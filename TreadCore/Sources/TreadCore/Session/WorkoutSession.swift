import Foundation

/// Réglages utilisés par une séance.
public struct SessionSettings: Codable, Equatable, Sendable {
    public var zones = HeartZoneSettings()
    public var stepEstimationEnabled = false
    public var strideLengthMeters = 0.70
    /// Poids pour l'estimation des calories ; nil = pas d'estimation.
    public var weightKg: Double?
    public var zoneAlertsEnabled = false
    public var zoneAlertDwell: TimeInterval = 20
    public var zoneAlertCooldown: TimeInterval = 90
    /// Vitesse de départ d'une séance libre.
    public var freeRunStartSpeed = 3.0
    /// Arrêter le tapis à la fin du programme (sinon la dernière consigne est maintenue).
    public var stopTreadmillAtProgramEnd = true

    public init() {}
}

/// Séance en cours : relie moteur de programme, contrôleur du tapis, FC, pas, zones et enregistrement.
/// Indépendante de la plateforme ; l'app y branche le BLE, la Watch et l'interface.
public final class WorkoutSession {
    public enum Status: Equatable, Sendable {
        case ready
        /// Start envoyé, attente du mouvement du tapis (le chrono ne tourne pas encore).
        case starting
        case running
        /// Reprise demandée, attente du mouvement.
        case resuming
        case paused(PauseReason)
        case finished
    }

    public enum PauseReason: Equatable, Sendable {
        case user
        case connectionLost
        case machineStopped(String)

        public var label: String {
            switch self {
            case .user: return "En pause"
            case .connectionLost: return "Connexion perdue"
            case let .machineStopped(r): return "Tapis arrêté (\(r))"
            }
        }
    }

    public struct ManualOverride: Equatable, Sendable {
        public var speed: Double?
        public var incline: Double?
    }

    public let controller: TreadmillController
    public let heartRate: HeartRateMonitor
    public let engine: ProgramEngine
    public let program: WorkoutProgram?
    public var settings: SessionSettings
    public let log: DiagnosticLog
    private let clock: () -> TimeInterval
    private let wallClock: () -> Date

    public private(set) var status: Status = .ready
    public private(set) var record: SessionRecord
    public private(set) var manualOverride: ManualOverride?
    public private(set) var freeRunTargets: (speed: Double, incline: Double)
    public private(set) var steps: StepTracker
    public private(set) var zoneTime = ZoneTimeAccumulator()
    public private(set) var currentZone: Int?
    public private(set) var lastAlert: String?
    public private(set) var message: String?

    public var onAlert: ((String) -> Void)?
    public var onFinished: ((SessionRecord) -> Void)?
    public var onChange: (() -> Void)?

    private var alerts: ZoneAlertDebouncer
    private var distanceCounter = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 4.5)
    private var energyCounter = CumulativeCounter(modulus: 1 << 16, maxRatePerSecond: 2)
    private var integratedDistance = 0.0
    private var estimatedKcal = 0.0
    private var lastSpeedSampleAt: TimeInterval?
    private var lastTickAt: TimeInterval?
    private var lastSampleAt: TimeInterval = -.infinity
    private let startMonotonic: TimeInterval
    private var hasDistanceCounter = false
    private var pauseStartedAt: TimeInterval?

    public init(program: WorkoutProgram?, controller: TreadmillController, heartRate: HeartRateMonitor,
                settings: SessionSettings, treadmillName: String?, simulated: Bool, log: DiagnosticLog,
                clock: @escaping () -> TimeInterval, wallClock: @escaping () -> Date) {
        self.program = program
        self.controller = controller
        self.heartRate = heartRate
        self.settings = settings
        self.log = log
        self.clock = clock
        self.wallClock = wallClock
        self.engine = ProgramEngine(schedule: program?.schedule ?? [])
        self.startMonotonic = clock()
        self.record = SessionRecord(startDate: wallClock(), program: program, treadmillName: treadmillName,
                                    profileID: controller.profile.id, simulated: simulated)
        self.record.zoneSettings = settings.zones
        self.steps = StepTracker(estimationEnabled: settings.stepEstimationEnabled, strideLengthMeters: settings.strideLengthMeters)
        self.alerts = ZoneAlertDebouncer(dwell: settings.zoneAlertDwell, cooldown: settings.zoneAlertCooldown)
        self.freeRunTargets = (controller.capabilities.snapSpeed(settings.freeRunStartSpeed), 0)
    }

    // MARK: - Lecture

    public var sessionTime: TimeInterval { clock() - startMonotonic }
    public var activeTime: TimeInterval { engine.activeElapsed(at: clock()) }
    public var position: EnginePosition { engine.position(at: clock()) }
    public var currentPhase: ScheduledPhase? { engine.currentPhase ?? (status == .ready || status == .starting ? engine.schedule.first : nil) }
    public var nextPhase: ScheduledPhase? {
        if engine.currentPhase == nil { return engine.schedule.count > 1 && (status == .ready || status == .starting) ? engine.schedule[1] : nil }
        return engine.nextPhase
    }
    public var distanceMeters: Double { hasDistanceCounter ? distanceCounter.sessionTotal : integratedDistance }
    public var distanceSource: MetricSource { hasDistanceCounter ? .treadmill : (integratedDistance > 0 ? .estimated : .none) }
    public var treadmillKcal: Double? { energyCounter.sessionTotal > 0 ? energyCounter.sessionTotal : nil }
    public var estimatedKcalValue: Double? { settings.weightKg == nil ? nil : estimatedKcal }

    /// Consignes effectives : modification manuelle > phase courante > séance libre.
    public var effectiveTargets: (speed: Double, incline: Double) {
        let base: (Double, Double)
        if let p = currentPhase?.phase { base = (p.speedKmh, p.inclinePercent) } else { base = freeRunTargets }
        return (manualOverride?.speed ?? base.0, manualOverride?.incline ?? base.1)
    }

    public var isFreeRun: Bool { engine.isFreeRun }

    // MARK: - Actions explicites

    public func start() -> Result<Void, ControllerError> {
        guard status == .ready else { return .failure(.invalidState("séance déjà démarrée")) }
        if let p = program {
            let issues = ProgramValidator.validate(p, against: controller.capabilities).filter { $0.severity == .error }
            if let first = issues.first {
                return .failure(.outOfRange("\(first.phaseName ?? p.name) : \(first.message)"))
            }
        }
        let t = effectiveTargets
        let result = controller.start(targetSpeed: t.speed, targetIncline: controller.capabilities.supportsInclinationControl ? t.incline : nil)
        if case .success = result {
            status = .starting
            event(.start, "Démarrage demandé" + (program.map { " — \($0.name)" } ?? " — séance libre"))
        }
        changed()
        return result
    }

    public func pause() {
        switch status {
        case .running, .starting, .resuming: break
        default: return
        }
        if case let .failure(e) = controller.pause() {
            message = "Pause logicielle impossible (\(e)). Utilisez le bouton ou la clé de sécurité du tapis."
            log.log(.warning, message!)
        }
        enterPause(.user)
    }

    public func resume() -> Result<Void, ControllerError> {
        guard case .paused = status else { return .failure(.invalidState("la séance n'est pas en pause")) }
        let t = effectiveTargets
        let r = controller.resume(targetSpeed: t.speed, targetIncline: controller.capabilities.supportsInclinationControl ? t.incline : nil)
        if case .success = r {
            status = .resuming
            event(.resume, "Reprise demandée")
        } else if case let .failure(e) = r {
            message = "\(e)"
        }
        changed()
        return r
    }

    /// Arrête le tapis (si possible) et termine la séance.
    public func stop() {
        guard status != .finished else { return }
        if case let .failure(e) = controller.stop() {
            message = "Arrêt logiciel impossible (\(e)). Arrêtez le tapis avec son bouton ou la clé de sécurité."
            log.log(.warning, message!)
            event(.stop, "Fin de séance — arrêt du tapis NON envoyé (\(e))")
        } else {
            event(.stop, "Fin de séance — arrêt demandé au tapis")
        }
        finish()
    }

    public func skipToNextPhase() {
        guard !engine.isFreeRun, status == .running || isPaused else { return }
        let from = engine.currentPhase?.displayName ?? "?"
        let events = engine.skipToNextPhase(at: clock())
        event(.phaseSkipped, "Phase « \(from) » passée manuellement")
        handle(engineEvents: events)
        changed()
    }

    /// Modification manuelle : remplace la consigne jusqu'au prochain palier.
    public func setManualSpeed(_ kmh: Double) -> Result<Void, ControllerError> {
        let v = controller.capabilities.snapSpeed(kmh)
        if let e = controller.checkSpeed(v) { return .failure(e) }
        if engine.isFreeRun { freeRunTargets.speed = v } else {
            manualOverride = ManualOverride(speed: v, incline: manualOverride?.incline)
            event(.manualOverride, String(format: "Vitesse manuelle %.1f km/h (jusqu'au prochain palier)", v))
        }
        let r = isPaused ? .success(()) : controller.setTargetSpeed(v, origin: .user)
        changed()
        return r
    }

    public func setManualIncline(_ pct: Double) -> Result<Void, ControllerError> {
        guard controller.capabilities.supportsInclinationControl else { return .failure(.notSupported("inclinaison")) }
        let v = controller.capabilities.snapInclination(pct)
        if engine.isFreeRun { freeRunTargets.incline = v } else {
            manualOverride = ManualOverride(speed: manualOverride?.speed, incline: v)
            event(.manualOverride, String(format: "Inclinaison manuelle %.0f %% (jusqu'au prochain palier)", v))
        }
        let r = isPaused ? .success(()) : controller.setTargetIncline(v, origin: .user)
        changed()
        return r
    }

    public func adjustSpeed(by delta: Double) -> Result<Void, ControllerError> {
        setManualSpeed(effectiveTargets.speed + delta)
    }

    public func adjustIncline(by delta: Double) -> Result<Void, ControllerError> {
        setManualIncline(effectiveTargets.incline + delta)
    }

    public var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    // MARK: - Entrées

    /// Télémétrie décodée (brancher sur `controller.onTelemetry`).
    public func handleTelemetry(_ d: TreadmillData, at now: TimeInterval) {
        if let raw = d.totalDistanceMeters {
            hasDistanceCounter = true
            let before = distanceCounter.sessionTotal
            if let a = distanceCounter.ingest(UInt64(raw), at: now) { logAnomaly("distance", a) }
            steps.ingestDistance(deltaMeters: distanceCounter.sessionTotal - before, sessionElapsed: now - startMonotonic)
        } else if let v = d.instantaneousSpeedKmh {
            // Pas de distance fournie : intégration de la vitesse mesurée.
            if let last = lastSpeedSampleAt, now > last, now - last < 5 {
                let delta = v / 3.6 * (now - last)
                integratedDistance += delta
                steps.ingestDistance(deltaMeters: delta, sessionElapsed: now - startMonotonic)
            }
        }
        if d.instantaneousSpeedKmh != nil { lastSpeedSampleAt = now }
        if let raw = d.totalEnergyKcal {
            if let a = energyCounter.ingest(UInt64(raw), at: now) { logAnomaly("énergie", a) }
        }
        if let raw = d.stepCountExtension {
            steps.ingestTreadmill(raw: raw, at: now)
        }
        if let hr = d.heartRateBpm {
            heartRate.ingest(HeartRateReading(bpm: Int(hr), receivedAt: now, source: .treadmill))
        }
    }

    public func ingestWatchSteps(total: Double) {
        steps.ingestWatch(total: total, at: clock())
    }

    public func ingestWatchActiveEnergy(kcal: Double) {
        record.calories.healthKitActiveKcal = kcal
    }

    public func handle(controllerEvent e: ControllerEvent) {
        switch e {
        case let .linkLost(wasActive):
            steps.markDiscontinuity()
            distanceCounter.markDiscontinuity()
            energyCounter.markDiscontinuity()
            lastSpeedSampleAt = nil
            event(.connectionLost, wasActive ? "Connexion perdue pendant l'activité — état du tapis inconnu" : "Connexion perdue")
            if status == .running || status == .starting || status == .resuming { enterPause(.connectionLost) }
        case .speedMismatch(let target, let observed):
            event(.speedMismatch, String(format: "Consigne %.1f km/h acquittée, mesure %@", target,
                                         observed.map { String(format: "%.1f", $0) } ?? "—"))
        case .inclineMismatch(let target, let observed):
            event(.inclineMismatch, String(format: "Consigne %.0f %%, mesure %@", target,
                                           observed.map { String(format: "%.1f", $0) } ?? "—"))
        case let .commandFailed(m):
            event(.commandFailed, m)
            message = m
        case let .startFailed(m):
            event(.commandFailed, m)
            message = m
            if status == .starting && controller.state != .startUnconfirmed {
                status = .ready
            } else if status == .resuming && controller.state != .startUnconfirmed {
                status = .paused(.user)
            }
        case let .machineStopped(reason, paused):
            event(.machineStopped, "Tapis \(paused ? "en pause" : "arrêté") : \(reason)")
            if status == .running || status == .starting || status == .resuming {
                enterPause(.machineStopped(reason))
            }
        case .externalMovement:
            event(.externalMovement, "Le tapis tourne sans commande de l'app")
        case let .stopFailed(m):
            message = m
            event(.commandFailed, m)
        default:
            break
        }
        changed()
    }

    /// À appeler régulièrement (timer + chaque notification BLE).
    public func tick() {
        let now = clock()
        controller.tick()
        // Démarrage effectif du chrono quand le mouvement est observé.
        if status == .starting && controller.state == .running {
            status = .running
            log.log(.session, "Chrono démarré (mouvement du tapis observé)")
            handle(engineEvents: engine.start(at: now))
        } else if status == .resuming && controller.state == .running {
            status = .running
            if let p = pauseStartedAt { record.pausedSeconds += now - p; pauseStartedAt = nil }
            handle(engineEvents: engine.resume(at: now))
        }
        if status == .running {
            handle(engineEvents: engine.update(at: now))
        }
        updateHeartAndZones(now: now)
        if status == .running, let w = settings.weightKg, let last = lastTickAt, let v = controller.telemetry.speedKmh,
           controller.telemetry.isFresh(now: now) {
            estimatedKcal += EnergyEstimator.kcalPerMinute(speedKmh: v, gradePercent: controller.telemetry.inclinePercent ?? 0, weightKg: w)
                * max(0, min(now - last, 5)) / 60
        }
        lastTickAt = now
        if now - lastSampleAt >= 1, status != .ready, status != .finished {
            lastSampleAt = now
            appendSample(now: now)
        }
        changed()
    }

    // MARK: - Reprise après crash

    public struct Checkpoint: Codable, Equatable {
        public var record: SessionRecord
        public var engine: ProgramEngine.Snapshot
        public var savedAt: Date
    }

    public func checkpoint() -> Checkpoint {
        Checkpoint(record: snapshotRecord(), engine: engine.snapshot(at: clock()), savedAt: wallClock())
    }

    /// Transforme un point de sauvegarde en séance interrompue (sans jamais relancer le tapis).
    public static func recoveredRecord(from cp: Checkpoint) -> SessionRecord {
        var r = cp.record
        r.interrupted = true
        r.endDate = r.endDate ?? cp.savedAt
        r.activeSeconds = max(r.activeSeconds, cp.engine.accumulatedActive)
        r.events.append(SessionEvent(t: r.samples.last?.t ?? 0, kind: .recovered,
                                     detail: "Séance récupérée après fermeture inattendue de l'app"))
        r.recomputeAggregates()
        return r
    }

    // MARK: - Interne

    private func enterPause(_ reason: PauseReason) {
        let now = clock()
        engine.pause(at: now)
        if pauseStartedAt == nil { pauseStartedAt = now }
        zoneTime.interrupt()
        alerts.reset()
        status = .paused(reason)
        event(.pause, reason.label)
        changed()
    }

    private func finish() {
        let now = clock()
        if let p = pauseStartedAt { record.pausedSeconds += now - p; pauseStartedAt = nil }
        engine.finish(at: now)
        status = .finished
        appendSample(now: now)
        event(.finish, "Séance terminée")
        record = snapshotRecord()
        record.endDate = wallClock()
        log.log(.session, String(format: "Séance terminée : %.0f s actives, %.0f m", record.activeSeconds, record.distanceMeters))
        changed()
        onFinished?(record)
    }

    private func snapshotRecord() -> SessionRecord {
        var r = record
        r.activeSeconds = engine.activeElapsed(at: clock())
        r.distanceMeters = distanceMeters
        r.distanceSource = distanceSource
        r.steps = steps.value
        r.stepsSource = steps.source
        r.zoneSeconds = zoneTime.seconds
        r.calories.treadmillKcal = treadmillKcal
        r.calories.estimatedKcal = estimatedKcalValue
        r.recomputeAggregates()
        return r
    }

    private func handle(engineEvents: [EngineEvent]) {
        for e in engineEvents {
            switch e {
            case let .phaseStarted(index, skipped):
                manualOverride = nil
                alerts.reset()
                let sp = engine.schedule[index]
                if !skipped.isEmpty {
                    let names = skipped.map { engine.schedule[$0].displayName }.joined(separator: ", ")
                    event(.phaseSkipped, "Phases écoulées sans être appliquées (app suspendue ?) : \(names)")
                }
                event(.phaseChange, String(format: "%@ — %.1f km/h, %.0f %%", sp.displayName, sp.phase.speedKmh, sp.phase.inclinePercent))
                applyPhaseTargets(sp.phase)
            case .finished:
                event(.info, "Programme terminé")
                if settings.stopTreadmillAtProgramEnd {
                    stop()
                }
            }
        }
    }

    private func applyPhaseTargets(_ p: ProgramPhase) {
        guard status == .running else { return }
        // N'envoie que ce qui change par rapport à la consigne déjà demandée (pas de doublon).
        if controller.speed.requested.map({ abs($0 - p.speedKmh) > 0.001 }) ?? true || controller.speed.status == .none {
            if case let .failure(e) = controller.setTargetSpeed(p.speedKmh, origin: .program) {
                event(.commandFailed, "Consigne vitesse de la phase refusée : \(e)")
            }
        }
        if controller.capabilities.supportsInclinationControl,
           controller.incline.requested.map({ abs($0 - p.inclinePercent) > 0.001 }) ?? true {
            if case let .failure(e) = controller.setTargetIncline(p.inclinePercent, origin: .program) {
                event(.commandFailed, "Consigne inclinaison de la phase refusée : \(e)")
            }
        }
    }

    private func updateHeartAndZones(now: TimeInterval) {
        let st = heartRate.status(now: now)
        if let bpm = st.liveBPM {
            currentZone = settings.zones.zone(for: bpm)
        } else {
            currentZone = nil
        }
        if status == .running {
            zoneTime.add(zone: currentZone, at: now)
            if settings.zoneAlertsEnabled,
               let alert = alerts.evaluate(currentZone: currentZone, targetZone: engine.currentPhase?.phase.targetZone, at: now) {
                let text: String
                switch alert {
                case let .above(t, c): text = "Zone \(c) : au-dessus de la cible Z\(t)"
                case let .below(t, c): text = "Zone \(c) : en dessous de la cible Z\(t)"
                }
                lastAlert = text
                event(.zoneAlert, text)
                onAlert?(text)
            }
        } else {
            zoneTime.interrupt()
        }
    }

    private func appendSample(now: TimeInterval) {
        let tel = controller.telemetry
        let fresh = tel.isFresh(now: now)
        let hr = heartRate.status(now: now)
        let t = effectiveTargets
        record.samples.append(SessionSample(
            t: now - startMonotonic,
            active: engine.activeElapsed(at: now),
            speed: fresh ? tel.speedKmh : nil,
            incline: fresh ? tel.inclinePercent : nil,
            targetSpeed: status == .running ? t.speed : nil,
            targetIncline: status == .running && controller.capabilities.supportsInclinationControl ? t.incline : nil,
            hr: hr.liveBPM,
            hrSource: hr.liveBPM != nil ? heartRate.activeSource : nil,
            zone: currentZone,
            distance: distanceMeters,
            steps: steps.value,
            phase: engine.currentIndex,
            paused: status != .running))
    }

    private func event(_ kind: SessionEvent.Kind, _ detail: String) {
        record.events.append(SessionEvent(t: clock() - startMonotonic, kind: kind, detail: detail))
        log.log(.session, detail)
    }

    private func logAnomaly(_ what: String, _ a: CumulativeCounter.Anomaly) {
        switch a {
        case let .wrapped(f, t): log.log(.info, "Compteur \(what) : débordement \(f) → \(t)")
        case let .reset(f, t): log.log(.info, "Compteur \(what) remis à zéro par le tapis (\(f) → \(t)), cumul conservé")
        case let .implausibleJump(f, t): log.log(.warning, "Compteur \(what) : saut ignoré \(f) → \(t)")
        }
    }

    private func changed() { onChange?() }
}
