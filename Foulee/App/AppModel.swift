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
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let checkpointStore: CheckpointStore
    @ObservationIgnored private var timer: DispatchSourceTimer?

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
        log.log(.info, "Foulée démarrée")
        wireServices()
        seedTemplatesIfNeeded()
        recoverInterruptedSession()
        startLoop()
    }

    // MARK: - Câblage

    private func wireServices() {
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
        sessionService?.session.settings.zoneAlertsEnabled = settings.session.zoneAlertsEnabled
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
        let service = SessionService(session: s, checkpointStore: checkpointStore)
        service.onFinished = { [weak self] r in self?.sessionFinished(r) }
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
    func startSession() -> String? {
        guard let s = sessionService else { return "Aucune séance préparée" }
        switch s.session.start() {
        case .success:
            watch.beginSession(id: s.session.record.id, title: s.session.record.title)
            if settings.startWatchWorkoutWithSession && watch.isAppInstalled && watch.linkState != .mirrored {
                watch.launchWatchWorkout(running: (s.program?.maxSpeedKmh ?? s.session.effectiveTargets.speed) >= 8)
            }
            s.saveCheckpoint()
            updateIdleTimer()
            return nil
        case let .failure(e):
            return e.description
        }
    }

    func pauseSession() {
        sessionService?.session.pause()
        sessionService?.saveCheckpoint()
        if watch.linkState == .mirrored || watch.linkState == .connectivity { watch.send(.command(.pause)) }
    }

    func resumeSession() -> String? {
        guard let s = sessionService else { return nil }
        if case let .failure(e) = s.session.resume() { return e.description }
        if watch.watchState == .paused { watch.send(.command(.resume)) }
        return nil
    }

    func stopSession() {
        sessionService?.session.stop()
    }

    private func sessionFinished(_ record: SessionRecord) {
        var r = record
        let usedWatch = watch.usedDuringSession
        if usedWatch { r.healthStatus = .ownedByWatch }
        dataStore.upsert(r)
        lastFinishedRecordID = r.id
        if settings.endWatchWorkoutWithSession && usedWatch { watch.send(.command(.end)) }
        watch.endSessionTracking()
        updateIdleTimer()
        let plan = HealthSyncPlan.make(record: r, settings: settings.health, watchWorkoutUsed: usedWatch)
        log.log(.health, "Santé : \(plan.reason)")
        if plan.owner == .phone {
            let toSave = r
            Task { @MainActor [weak self] in
                guard let self else { return }
                var updated = toSave
                updated.healthStatus = await self.health.save(toSave, plan: plan)
                self.dataStore.upsert(updated)
            }
        }
    }

    /// Ferme l'écran de séance terminée pour en préparer une nouvelle.
    func closeFinishedSession() {
        guard let s = sessionService, s.session.status == .finished else { return }
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

    private func seedTemplatesIfNeeded() {
        guard !settings.didSeedTemplates else { return }
        if dataStore.allPrograms().isEmpty {
            WorkoutProgram.templates.forEach { dataStore.upsert($0) }
        }
        settings.didSeedTemplates = true
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
