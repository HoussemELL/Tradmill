import Foundation

/// Tapis FTMS simulé au niveau des octets : reçoit les écritures Control Point,
/// répond par indications, notifie Machine Status et Treadmill Data.
///
/// Sert au mode simulateur de l'app (clairement identifié) et aux tests.
/// Les « quirks » permettent de reproduire les comportements rapportés pour l'URTM047 ;
/// ce sont des hypothèses de test, pas une description du firmware réel.
public final class SimulatedTreadmill {
    public struct Quirks: Equatable, Sendable {
        /// Start sans consigne de vitesse préalable : acquitté mais aucun mouvement.
        public var requiresSpeedBeforeStart = false
        /// Consignes de vitesse reçues pendant le compte à rebours : acquittées mais ignorées.
        public var ignoresSpeedDuringCountdown = false
        /// Consignes de vitesse acquittées mais jamais appliquées (cas pathologique).
        public var ignoresAllSpeedCommands = false
        /// Consignes reçues pendant une accélération/décélération : acquittées mais ignorées
        /// (une des hypothèses pour le symptôme « acquittée sans effet »).
        public var ignoresSpeedWhileRamping = false
        /// Réponse du Control Point à Set Target Speed (cas observé : aucune réponse tapis arrêté).
        public var speedResponse: SpeedResponseMode = .normal
        /// Envoie le statut 0x05 « consigne vitesse modifiée » quand une consigne est appliquée.
        public var reportsSpeedStatus = true
        /// Démarre toujours à la vitesse minimale, quelle que soit la consigne reçue à l'arrêt
        /// (observé sur l'URTM047 le 23/10).
        public var startsAtMinimumSpeed = false
        /// Ne répond jamais aux commandes (test des délais).
        public var dropsResponses = false
        /// Envoie l'extension Step Count (bit 13).
        public var reportsStepCount = false
        /// Annonce le champ distance mais le laisse à 0 (compteur figé).
        public var frozenDistance = false
        public var countdown: TimeInterval = 3
        public var accelerationKmhPerSecond: Double = 0.6
        public var inclineRatePercentPerSecond: Double = 0.5
        public var dataInterval: TimeInterval = 1
        public var responseLatency: TimeInterval = 0.05
        public init() {}

        public static var urtm047Like: Quirks {
            var q = Quirks()
            q.requiresSpeedBeforeStart = true
            q.ignoresSpeedDuringCountdown = true
            q.startsAtMinimumSpeed = true
            q.reportsStepCount = false
            return q
        }
    }

    public enum SpeedResponseMode: Equatable, Sendable {
        case normal
        case silentWhenStopped
        case silent
        case late(seconds: TimeInterval)
    }

    public enum RunState: Equatable, Sendable { case idle, countdown(until: TimeInterval), running, paused, stopped }

    public var quirks: Quirks
    public let speedRange: SpeedRange
    public let inclinationRange: InclinationRange
    public let feature: FitnessMachineFeature

    public private(set) var runState: RunState = .idle
    public private(set) var hasControl = false
    public private(set) var targetSpeed: Double?
    public private(set) var currentSpeed: Double = 0
    public private(set) var targetIncline: Double = 0
    public private(set) var currentIncline: Double = 0
    public private(set) var distanceMeters: Double = 0
    public private(set) var steps: Double = 0
    public private(set) var energyKcal: Double = 0
    public private(set) var elapsed: Double = 0
    public private(set) var receivedCommands: [ControlCommand] = []

    public var onIndication: (([UInt8]) -> Void)?
    public var onStatus: (([UInt8]) -> Void)?
    public var onData: (([UInt8]) -> Void)?

    private var outbox: [(at: TimeInterval, kind: Int, bytes: [UInt8])] = []
    private var lastAdvance: TimeInterval?
    private var lastDataAt: TimeInterval = -.infinity

    public init(quirks: Quirks = Quirks(),
                speedRange: SpeedRange = SpeedRange(minKmh: 1, maxKmh: 12, incrementKmh: 0.1),
                inclinationRange: InclinationRange = InclinationRange(minPercent: 0, maxPercent: 9, incrementPercent: 1)) {
        self.quirks = quirks
        self.speedRange = speedRange
        self.inclinationRange = inclinationRange
        self.feature = FitnessMachineFeature(
            machine: [.totalDistance, .inclination, .expendedEnergy, .elapsedTime],
            targetSettings: [.speed, .inclination])
    }

    /// Écriture reçue sur le Control Point.
    public func receiveControlPoint(_ bytes: [UInt8], now: TimeInterval) {
        guard let op = bytes.first else { return }
        let command: ControlCommand
        do { command = try ControlCommand.decode(bytes) } catch {
            respond(op, .opCodeNotSupported, now: now)
            return
        }
        receivedCommands.append(command)
        if quirks.dropsResponses { return }
        if command != .requestControl && command != .reset && !hasControl {
            respond(op, .controlNotPermitted, now: now)
            return
        }
        switch command {
        case .requestControl:
            hasControl = true
            respond(op, .success, now: now)
        case .reset:
            hasControl = false
            runState = .idle
            targetSpeed = nil
            respond(op, .success, now: now)
        case let .setTargetSpeed(kmh):
            guard kmh >= speedRange.minKmh - 0.001, kmh <= speedRange.maxKmh + 0.001 else {
                respond(op, .invalidParameter, now: now); return
            }
            let stopped = runState != .running && !isCountdown
            switch quirks.speedResponse {
            case .normal: respond(op, .success, now: now)
            case .silentWhenStopped: if !stopped { respond(op, .success, now: now) }
            case .silent: break
            case let .late(delay): respond(op, .success, now: now + delay)
            }
            let ramping = runState == .running && abs(currentSpeed - (targetSpeed ?? 0)) > 0.05
            let ignored = quirks.ignoresAllSpeedCommands
                || (quirks.ignoresSpeedDuringCountdown && isCountdown)
                || (quirks.ignoresSpeedWhileRamping && ramping)
            if !ignored {
                targetSpeed = kmh
                if quirks.reportsSpeedStatus { status(.targetSpeedChanged(kmh: kmh), now: now) }
            }
        case let .setTargetInclination(p):
            guard p >= inclinationRange.minPercent - 0.001, p <= inclinationRange.maxPercent + 0.001 else {
                respond(op, .invalidParameter, now: now); return
            }
            targetIncline = p
            respond(op, .success, now: now)
            status(.targetInclinationChanged(percent: p), now: now)
        case .startOrResume:
            respond(op, .success, now: now)
            if quirks.requiresSpeedBeforeStart && targetSpeed == nil {
                return // acquitté, sans effet
            }
            if targetSpeed == nil || quirks.startsAtMinimumSpeed { targetSpeed = speedRange.minKmh }
            if runState == .paused {
                runState = .running
            } else {
                resetWorkoutCounters()
                runState = .countdown(until: now + quirks.countdown)
            }
            status(.startedOrResumedByUser, now: now)
        case .stop:
            respond(op, .success, now: now)
            runState = .stopped
            targetSpeed = nil
            status(.stoppedOrPausedByUser(paused: false), now: now)
        case .pause:
            respond(op, .success, now: now)
            runState = .paused
            status(.stoppedOrPausedByUser(paused: true), now: now)
        }
    }

    /// Simule l'appui sur la clé de sécurité.
    public func pullSafetyKey(now: TimeInterval) {
        runState = .stopped
        targetSpeed = nil
        currentSpeed = 0
        status(.stoppedBySafetyKey, now: now)
    }

    /// Simule l'appui sur le bouton Stop du tapis ou de sa télécommande.
    public func pressStopButton(now: TimeInterval) {
        runState = .stopped
        targetSpeed = nil
        status(.stoppedOrPausedByUser(paused: false), now: now)
    }

    public func advance(to now: TimeInterval) {
        let dt = lastAdvance.map { max(0, now - $0) } ?? 0
        lastAdvance = now
        if case let .countdown(until) = runState, now >= until {
            runState = .running
        }
        let goal: Double = runState == .running ? (targetSpeed ?? 0) : 0
        currentSpeed = approach(currentSpeed, goal, rate: quirks.accelerationKmhPerSecond, dt: dt)
        if runState == .running || isCountdown || currentSpeed > 0 {
            currentIncline = approach(currentIncline, targetIncline, rate: quirks.inclineRatePercentPerSecond, dt: dt)
        }
        if currentSpeed > 0 {
            let meters = currentSpeed / 3.6 * dt
            distanceMeters += meters
            elapsed += dt
            // Longueur de pas approximative pour la simulation
            let stride = currentSpeed < 7 ? 0.7 : 1.0
            steps += meters / stride
            energyKcal += (0.1 * (currentSpeed * 1000 / 60) + 3.5) * 70 / 1000 * 5 / 60 * dt
        }
        flush(now: now)
        if now - lastDataAt >= quirks.dataInterval {
            lastDataAt = now
            var d = TreadmillData()
            d.instantaneousSpeedKmh = (currentSpeed * 100).rounded() / 100
            d.totalDistanceMeters = quirks.frozenDistance ? 0 : UInt32(distanceMeters)
            d.inclinationPercent = (currentIncline * 10).rounded() / 10
            d.rampAngleDegrees = nil
            d.totalEnergyKcal = UInt16(energyKcal)
            d.energyPerHourKcal = nil
            d.energyPerMinuteKcal = nil
            d.elapsedTimeSeconds = UInt16(min(elapsed, 65535))
            if quirks.reportsStepCount { d.stepCountExtension = UInt32(steps) }
            onData?(d.encode())
        }
    }

    public var isCountdown: Bool {
        if case .countdown = runState { return true }
        return false
    }

    // MARK: - Interne

    private func resetWorkoutCounters() {
        distanceMeters = 0
        steps = 0
        energyKcal = 0
        elapsed = 0
    }

    private func approach(_ v: Double, _ goal: Double, rate: Double, dt: Double) -> Double {
        let step = rate * dt
        if abs(goal - v) <= step { return goal }
        return v + (goal > v ? step : -step)
    }

    private func respond(_ op: UInt8, _ code: ControlResultCode, now: TimeInterval) {
        outbox.append((now + quirks.responseLatency, 0, ControlPointResponse(requestOpCode: op, result: code).encode()))
        outbox.sort { $0.at < $1.at }
    }

    private func status(_ s: MachineStatus, now: TimeInterval) {
        outbox.append((now + quirks.responseLatency, 1, s.encode()))
    }

    private func flush(now: TimeInterval) {
        while let first = outbox.first, first.at <= now {
            outbox.removeFirst()
            if first.kind == 0 { onIndication?(first.bytes) } else { onStatus?(first.bytes) }
        }
    }
}

/// Lien simulé reliant un `SimulatedTreadmill` à un `TreadmillController`
/// par les mêmes chemins d'octets que le BLE réel.
public final class SimulatedFTMSLink: ControlPointWriter {
    public let treadmill: SimulatedTreadmill
    public private(set) weak var controller: TreadmillController?
    public private(set) var isConnected = false
    private let clock: () -> TimeInterval

    public init(treadmill: SimulatedTreadmill, clock: @escaping () -> TimeInterval) {
        self.treadmill = treadmill
        self.clock = clock
    }

    public func connect(to controller: TreadmillController) {
        self.controller = controller
        controller.queue.writer = self
        treadmill.onIndication = { [weak controller] b in controller?.handleControlPointIndication(b) }
        treadmill.onStatus = { [weak controller] b in controller?.handleMachineStatus(b) }
        treadmill.onData = { [weak controller] b in controller?.handleTreadmillData(b) }
        isConnected = true
        controller.log.log(.ble, "SIMULATEUR connecté (aucun appareil réel)")
        controller.linkDidConnect()
        // Les capacités passent par les mêmes décodeurs que le BLE réel.
        let caps = TreadmillCapabilities(
            speed: (try? SpeedRange.decode(treadmill.speedRange.encode())) ?? treadmill.speedRange,
            inclination: try? InclinationRange.decode(treadmill.inclinationRange.encode()),
            feature: try? FitnessMachineFeature.decode(treadmill.feature.encode()),
            speedRangeFromDevice: true, inclinationRangeFromDevice: true)
        controller.setCapabilities(caps)
        controller.linkDidBecomeReady()
    }

    public func disconnect() {
        isConnected = false
        treadmill.onIndication = nil
        treadmill.onStatus = nil
        treadmill.onData = nil
        controller?.linkDidDisconnect()
    }

    public func writeControlPoint(_ bytes: [UInt8]) -> Bool {
        guard isConnected else { return false }
        treadmill.receiveControlPoint(bytes, now: clock())
        controller?.handleControlPointWrite(error: nil)
        return true
    }

    public func advance() {
        treadmill.advance(to: clock())
    }
}
