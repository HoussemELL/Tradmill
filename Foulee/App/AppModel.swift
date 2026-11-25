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
        if !ScenarioRunner.isActive {
            Task { @MainActor [log] in await SigningExpiry.scheduleReminder(log: log) }
        }
        migrateLegacyZonesIfNeeded()
        repairStepJumpsIfNeeded()
        relearnStepCalibrationIfNeeded()
        reconcileRecentSteps()
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
        watch.onSteps = { [weak self] total, age in
            self?.sessionService?.session.ingestWatchSteps(total: total, sampleAge: age)
        }
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
        sessionService?.session.settings.fixedInclinePercent = settings.session.fixedInclinePercent
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
        // Estimation en direct : longueur de pas apprise (en marche à 5 km/h) si elle existe.
        var sessionSettings = settings.session
        if let f = stepCalibration.factor(speedKmh: StepModel.referenceSpeedKmh) {
            sessionSettings.strideLengthMeters = StepCalibration.baseWalkingStepLength * f
        }
        let s = WorkoutSession(program: program, controller: treadmill.controller, heartRate: heartRate.monitor,
                               settings: sessionSettings, treadmillName: treadmill.deviceName,
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
            if !fromWatch && settings.startWatchWorkoutWithSession && watch.isWatchPaired && !watch.watchWorkoutActive {
                launchWatchWorkoutWithRetry(sessionID: s.session.record.id,
                                            running: s.program?.suggestsRunning ?? (s.session.effectiveTargets.speed >= 8))
            }
            s.saveCheckpoint()
            updateIdleTimer()
            publishWatchContext(force: true)
            return nil
        case let .failure(e):
            return e.description
        }
    }

    /// Lance l'exercice de la montre ; s'il ne tourne toujours pas après 12 s puis 40 s (montre
    /// verrouillée, poignet baissé, lancement perdu), nouvel essai. Au-delà, un bandeau demande
    /// d'ouvrir Foulée sur la montre : elle démarre alors seule l'enregistrement de la séance.
    private func launchWatchWorkoutWithRetry(sessionID: UUID, running: Bool) {
        watch.launchWatchWorkout(running: running)
        Task { @MainActor [weak self] in
            for (attempt, delay) in [(2, 12.0), (3, 28.0)] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.hasActiveSession, self.sessionService?.session.record.id == sessionID else { return }
                if self.watch.watchWorkoutActive { return }
                self.log.log(.watch, "Exercice Watch toujours absent : nouvel essai de lancement (\(attempt))")
                self.watch.launchWatchWorkout(running: running)
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.hasActiveSession, self.sessionService?.session.record.id == sessionID,
                  !self.watch.watchWorkoutActive else { return }
            self.notice = "La montre ne s'est pas ouverte : ouvrez Foulée sur la montre, l'enregistrement de la séance démarrera seul."
            self.log.log(.warning, "Exercice Watch non démarré après 3 essais")
        }
    }

    func pauseSession() {
        sessionService?.session.pause()
        sessionService?.saveCheckpoint()
        // L'exercice de la montre n'est PAS mis en pause : un exercice en pause ne mesure plus la FC,
        // et un ordre de reprise perdu (montre en veille) la laissait sans FC jusqu'à la fin
        // (séance du 02/11). Les pauses sont reportées dans sa séance Santé à la fin.
        sendWatchStatus(force: true)
    }

    func resumeSession() -> String? {
        guard let s = sessionService else { return nil }
        if case let .failure(e) = s.session.resume() { return e.description }
        // Montre encore en pause (ancienne version, ou pause faite sur la montre) : on la relance.
        if watch.watchState == .paused || watch.linkState == .mirrored || watch.isReachable { watch.send(.command(.resume)) }
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
        var r = finalizeSteps(record)
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
        var r = finalizeSteps(record)
        // Le ressenti a pu être saisi pendant les 2 min de FC de récupération.
        r.perceivedExertion = dataStore.record(id: r.id)?.perceivedExertion ?? r.perceivedExertion
        let usedWatch = watchOwnedSessions.removeValue(forKey: r.id) ?? false
        if usedWatch {
            r.healthStatus = .ownedByWatch
            r.healthReport = dataStore.record(id: r.id)?.healthReport
        }
        dataStore.upsert(r)
        reconcileWatchSteps(id: r.id)
        finishingServices.removeAll { $0.session.isFinalized }
        guard !usedWatch else {
            verifyWatchHealthSession(id: r.id)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var updated = await self.writeToHealth(r)
            updated.perceivedExertion = self.dataStore.record(id: r.id)?.perceivedExertion ?? updated.perceivedExertion
            self.dataStore.upsert(updated)
        }
    }

    // MARK: - Pas : choix final, Santé, longueur de pas apprise

    var stepCalibration: StepCalibration {
        guard let c = settings.stepCalibration, c.version == StepCalibration.currentVersion else { return StepCalibration() }
        return c
    }

    /// Calibration absente ou d'une version antérieure : réapprise sur tout l'historique.
    private func relearnStepCalibrationIfNeeded() {
        guard settings.stepCalibration?.version != StepCalibration.currentVersion,
              let all = dataStore.sessionsForSharing()?.records else { return }
        let c = StepCalibration.learned(from: all)
        settings.stepCalibration = c
        log.log(.info, "Longueur de pas réapprise sur l'historique : " + Self.stepCalibrationSummary(c))
    }

    /// Choix final des pas avec ce qu'on sait déjà (sans Santé) ; conserve ce que Santé a déjà apporté.
    private func finalizeSteps(_ record: SessionRecord) -> SessionRecord {
        var r = record
        if let stored = dataStore.record(id: r.id) {
            r.watchSteps = r.watchSteps ?? stored.watchSteps
            r.watchStepsFromHealth = stored.watchStepsFromHealth
            r.stepsReconciled = stored.stepsReconciled
        }
        return StepReconciliation.finalize(r, healthWatchSteps: nil, calibration: stepCalibration,
                                           walkingStepLength: settings.session.strideLengthMeters)
    }

    /// Relit dans Santé les pas de la montre pendant la séance (la synchronisation montre → iPhone
    /// peut prendre quelques minutes : essais à 30 s, 2 min et 6 min), choisit les pas définitifs,
    /// puis apprend la longueur de pas si les pas sont cohérents avec la distance.
    private func reconcileWatchSteps(id: UUID, delays: [UInt64] = [30, 90, 240]) {
        Task { @MainActor [weak self] in
            for (i, delay) in delays.enumerated() {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                guard let self, let r = self.dataStore.record(id: id), !r.simulated, r.stepsReconciled != true else { return }
                if await self.reconcileWatchStepsOnce(r, last: i == delays.count - 1) { return }
            }
        }
    }

    /// Un essai ; renvoie vrai quand c'est terminé (Santé a fourni au moins le total reçu en direct,
    /// ou dernier essai).
    @MainActor
    private func reconcileWatchStepsOnce(_ r: SessionRecord, last: Bool) async -> Bool {
        let intervals = r.activeIntervals()
        var healthSteps: Int?
        if settings.health.enabled, let first = intervals.first, let end = intervals.last?.end,
           let samples = await health.watchStepSamples(from: first.start, to: end) {
            let total = StepReconciliation.watchSteps(samples, during: intervals)
            if total >= 1 { healthSteps = Int(total.rounded()) }
        }
        let live = r.watchSteps ?? (r.stepsSource == .appleWatch ? r.steps : nil)
        let complete = healthSteps.map { $0 >= (live ?? 0) } ?? false
        guard complete || last || !settings.health.enabled else { return false }
        var f = StepReconciliation.finalize(r, healthWatchSteps: healthSteps, calibration: stepCalibration,
                                            walkingStepLength: settings.session.strideLengthMeters)
        f.stepsReconciled = true
        f.perceivedExertion = dataStore.record(id: r.id)?.perceivedExertion ?? f.perceivedExertion
        if f.steps != r.steps || f.stepsSource != r.stepsSource || f.watchSteps != r.watchSteps {
            var parts: [String] = []
            if let h = healthSteps { parts.append("\(h) pas de la montre relus dans Santé (direct : \(live.map(String.init) ?? "aucun"))") }
            if f.stepsReplacedUndercount == true, let w = f.watchSteps {
                parts.append("la montre n'a compté que \(w) pas pour \(Int(f.distanceMeters)) m : pas estimés à \(f.steps ?? 0) avec la longueur de pas")
            }
            log.log(.info, "Pas : " + (parts.isEmpty ? "\(r.steps ?? 0) → \(f.steps ?? 0)" : parts.joined(separator: " ; ")))
        }
        dataStore.upsert(f)
        learnStepLength(from: f)
        return true
    }

    /// Apprend la longueur de pas sur une séance dont les pas de la montre (ou du tapis) sont cohérents.
    private func learnStepLength(from r: SessionRecord) {
        let measured = r.stepsSource == .treadmill ? r.steps : r.watchSteps
        guard let m = measured, r.stepsReplacedUndercount != true else { return }
        var c = stepCalibration
        guard c.learn(from: r, measuredSteps: m) else { return }
        settings.stepCalibration = c
        log.log(.info, "Longueur de pas apprise : " + Self.stepCalibrationSummary(c))
    }

    static func stepCalibrationSummary(_ c: StepCalibration) -> String {
        func cm(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded())) cm" } ?? "—" }
        var parts: [String] = []
        if let w = c.walk { parts.append("marche \(cm(c.learnedStepLength(speedKmh: 5))) à 5 km/h (\(w.sessions) séance\(w.sessions > 1 ? "s" : ""))") }
        if let r = c.run { parts.append("course \(cm(c.learnedStepLength(speedKmh: 9))) à 9 km/h (\(r.sessions) séance\(r.sessions > 1 ? "s" : ""))") }
        return parts.isEmpty ? "pas encore apprise" : parts.joined(separator: ", ")
    }

    /// Au lancement : séances des dernières 48 h dont les pas n'ont pas encore été relus dans Santé
    /// (app fermée avant la fin des essais).
    private func reconcileRecentSteps() {
        guard let all = dataStore.sessionsForSharing()?.records else { return }
        let since = Date().addingTimeInterval(-48 * 3600)
        for r in all where !r.simulated && r.stepsReconciled != true && (r.endDate ?? .distantPast) > since {
            reconcileWatchSteps(id: r.id, delays: [5, 60, 240])
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

    /// Après une séance enregistrée par la montre : une fois sa séance Santé enregistrée (état
    /// « terminé » reçu, au plus ~3 min), on vérifie qu'elle couvre bien toute la séance. Si la
    /// montre n'en a gardé qu'une partie (exercice coupé ou démarré en retard), l'iPhone la
    /// remplace automatiquement par la séance complète. Rien n'est fait si Santé n'a encore
    /// aucune séance de la montre (le bouton de l'historique reste disponible).
    private func verifyWatchHealthSession(id: UUID) {
        guard settings.health.enabled, health.isAvailable else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<36 {
                guard let self else { return }
                if self.watch.watchState == .ended || self.watch.watchState == .failed { break }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            // Laisser à Santé le temps de synchroniser la séance de la montre vers l'iPhone.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, let r = self.dataStore.record(id: id), r.healthStatus == .ownedByWatch, !r.simulated else { return }
            let message = await self.recoverHealthSession(r, automatic: true)
            if self.dataStore.record(id: id)?.healthStatus != .ownedByWatch {
                self.notice = "Santé : la montre n'avait enregistré qu'une partie de la séance, remplacée par la séance complète."
            }
            self.log.log(.health, "Vérification automatique de la séance Santé de la montre : \(message)")
        }
    }

    /// Séance Watch incomplète dans Santé : l'iPhone écrit la séance complète (données Foulée).
    @MainActor
    func recoverHealthSession(_ record: SessionRecord, automatic: Bool = false) async -> String {
        let mass = await health.latestBodyMass()
        let (updated, message) = await health.recoverFullSession(record, bodyMassKg: mass, onlyIfPartialExists: automatic)
        if let u = updated {
            var keep = u
            keep.perceivedExertion = dataStore.record(id: u.id)?.perceivedExertion ?? u.perceivedExertion
            dataStore.upsert(keep)
        }
        log.log(.health, "Récupération Santé : \(message)")
        return message
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
        if record.isWatchStandalone {
            // Sortie de la montre : retirée de l'historique seulement (elle reste dans Santé), et
            // jamais réimportée.
            var deleted = UserDefaults.standard.stringArray(forKey: Self.deletedImportsKey) ?? []
            deleted.append(record.id.uuidString)
            UserDefaults.standard.set(Array(deleted.suffix(200)), forKey: Self.deletedImportsKey)
            return "Sortie retirée de l'historique Foulée (elle reste dans Apple Santé)."
        }
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
        // Une fois, puis seulement si une donnée n'a jamais été proposée (nouvelle version).
        let newDataToAsk = await health.shouldRequestAuthorization()
        if settings.didRequestHealthAuthorization != true || newDataToAsk {
            _ = await health.requestAuthorization()
            settings.didRequestHealthAuthorization = true
        }
        await refreshZonesFromHealth()
        await importWatchWorkouts()
    }

    // MARK: - Exercices autonomes de la montre

    private static let deletedImportsKey = "foulee.importedWatch.deleted"
    @ObservationIgnored private var lastWatchImportAt = Date.distantPast

    /// Ajoute à l'historique les exercices faits avec la montre seule (sans tapis ni iPhone),
    /// lus dans Santé. Au lancement et au retour au premier plan (au plus toutes les 2 min).
    /// Une sortie supprimée de l'historique n'est jamais réimportée.
    @MainActor
    func importWatchWorkouts() async {
        guard health.isAvailable, !ScenarioRunner.isActive, StoreLocation.openError == nil,
              Date().timeIntervalSince(lastWatchImportAt) > 120,
              let existing = dataStore.sessionsForSharing() else { return }
        lastWatchImportAt = Date()
        var known = Set(existing.records.map(\.id)).union(existing.undecodable)
        known.formUnion((UserDefaults.standard.stringArray(forKey: Self.deletedImportsKey) ?? []).compactMap(UUID.init))
        let since = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
        let found = await health.standaloneWatchWorkouts(since: since, known: known)
        var added = 0
        for w in found where dataStore.upsert(w.record(zones: settings.session.zones)) { added += 1 }
        if added > 0 {
            log.log(.health, "\(added) exercice(s) autonome(s) de la montre ajouté(s) à l'historique")
            notice = added == 1 ? "1 sortie de la montre ajoutée à l'historique." : "\(added) sorties de la montre ajoutées à l'historique."
        }
    }

    func appDidBecomeActive() {
        Task { @MainActor [weak self] in await self?.importWatchWorkouts() }
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

    /// Une seule fois : retire des séances les sauts de pas impossibles (total de la montre
    /// recalculé par Santé, compté à tort comme une remise à zéro), puis les re-partage avec Rythme.
    func repairStepJumpsIfNeeded() {
        guard settings.didRepairStepJumps != true, StoreLocation.openError == nil,
              let all = dataStore.sessionsForSharing() else { return }
        var fixedNames: [String] = []
        for r in all.records {
            guard let fixed = r.repairedStepJumps() else { continue }
            if dataStore.upsert(fixed) {
                fixedNames.append("\(r.programName ?? "Séance libre") (\(r.steps ?? 0) → \(fixed.steps ?? 0) pas)")
            }
        }
        if !fixedNames.isEmpty { log.log(.info, "Pas corrigés : " + fixedNames.joined(separator: ", ")) }
        settings.didRepairStepJumps = true
    }

    /// Recalcule FC max et FC de repos depuis Santé (sauf valeurs saisies dans Foulée).
    @MainActor
    func refreshZonesFromHealth() async {
        guard health.isAvailable else { return }
        // iPhone verrouillé (app lancée en arrière-plan par la montre) : Santé est chiffrée et ne
        // renvoie rien ; on garde les zones actuelles.
        guard UIApplication.shared.isProtectedDataAvailable else {
            log.log(.heart, "Zones : iPhone verrouillé, Santé illisible : zones actuelles conservées")
            return
        }
        let z = settings.session.zones
        let inputs = await health.zoneInputs()
        let resolved = ZoneProfileResolver.resolve(userMax: z.maxHRIsUserValue ? z.maxHR : nil,
                                                   userResting: z.restingHRIsUserValue ? z.restingHR : nil,
                                                   birthDate: inputs.birthDate, now: Date(),
                                                   highHR: inputs.highHR, restingHR: inputs.restingHR,
                                                   fallbackMax: z.maxHR)
        let res = ZoneProfileResolver.keepingPrevious(resolved, previous: z,
                                                      readMax: inputs.birthDate != nil || !inputs.highHR.isEmpty,
                                                      readResting: !inputs.restingHR.isEmpty)
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
        // Une seule fois : les programmes prédéfinis ajoutés pendant le bug du dossier commun
        // (23/10, base ouverte au mauvais endroit) étaient notés « déjà proposés » sans être dans
        // la vraie base, donc jamais réinstallés (ex. Football Endurance). On remet ceux qui manquent.
        if settings.didRepairMissingTemplates != true, StoreLocation.openError == nil {
            let before = Set(dataStore.allPrograms().compactMap(\.templateID))
            let missing = WorkoutProgram.templates.filter { t in t.templateID.map { !before.contains($0) } ?? false }
            missing.forEach { dataStore.upsert($0) }
            if !missing.isEmpty {
                log.log(.info, "Programmes prédéfinis manquants réinstallés : \(missing.map(\.name).joined(separator: ", "))")
            }
            settings.didRepairMissingTemplates = true
        }
        // Une seule fois : le RUN100 remplace l'UREVO et ne pilote pas l'inclinaison ; les
        // programmes personnels (et copies) passent à plat, mêmes identifiants.
        if settings.didFlattenPersonalPrograms != true, StoreLocation.openError == nil {
            let flattened = dataStore.allPrograms().filter { $0.templateID == nil }.compactMap { $0.flattenedIncline() }
            flattened.forEach { dataStore.upsert($0) }
            if !flattened.isEmpty {
                log.log(.info, "Programmes personnels mis à plat : \(flattened.map(\.name).joined(separator: ", "))")
            }
            settings.didFlattenPersonalPrograms = true
        }
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
