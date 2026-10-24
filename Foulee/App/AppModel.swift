import Foundation
import Observation
import SwiftData
import UIKit
import TreadCore

/// Racine de l'app : services, réglages, séance en cours et boucle de rafraîchissement.
@Observable
final class AppModel {
    let log: DiagnosticLog
    let bluetooth: BluetoothHub
    let treadmill: TreadmillService
    let heartRate: HeartRateService
    let health: HealthService
    let watch: WatchBridge
    private(set) var sessionService: SessionService?
    private(set) var lastFinishedRecordID: UUID?
    private(set) var recoveredNotice: String?
    /// Diagnostic actif en cours (avancé par la boucle de l'app, même hors de l'écran Diagnostic).
    private(set) var diagnostic: ActiveDiagnostic?
    private(set) var diagnosticRevision = 0
    var banner: String?

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
            applySettings(old: oldValue)
        }
    }

    @ObservationIgnored let dataStore: DataStore
    /// Partage automatique des séances avec Rythme (App Group).
    @ObservationIgnored let rythmeShare: RythmeShare
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let checkpointStore: CheckpointStore
    @ObservationIgnored private var timer: DispatchSourceTimer?
    /// Séances terminées qui enregistrent encore la FC de récupération.
    @ObservationIgnored private var finishingServices: [SessionService] = []
    @ObservationIgnored private var watchOwnedSessions: [UUID: Bool] = [:]
    @ObservationIgnored private var lastWatchStatusAt: TimeInterval = 0
    @ObservationIgnored private var lastContextCheckAt: TimeInterval = 0
    /// Démarrage demandé par la montre, en attente de la connexion du tapis.
    @ObservationIgnored private var pendingWatchStart: (request: WatchStartRequest, deadline: TimeInterval)?
    /// Dernière demande de démarrage traitée (une demande répétée n'est jamais rejouée).
    @ObservationIgnored private var handledStartRequests: Set<UUID> = []
    @ObservationIgnored private var lastStartResult: WatchStartResult?
    /// Retour affiché sur la montre (ex. reprise refusée), pendant quelques secondes.
    @ObservationIgnored private var watchFeedback: (text: String, until: TimeInterval)?
    @ObservationIgnored private var watchCatalog: (fingerprint: String, programs: [WatchProgramSummary])?
    /// Bandeau d'information (ex. séance lancée depuis la montre).
    var notice: String?
    /// Base de données inaccessible : l'app tourne sans rien enregistrer.
    var storageWarning: String?
    /// Scénario de test (simulateur), actif seulement avec `-FouleeScenario`.
    @ObservationIgnored private var scenario: ScenarioRunner?

    init(modelContext: ModelContext) {
        let log = DiagnosticLog()
        self.log = log
        dataStore = DataStore(context: modelContext)
        let loaded = settingsStore.load()
        settings = loaded
        log.includeRawTelemetry = loaded.logRawTelemetry
        bluetooth = BluetoothHub(log: log)
        treadmill = TreadmillService(hub: bluetooth, log: log)
        treadmill.profileOverrideID = loaded.profileOverrideID
        heartRate = HeartRateService(hub: bluetooth, log: log, preference: loaded.heartRatePreference)
        health = HealthService(log: log)
        watch = WatchBridge(healthStore: health.store, log: log)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        checkpointStore = CheckpointStore(directory: support)
        rythmeShare = RythmeShare(log: log)
        log.log(.info, "Foulée démarrée")
        wireServices()
        seedTemplatesIfNeeded()
        if ScenarioRunner.isActive {
            let s = ScenarioRunner(model: self)
            scenario = s
            s.configure()
        }
        if let e = StoreLocation.openError {
            storageWarning = "La base de Foulée n'a pas pu être ouverte (\(e)). Les séances de cette ouverture ne seront pas enregistrées : contactez le développeur avant de supprimer l'app."
            log.log(.error, "Base SwiftData inaccessible : \(e)")
        } else {
            StoreLocation.recoverMisplacedData(into: dataStore, log: log)
        }
        recoverInterruptedSession()
        migrateLegacyZonesIfNeeded()
        syncRythmeShare()
        startLoop()
        // Aussi utile quand iOS lance l'app en arrière-plan (demande de la montre).
        connectRememberedDevices()
    }

    // MARK: - Câblage

    private func wireServices() {
        dataStore.onSessionSaved = { [weak self] r in
            guard let self else { return }
            self.rythmeShare.write(r, zones: self.settings.session.zones)
        }
        dataStore.onSessionDeleted = { [weak self] id in self?.rythmeShare.remove(id: id) }
        dataStore.onSaveError = { [weak self] message in
            guard let self else { return }
            self.log.log(.error, "Base : \(message)")
            self.storageWarning = "\(message). Rien n'a été enregistré ni partagé avec Rythme ; si l'erreur revient, exportez le journal (Réglages)."
        }
        treadmill.onDeviceRemembered = { [weak self] id, name in
            self?.settings.lastTreadmillID = id
            self?.settings.lastTreadmillName = name
        }
        heartRate.onSensorRemembered = { [weak self] id, name in
            self?.settings.lastHeartRateSensorID = id
            self?.settings.lastHeartRateSensorName = name
        }
        treadmill.onPacket = { [weak self] in
            // Chaque notification BLE fait avancer la séance (utile quand l'app est en arrière-plan).
            self?.sessionService?.tick()
        }
        watch.onHeartRate = { [weak self] bpm, age in self?.heartRate.ingestWatch(bpm: bpm, sampleAge: age) }
        watch.onSteps = { [weak self] total in self?.sessionService?.session.ingestWatchSteps(total: total) }
        watch.onActiveEnergy = { [weak self] kcal in self?.sessionService?.session.ingestWatchActiveEnergy(kcal: kcal) }
        watch.onRemoteCommand = { [weak self] c in self?.handleWatchCommand(c) }
        watch.onControl = { [weak self] c in self?.handleWatchControl(c) }
        watch.onStartRequest = { [weak self] r in self?.handleWatchStart(r) }
        watch.onContextRequested = { [weak self] in self?.publishWatchContext(force: true) }
        watch.contextProvider = { [unowned self] in self.watchContext() }
        watch.liveProvider = { [weak self] in
            guard let self, let s = self.sessionService, s.session.status != .ready else { return nil }
            return self.liveStatusForWatch(s, now: MonotonicClock.now())
        }
    }

    // MARK: - Montre : catalogue, démarrage, commandes

    /// Contexte publié pour la montre : programmes (dans l'ordre de l'iPhone), tapis, séance.
    func watchContext() -> WatchPhoneContext {
        let tm = treadmill
        let brief = WatchTreadmillBrief(name: tm.deviceName, ready: tm.connection.isReady && tm.beltState != .linkLost,
                                        simulated: tm.isSimulated, label: tm.connection.label)
        let active = hasActiveSession ? sessionService?.session.record : nil
        let fp = dataStore.programsFingerprint()
        if watchCatalog?.fingerprint != fp {
            watchCatalog = (fp, dataStore.allPrograms().map(WatchProgramSummary.init))
        }
        return WatchPhoneContext(programs: watchCatalog?.programs ?? [], treadmill: brief,
                                 activeSessionID: active?.id, activeProgramName: active?.title,
                                 zoneBounds: settings.session.zones.bounds, sentAt: Date(), lastStartResult: lastStartResult)
    }

    /// Publie le contexte s'il a changé (vérifié toutes les 2 s, et immédiatement sur demande).
    func publishWatchContext(force: Bool = false) {
        let now = MonotonicClock.now()
        guard force || now - lastContextCheckAt >= 2 else { return }
        lastContextCheckAt = now
        watch.publish(watchContext(), force: force)
    }

    /// Démarrage demandé depuis la montre. Le tapis doit être connecté (connexion au tapis
    /// mémorisé tentée pendant 12 s au plus) ; une demande ancienne ou répétée est refusée.
    private func handleWatchStart(_ r: WatchStartRequest) {
        guard !handledStartRequests.contains(r.requestID) else { return }
        handledStartRequests.insert(r.requestID)
        if !treadmill.connection.isReady && !hasActiveSession {
            connectRememberedDevices()
            pendingWatchStart = (r, MonotonicClock.now() + 12)
            log.log(.watch, "Démarrage Watch : attente de la connexion du tapis")
            return
        }
        completeWatchStart(r)
    }

    private func checkPendingWatchStart() {
        guard let p = pendingWatchStart else { return }
        if treadmill.connection.isReady || MonotonicClock.now() > p.deadline {
            pendingWatchStart = nil
            completeWatchStart(p.request)
        }
    }

    private func completeWatchStart(_ r: WatchStartRequest) {
        let decision = WatchStartPolicy.evaluate(r, now: Date(), programs: dataStore.allPrograms(),
                                                 treadmillReady: treadmill.connection.isReady,
                                                 sessionActive: hasActiveSession, diagnosticRunning: isDiagnosticRunning,
                                                 capabilities: treadmill.capabilities)
        let result: WatchStartResult
        switch decision {
        case let .refuse(why):
            result = WatchStartResult(requestID: r.requestID, accepted: false, sessionID: nil, message: why)
        case let .start(program):
            if sessionService?.session.status == .finished { closeFinishedSession() }
            prepareSession(program: program)
            if let e = startSession(fromWatch: true) {
                discardPreparedSession()
                result = WatchStartResult(requestID: r.requestID, accepted: false, sessionID: nil, message: e)
            } else {
                let title = program?.name ?? "Séance libre"
                notice = "« \(title) » lancé depuis l'Apple Watch"
                result = WatchStartResult(requestID: r.requestID, accepted: true, sessionID: sessionService?.session.record.id,
                                          message: "\(title) : démarrage du tapis")
            }
        }
        log.log(.watch, "Démarrage Watch : \(result.accepted ? "accepté" : "refusé") — \(result.message)")
        lastStartResult = result
        watch.sendReliably(.startResult(result))
        publishWatchContext(force: true)
        sendWatchStatus(force: true)
    }

    /// Commande horodatée de la montre : ignorée si elle vise une autre séance ou si elle est
    /// trop ancienne (une reprise n'est jamais rejouée en retard).
    private func handleWatchControl(_ c: WatchControl) {
        let current = sessionService?.session.record.id
        guard c.isAcceptable(now: Date(), currentSessionID: current) else {
            log.log(.watch, "Commande Watch « \(c.command.rawValue) » ignorée (ancienne ou pour une autre séance)")
            sendWatchStatus(force: true)
            return
        }
        handleWatchCommand(c.command)
    }

    /// Commandes reçues de la montre : mêmes actions que les boutons de l'iPhone.
    /// La reprise reste une action explicite de l'utilisateur (bouton sur la montre).
    private func handleWatchCommand(_ c: WatchRemoteCommand) {
        guard let s = sessionService else { return }
        switch c {
        case .pause: pauseSession()
        case .resume:
            if let e = resumeSession() {
                // Ex. le tapis ralentit encore après la pause : refus sûr, mais expliqué sur la montre.
                let text = "Reprise impossible : \(e). Réessayez dans quelques secondes."
                log.log(.watch, text)
                watchFeedback = (text, MonotonicClock.now() + 10)
            }
        case .stop:
            if s.session.status != .finished { stopSession() }
        case .resumeAutopilot: s.session.resumeAutopilot()
        }
        sendWatchStatus(force: true)
    }

    /// État en direct vers la montre (≈ 1 Hz) pendant une séance.
    private func sendWatchStatus(force: Bool = false) {
        let now = MonotonicClock.now()
        guard let s = sessionService, s.session.status != .ready, watch.canStreamToWatch,
              force || now - lastWatchStatusAt >= 1 else { return }
        lastWatchStatusAt = now
        watch.send(.liveStatus(liveStatusForWatch(s, now: now)), quiet: true)
    }

    private func liveStatusForWatch(_ s: SessionService, now: TimeInterval) -> WatchLiveStatus {
        var st = WatchLiveStatus.make(session: s.session, now: now, date: Date())
        if let f = watchFeedback {
            if now < f.until { st.alert = f.text } else { watchFeedback = nil }
        }
        return st
    }

    /// Reconnexion automatique du lien (jamais de commande) aux appareils mémorisés.
    func connectRememberedDevices() {
        if settings.simulatorMode {
            if !treadmill.isSimulated { treadmill.connectSimulator() }
        } else if let id = settings.lastTreadmillID, treadmill.connection == .none {
            treadmill.connect(id: id, name: settings.lastTreadmillName ?? "Tapis")
        }
        if let id = settings.lastHeartRateSensorID, heartRate.sensorConnection == .none {
            heartRate.connectSensor(id: id, name: settings.lastHeartRateSensorName ?? "Capteur cardio")
        }
    }

    private func applySettings(old: AppSettings) {
        log.includeRawTelemetry = settings.logRawTelemetry
        if settings.heartRatePreference != old.heartRatePreference {
            heartRate.setPreference(settings.heartRatePreference)
        }
        if settings.profileOverrideID != old.profileOverrideID {
            treadmill.profileOverrideID = settings.profileOverrideID
        }
        if settings.simulatorMode != old.simulatorMode {
            if settings.simulatorMode {
                treadmill.connectSimulator()
            } else {
                treadmill.disconnect()
            }
        }
        sessionService?.session.settings.zones = settings.session.zones
        if RythmeShare.zonesFingerprint(settings.session.zones) != RythmeShare.zonesFingerprint(old.session.zones) {
            syncRythmeShare()
        }
        sessionService?.session.settings.zoneAlertsEnabled = settings.session.zoneAlertsEnabled
        sessionService?.session.settings.smoothTransitions = settings.session.smoothTransitions
        sessionService?.session.settings.maxSpeedStepKmh = settings.session.maxSpeedStepKmh
        updateIdleTimer()
    }

    // MARK: - Boucle (base de temps indépendante de l'affichage)

    private func startLoop() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let driven = sessionService.map { $0.session.status != .finished } ?? false
        treadmill.tick(drivenBySession: driven)
        sessionService?.tick()
        sendWatchStatus()
        publishWatchContext()
        checkPendingWatchStart()
        finishingServices.forEach { $0.tick() }
        heartRate.refresh()
        if let d = diagnostic, case .running = d.state {
            d.tick()
            diagnosticRevision += 1
        }
    }

    // MARK: - Diagnostic actif (explicite, hors du tapis)

    var isDiagnosticRunning: Bool {
        _ = diagnosticRevision
        if case .running = diagnostic?.state { return true }
        return false
    }

    enum DiagnosticKind { case startSequence, speedResponse(requestControlEachStep: Bool) }

    func startDiagnostic(_ kind: DiagnosticKind) -> String? {
        guard !hasActiveSession else { return "Terminez la séance en cours" }
        let d: ActiveDiagnostic
        switch kind {
        case .startSequence:
            d = StartSequenceDiagnostic(controller: treadmill.controller)
        case let .speedResponse(rc):
            var o = SpeedResponseDiagnostic.Options()
            o.requestControlBeforeEachStep = rc
            d = SpeedResponseDiagnostic(controller: treadmill.controller, options: o)
        }
        diagnostic = d
        diagnosticRevision += 1
        if case let .failure(e) = d.begin() { return e.description }
        return nil
    }

    func abortDiagnostic() {
        diagnostic?.abort()
        diagnosticRevision += 1
    }

    // MARK: - Séance

    var hasActiveSession: Bool {
        guard let s = sessionService else { return false }
        return s.session.status != .finished && s.session.status != .ready
    }

    func prepareSession(program: WorkoutProgram?) {
        guard !hasActiveSession else { return }
        let s = WorkoutSession(program: program, controller: treadmill.controller, heartRate: heartRate.monitor,
                               settings: settings.session, treadmillName: treadmill.deviceName,
                               simulated: treadmill.isSimulated, log: log,
                               clock: MonotonicClock.now, wallClock: Date.init)
        if let p = program, p.hasAutoSpeed, let records = dataStore.sessionsForSharing()?.records {
            s.learnedAutoStartKmh = SessionAnalysis.learnedAutoStart(for: p, records: records.map { displayRecord($0) })
        }
        let service = SessionService(session: s, checkpointStore: checkpointStore)
        service.onFinished = { [weak self] r in self?.sessionFinished(r) }
        service.onFinalized = { [weak self] r in self?.sessionFinalized(r) }
        service.onAlert = { [weak self] text in self?.zoneAlert(text) }
        treadmill.eventSink = { [weak s] e in s?.handle(controllerEvent: e) }
        treadmill.telemetrySink = { [weak s] d, t in s?.handleTelemetry(d, at: t) }
        sessionService = service
    }

    func discardPreparedSession() {
        guard let s = sessionService, s.session.status == .ready || s.session.status == .finished else { return }
        sessionService = nil
        treadmill.eventSink = nil
        treadmill.telemetrySink = nil
    }

    /// Démarrage explicite par l'utilisateur.
    /// - Parameter fromWatch: lancé depuis la montre, qui démarre elle-même son exercice.
    func startSession(fromWatch: Bool = false) -> String? {
        guard let s = sessionService else { return "Aucune séance préparée" }
        switch s.session.start() {
        case .success:
            let (std, meta) = HealthWritePlan.watchMetadata(record: s.session.record)
            watch.beginSession(id: s.session.record.id, title: s.session.record.title,
                               metadata: .workoutMetadata(standard: std, foulee: meta))
            if !fromWatch && settings.startWatchWorkoutWithSession && watch.isAppInstalled && watch.linkState != .mirrored {
                watch.launchWatchWorkout(running: s.program?.suggestsRunning ?? (s.session.effectiveTargets.speed >= 8))
            }
            s.saveCheckpoint()
            updateIdleTimer()
            publishWatchContext(force: true)
            return nil
        case let .failure(e):
            return e.description
        }
    }

    func pauseSession() {
        sessionService?.session.pause()
        sessionService?.saveCheckpoint()
        if watch.linkState == .mirrored || watch.linkState == .connectivity || watch.isReachable { watch.send(.command(.pause)) }
        sendWatchStatus(force: true)
    }

    func resumeSession() -> String? {
        guard let s = sessionService else { return nil }
        if case let .failure(e) = s.session.resume() { return e.description }
        if watch.watchState == .paused || watch.isReachable { watch.send(.command(.resume)) }
        sendWatchStatus(force: true)
        return nil
    }

    func stopSession() {
        sessionService?.session.stop()
        sendWatchStatus(force: true)
    }

    /// Fin de séance : sauvegarde locale immédiate. Si un exercice Watch a tourné, la Watch est
    /// propriétaire de l'enregistrement Santé : on lui transmet les métadonnées Foulée avant de
    /// la terminer (ou de l'annuler si la séance fait moins d'1 minute).
    private func sessionFinished(_ record: SessionRecord) {
        var r = record
        let usedWatch = watch.usedDuringSession
        if usedWatch {
            r.healthStatus = .ownedByWatch
            let plan = HealthWritePlan.make(record: r, inputs: .init(healthEnabled: settings.health.enabled,
                                                                       watchWorkoutUsed: true, bodyMassKg: nil))
            let (std, meta) = HealthWritePlan.watchMetadata(record: r)
            watch.send(.workoutMetadata(standard: std, foulee: meta))
            if settings.endWatchWorkoutWithSession || plan.discardWatchWorkout {
                watch.send(.command(plan.discardWatchWorkout ? .discard : .end))
            }
            r.healthReport = HealthWriteReport(plan: plan, outcome: plan.discardWatchWorkout ? "exercice Watch annulé (< 1 min)" : "métadonnées envoyées à la Watch",
                                               workoutUUID: nil)
            log.log(.health, "Santé : \(plan.reason)")
        }
        watchOwnedSessions[r.id] = usedWatch
        dataStore.upsert(r)
        lastFinishedRecordID = r.id
        watch.endSessionTracking()
        updateIdleTimer()
    }

    /// Séance définitive (arrêt réel de la bande + 2 min de FC de récupération) : écriture Santé.
    private func sessionFinalized(_ record: SessionRecord) {
        var r = record
        // Le ressenti a pu être saisi pendant les 2 min de FC de récupération.
        r.perceivedExertion = dataStore.record(id: r.id)?.perceivedExertion ?? r.perceivedExertion
        let usedWatch = watchOwnedSessions.removeValue(forKey: r.id) ?? false
        if usedWatch {
            r.healthStatus = .ownedByWatch
            r.healthReport = dataStore.record(id: r.id)?.healthReport
        }
        dataStore.upsert(r)
        finishingServices.removeAll { $0.session.isFinalized }
        guard !usedWatch else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var updated = await self.writeToHealth(r)
            updated.perceivedExertion = self.dataStore.record(id: r.id)?.perceivedExertion ?? updated.perceivedExertion
            self.dataStore.upsert(updated)
        }
    }

    /// Calcule le plan et écrit dans Santé (iPhone propriétaire). Renvoie la séance mise à jour.
    @MainActor
    func writeToHealth(_ record: SessionRecord) async -> SessionRecord {
        var r = record
        let mass = settings.health.enabled ? await health.latestBodyMass() : nil
        let plan = HealthWritePlan.make(record: r, inputs: .init(healthEnabled: settings.health.enabled,
                                                                   watchWorkoutUsed: r.healthStatus == .ownedByWatch,
                                                                   bodyMassKg: mass))
        log.log(.health, "Santé : \(plan.reason)")
        let result = await health.write(r, plan: plan)
        r.healthStatus = result.status
        r.healthReport = result.report
        if case .saved = result.status { r.healthSyncVersion = plan.standard.syncVersion }
        return r
    }

    /// Correction d'une séance : nouvelle révision, réécrite dans Santé si Foulée l'y avait écrite.
    @MainActor
    func correct(_ record: SessionRecord, title: String, activityType: HealthActivityType?, endAfterMinutes: Double?) async -> SessionRecord {
        var r = record
        r.programName = title.trimmingCharacters(in: .whitespaces).isEmpty ? r.programName : title
        r.activityTypeOverride = activityType
        if let minutes = endAfterMinutes, let start = r.beltStartDate ?? r.samples.first.map({ r.date(at: $0.t) }) {
            let newEnd = start.addingTimeInterval(minutes * 60)
            if newEnd < (r.beltStopDate ?? r.endDate ?? newEnd.addingTimeInterval(1)) {
                let cut = newEnd.timeIntervalSince(r.startDate)
                r.samples.removeAll { $0.t > cut }
                r.events.removeAll { $0.t > cut }
                r.heartRateReadings = r.heartRateReadings?.filter { $0.t <= cut + HealthWritePlan.recoveryWindow }
                r.phaseSpans = r.phaseSpans?.filter { $0.start < cut }.map { var p = $0; p.end = min(p.end ?? cut, cut); return p }
                r.beltStopDate = newEnd
                r.endDate = newEnd
                if let last = r.samples.last {
                    r.distanceMeters = last.distance
                    r.steps = last.steps
                    r.activeSeconds = last.active
                }
                r.recomputeAggregates()
            }
        }
        r.revision = (r.revision ?? 1) + 1
        r.events.append(SessionEvent(t: r.samples.last?.t ?? 0, kind: .info, detail: "Séance corrigée (révision \(r.revision ?? 2))"))
        if case .saved = r.healthStatus {
            r = await writeToHealth(r)
        }
        dataStore.upsert(r)
        return r
    }

    /// Fichiers partagés avec Rythme : historique manquant, zones modifiées, séances retirées.
    func syncRythmeShare() {
        guard rythmeShare.directory != nil else { return }
        // Base en mémoire (ouverture impossible) : elle ne reflète pas l'historique, ne rien toucher.
        guard StoreLocation.openError == nil else { return }
        guard let s = dataStore.sessionsForSharing() else {
            log.log(.warning, "Partage Rythme : base illisible, synchronisation reportée (aucun fichier supprimé)")
            return
        }
        rythmeShare.sync(s.records, keep: s.undecodable, zones: settings.session.zones)
    }

    /// Séance telle qu'affichée et exportée pour Rythme : zones recalculées depuis la FC
    /// enregistrée avec les réglages de zones actuels (l'enregistrement d'origine reste intact).
    func displayRecord(_ r: SessionRecord) -> SessionRecord {
        r.rezoned(with: settings.session.zones)
    }

    /// Ressenti de l'effort (CR10 de Borg, 0–10), saisi après la séance.
    func setPerceivedExertion(_ value: Int?, for id: UUID) {
        guard var r = dataStore.record(id: id) else { return }
        r.perceivedExertion = value.map { min(max($0, 0), 10) }
        dataStore.upsert(r)
    }

    /// Supprime la séance de Foulée et, si elle y est, de Santé (séance et échantillons).
    @MainActor
    func delete(_ record: SessionRecord) async -> String {
        // D'abord Foulée : si la base refuse, rien n'est retiré de Santé ni de Rythme.
        guard dataStore.delete(id: record.id) else { return "La séance n'a pas pu être supprimée de Foulée (voir l'alerte)." }
        var message = "Séance supprimée de Foulée"
        switch record.healthStatus {
        case .saved, .ownedByWatch:
            message += " ; " + (await health.deleteSession(id: record.id.uuidString))
        default:
            break
        }
        return message
    }

    /// Au premier lancement : demande les autorisations Santé (une fois), puis calcule les zones.
    @MainActor
    func prepareHealth() async {
        migrateLegacyZonesIfNeeded()
        guard health.isAvailable, !ScenarioRunner.isActive else { return }
        if settings.didRequestHealthAuthorization != true {
            _ = await health.requestAuthorization()
            settings.didRequestHealthAuthorization = true
        }
        await refreshZonesFromHealth()
    }

    // MARK: - Zones (comme Rythme)

    /// Une seule fois : des réglages restés aux anciennes valeurs par défaut (% de FC max, rien de
    /// saisi) passent à la méthode Rythme ; FC max et repos sont ensuite calculées depuis Santé.
    /// Un réglage choisi ensuite, même % de FC max, n'est plus jamais modifié.
    func migrateLegacyZonesIfNeeded() {
        guard settings.didMigrateLegacyZones != true else { return }
        if settings.session.zones.isLegacyDefault {
            settings.session.zones.method = .rythme
            log.log(.heart, "Zones : anciens réglages par défaut (% de FC max) remplacés par la méthode Rythme")
        }
        settings.didMigrateLegacyZones = true
    }

    /// Recalcule FC max et FC de repos depuis Santé (sauf valeurs saisies dans Foulée).
    @MainActor
    func refreshZonesFromHealth() async {
        guard health.isAvailable else { return }
        let z = settings.session.zones
        let inputs = await health.zoneInputs()
        let res = ZoneProfileResolver.resolve(userMax: z.maxHRIsUserValue ? z.maxHR : nil,
                                              userResting: z.restingHRIsUserValue ? z.restingHR : nil,
                                              birthDate: inputs.birthDate, now: Date(),
                                              highHR: inputs.highHR, restingHR: inputs.restingHR,
                                              fallbackMax: z.maxHR)
        var nz = settings.session.zones
        nz.maxHR = res.maxHR
        nz.maxHRSource = res.maxSource
        nz.restingHR = res.restingHR
        nz.restingHRExact = res.restingHRExact
        nz.restingHRSource = res.restingSource
        settings.session.zones = nz
        log.log(.heart, "Zones : FC max \(res.maxHR) (\(res.maxSource)), repos \(res.restingHR.map(String.init) ?? "—") (\(res.restingSource))")
    }

    /// Ferme l'écran de séance terminée pour en préparer une nouvelle.
    func closeFinishedSession() {
        guard let s = sessionService, s.session.status == .finished else { return }
        // La FC de récupération continue d'être enregistrée en arrière-plan.
        if !s.session.isFinalized { finishingServices.append(s) }
        sessionService = nil
        treadmill.eventSink = nil
        treadmill.telemetrySink = nil
    }

    private func zoneAlert(_ text: String) {
        banner = text
        guard settings.hapticAlerts else { return }
        MainActor.assumeIsolated {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    // MARK: - Écran

    func updateIdleTimer() {
        let active: Bool
        if let s = sessionService, s.session.status != .finished, s.session.status != .ready {
            active = s.session.isFreeRun ? settings.keepScreenOnDuringFreeRun : settings.keepScreenOnDuringPrograms
        } else {
            active = false
        }
        MainActor.assumeIsolated {
            UIApplication.shared.isIdleTimerDisabled = active
        }
    }

    func appDidEnterBackground() {
        sessionService?.saveCheckpoint()
    }

    // MARK: - Reprise après crash

    private func recoverInterruptedSession() {
        guard let cp = checkpointStore.load() else { return }
        let record = WorkoutSession.recoveredRecord(from: cp)
        if dataStore.record(id: record.id) == nil {
            dataStore.upsert(record)
            recoveredNotice = "Une séance interrompue (\(record.title)) a été récupérée dans l'historique. Le tapis n'a pas été relancé."
            log.log(.session, recoveredNotice!)
        }
        checkpointStore.clear()
    }

    func dismissRecoveredNotice() { recoveredNotice = nil }

    /// Installe et met à jour la bibliothèque de programmes prédéfinis (voir `TemplateLibrary`) :
    /// mise à jour en place (mêmes identifiants), ajout des nouveaux, jamais de doublon, programmes
    /// supprimés par l'utilisateur non réinstallés, programmes personnels intacts.
    private func seedTemplatesIfNeeded() {
        let installedRevision = settings.templatesRevision ?? (settings.seededTemplateIDs == nil ? 0 : 1)
        let plan = TemplateLibrary.plan(installed: dataStore.allPrograms(), seededIDs: settings.seededTemplateIDs ?? [],
                                        installedRevision: installedRevision)
        plan.upserts.forEach { dataStore.upsert($0) }
        plan.removals.forEach { dataStore.deleteProgram(id: $0) }
        if !plan.removals.isEmpty { log.log(.info, "\(plan.removals.count) ancien(s) programme(s) de la première version retiré(s)") }
        if !plan.updatedNames.isEmpty { log.log(.info, "Programmes mis à jour : \(plan.updatedNames.joined(separator: ", "))") }
        if !plan.addedNames.isEmpty { log.log(.info, "Programmes ajoutés : \(plan.addedNames.joined(separator: ", "))") }
        settings.seededTemplateIDs = plan.seededIDs
        settings.templatesRevision = plan.revision
        settings.didSeedTemplates = true
    }

    /// Réinstalle les programmes prédéfinis absents (ou les remet à l'état d'origine).
    @discardableResult
    func restoreTemplates(resetExisting: Bool) -> Int {
        let programs = dataStore.allPrograms()
        var count = 0
        for t in WorkoutProgram.templates {
            if let current = programs.first(where: { $0.templateID == t.templateID }) {
                guard resetExisting else { continue }
                var fresh = t
                fresh.id = current.id
                fresh.createdAt = current.createdAt
                dataStore.upsert(fresh)
            } else {
                dataStore.upsert(t)
            }
            count += 1
        }
        return count
    }

    // MARK: - Diagnostic

    func diagnosticHeader() -> String {
        var lines = ["Foulée — journal de diagnostic",
                     "Date : \(Date())",
                     "Tapis : \(treadmill.deviceName ?? "—")\(treadmill.isSimulated ? " (SIMULATEUR)" : "")",
                     "Profil : \(treadmill.profile.name)"]
        let c = treadmill.capabilities
        lines.append(String(format: "Vitesse : %.2f–%.2f km/h pas %.2f (%@)", c.speed.minKmh, c.speed.maxKmh, c.speed.incrementKmh,
                            c.speedRangeFromDevice ? "tapis" : "profil"))
        if let i = c.inclination {
            lines.append(String(format: "Inclinaison : %.1f–%.1f %% pas %.1f (%@)", i.minPercent, i.maxPercent, i.incrementPercent,
                                c.inclinationRangeFromDevice ? "tapis" : "profil"))
        }
        if let f = c.feature {
            lines.append("Mesures : \(f.machineDescription)")
            lines.append("Consignes : \(f.targetDescription)")
        }
        for (k, v) in treadmill.deviceInfo.sorted(by: { $0.key < $1.key }) { lines.append("\(k) : \(v)") }
        lines.append("—")
        return lines.joined(separator: "\n")
    }
}
