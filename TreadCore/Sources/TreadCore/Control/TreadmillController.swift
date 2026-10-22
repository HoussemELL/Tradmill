import Foundation

/// Suivi d'une consigne : valeur demandée, acquittée, annoncée par le tapis, et état de vérification.
/// La valeur réellement mesurée vient toujours de la télémétrie, jamais d'ici.
public struct TargetTracking: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case none
        /// En file ou envoyée, réponse non reçue.
        case pending
        /// Acquittée (réponse « succès ») ; valeur pas encore observée.
        case acknowledged
        /// Valeur observée dans la télémétrie, dans la tolérance.
        case reached
        /// Acquittée mais non observée dans le délai attendu.
        case mismatch
        /// Envoi refusé, sans réponse ou annulé.
        case failed(String)
        /// Mémorisée, sera appliquée au prochain démarrage/reprise.
        case deferred
    }

    public var requested: Double?
    public var acknowledged: Double?
    public var machineReported: Double?
    public var status: Status = .none
    public var origin: CommandOrigin?
    public var deadline: TimeInterval?
    public var resendsUsed = 0
    var outOfToleranceSince: TimeInterval?
    var observedAtSend: Double?

    public init() {}
}

/// Dernières valeurs reçues du tapis (fusion des paquets partiels « More Data »).
public struct TreadmillTelemetry: Equatable, Sendable {
    public var speedKmh: Double?
    public var inclinePercent: Double?
    public var totalDistanceMeters: UInt32?
    public var totalEnergyKcal: UInt16?
    public var heartRateBpm: UInt8?
    public var elapsedSeconds: UInt16?
    public var stepCountExtension: UInt32?
    public var lastPacketAt: TimeInterval?
    public var lastSpeedAt: TimeInterval?
    public var packetCount = 0
    public var malformedCount = 0

    public init() {}

    public func isFresh(now: TimeInterval, maxAge: TimeInterval = 5) -> Bool {
        guard let t = lastSpeedAt else { return false }
        return now - t <= maxAge
    }

    mutating func merge(_ d: TreadmillData, now: TimeInterval) {
        packetCount += 1
        lastPacketAt = now
        if let v = d.instantaneousSpeedKmh { speedKmh = v; lastSpeedAt = now }
        if let v = d.inclinationPercent { inclinePercent = v }
        if let v = d.totalDistanceMeters { totalDistanceMeters = v }
        if let v = d.totalEnergyKcal { totalEnergyKcal = v }
        if d.flags.contains(.heartRate) { heartRateBpm = d.heartRateBpm }
        if let v = d.elapsedTimeSeconds { elapsedSeconds = v }
        if let v = d.stepCountExtension { stepCountExtension = v }
    }
}

public enum BeltState: Equatable, Sendable {
    case disconnected
    case idle
    case starting(String)
    case awaitingMovement(deadline: TimeInterval)
    /// Start acquitté mais aucun mouvement observé dans le délai.
    case startUnconfirmed
    case running
    case pausing
    case paused
    case stopping
    case stopped
    /// Connexion perdue pendant une activité : état réel du tapis inconnu.
    case linkLost

    public var label: String {
        switch self {
        case .disconnected: return "Déconnecté"
        case .idle: return "Prêt"
        case let .starting(step): return "Démarrage… (\(step))"
        case .awaitingMovement: return "Attente du mouvement…"
        case .startUnconfirmed: return "Démarrage non confirmé"
        case .running: return "En marche"
        case .pausing: return "Pause demandée…"
        case .paused: return "En pause"
        case .stopping: return "Arrêt demandé…"
        case .stopped: return "Arrêté"
        case .linkLost: return "Connexion perdue — état inconnu"
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .awaitingMovement, .startUnconfirmed, .running, .pausing, .stopping: return true
        default: return false
        }
    }
}

public enum ControllerEvent: Equatable, Sendable {
    case stateChanged(BeltState)
    case beltStarted
    case startFailed(String)
    case speedReached(Double)
    case speedMismatch(target: Double, observed: Double?)
    case inclineReached(Double)
    case inclineMismatch(target: Double, observed: Double?)
    case commandFailed(String)
    case stopConfirmed
    case stopFailed(String)
    case pauseConfirmed
    /// Arrêt ou pause constaté sans commande de l'app (bouton, télécommande, clé, vitesse nulle).
    case machineStopped(reason: String, paused: Bool)
    /// Mouvement constaté sans commande de l'app.
    case externalMovement
    case machineTargetReported(speed: Double?, incline: Double?)
    case controlLost
    case linkLost(wasActive: Bool)
}

public enum ControllerError: Error, Equatable, CustomStringConvertible {
    case notReady
    case invalidState(String)
    case outOfRange(String)
    case notSupported(String)

    public var description: String {
        switch self {
        case .notReady: return "Tapis non connecté ou non prêt"
        case let .invalidState(s): return "Action impossible : \(s)"
        case let .outOfRange(s): return "Valeur hors plage : \(s)"
        case let .notSupported(s): return "Non supporté : \(s)"
        }
    }
}

/// Contrôleur FTMS d'un tapis : séquences de démarrage par profil, consignes vérifiées
/// par la télémétrie, pause/arrêt avec confirmation, aucune action automatique après reconnexion.
public final class TreadmillController {
    public let queue: CommandQueue
    public let log: DiagnosticLog
    public let clock: () -> TimeInterval

    public private(set) var profile: TreadmillProfile
    public private(set) var capabilities: TreadmillCapabilities
    public private(set) var state: BeltState = .disconnected {
        didSet { if state != oldValue { emit(.stateChanged(state)) } }
    }
    public private(set) var telemetry = TreadmillTelemetry()
    public private(set) var speed = TargetTracking()
    public private(set) var incline = TargetTracking()
    public private(set) var hasControl = false
    public private(set) var lastMessage: String?

    public var onEvent: ((ControllerEvent) -> Void)?
    public var onTelemetry: ((TreadmillData, TimeInterval) -> Void)?

    private var sequenceID = 0
    private var pendingFinal: (speed: Double?, incline: Double?)?
    private var zeroSpeedSince: TimeInterval?
    private var stateBeforeSequence: BeltState = .idle
    /// Vitesse nulle observée depuis le dernier arrêt/pause : sert à distinguer une
    /// décélération d'un vrai redémarrage non commandé.
    private var zeroObservedSinceHalt = true
    /// Type d'arrêt annoncé par le tapis pendant une pause/arrêt demandé.
    private var reportedHaltIsPause: Bool?

    public init(profile: TreadmillProfile, log: DiagnosticLog, clock: @escaping () -> TimeInterval) {
        self.profile = profile
        self.capabilities = profile.fallbackCapabilities
        self.log = log
        self.clock = clock
        self.queue = CommandQueue(configuration: .init(responseTimeout: profile.responseTimeout,
                                                       minimumSpacing: profile.commandSpacing))
        queue.log = log
    }

    // MARK: - Cycle de vie du lien

    public func setProfile(_ p: TreadmillProfile) {
        profile = p
        queue.configuration = .init(responseTimeout: p.responseTimeout, minimumSpacing: p.commandSpacing)
        log.log(.info, "Profil matériel : \(p.name)")
    }

    public func setCapabilities(_ c: TreadmillCapabilities) {
        capabilities = c
        log.log(.info, String(format: "Capacités : vitesse %.2f–%.2f km/h (pas %.2f, %@)",
                              c.speed.minKmh, c.speed.maxKmh, c.speed.incrementKmh,
                              c.speedRangeFromDevice ? "lu sur le tapis" : "valeur du profil")
                + (c.inclination.map { String(format: ", inclinaison %.1f–%.1f %% (pas %.1f, %@)",
                                              $0.minPercent, $0.maxPercent, $0.incrementPercent,
                                              c.inclinationRangeFromDevice ? "lu sur le tapis" : "valeur du profil") }
                   ?? ", inclinaison non disponible"))
    }

    public func linkDidConnect() {
        state = .idle
        zeroObservedSinceHalt = true
        telemetry = TreadmillTelemetry()
        speed = TargetTracking()
        incline = TargetTracking()
        hasControl = false
        lastMessage = nil
    }

    /// Indications Control Point et notifications actives : les commandes peuvent partir.
    public func linkDidBecomeReady() {
        queue.setLinkReady(true, now: clock())
        log.log(.ble, "Lien FTMS prêt (indications/notifications actives). Aucune commande envoyée automatiquement.")
    }

    public func linkDidDisconnect() {
        let wasActive = state.isActive || state == .paused
        sequenceID += 1
        pendingFinal = nil
        hasControl = false
        queue.setLinkReady(false, now: clock())
        state = wasActive ? .linkLost : .disconnected
        if wasActive {
            lastMessage = "Connexion perdue : l'app ne peut pas confirmer l'état du tapis. Utilisez le bouton ou la clé de sécurité du tapis."
            log.log(.warning, lastMessage!)
        }
        emit(.linkLost(wasActive: wasActive))
    }

    // MARK: - Entrées BLE

    public func handleTreadmillData(_ bytes: [UInt8]) {
        let now = clock()
        let (data, error) = TreadmillData.decodePartial(bytes)
        if let error {
            telemetry.malformedCount += 1
            log.log(.warning, "Treadmill Data : \(error) — champs complets conservés", bytes: bytes)
        } else {
            log.log(.telemetry, summary(data), bytes: bytes)
        }
        if !data.trailingBytes.isEmpty {
            log.log(.warning, "Treadmill Data : \(data.trailingBytes.count) octet(s) non interprété(s)", bytes: data.trailingBytes)
        }
        if data.flags.contains(.stepCountExtension), telemetry.stepCountExtension == nil {
            log.log(.info, "Le tapis envoie le champ d'extension « Step Count » (bit 13, hors FTMS 1.0)")
        }
        telemetry.merge(data, now: now)
        onTelemetry?(data, now)
        evaluate(now: now)
    }

    public func handleMachineStatus(_ bytes: [UInt8]) {
        let status: MachineStatus
        do { status = try MachineStatus.decode(bytes) } catch {
            log.log(.warning, "Machine Status illisible : \(error)", bytes: bytes)
            return
        }
        log.log(.status, status.description, bytes: bytes)
        switch status {
        case .controlPermissionLost:
            hasControl = false
            lastMessage = "Le tapis a retiré le contrôle à l'app."
            emit(.controlLost)
        case .reset:
            hasControl = false
        case .stoppedBySafetyKey:
            abortActivity(reason: "clé de sécurité", paused: false)
        case let .stoppedOrPausedByUser(paused):
            // Le même statut confirme aussi nos propres Stop/Pause : l'état final
            // n'est retenu qu'une fois la vitesse nulle observée (voir evaluate).
            if state == .stopping || state == .pausing {
                reportedHaltIsPause = paused
                evaluate(now: clock())
            } else {
                abortActivity(reason: paused ? "pause sur le tapis" : "arrêt sur le tapis", paused: paused)
            }
        case .startedOrResumedByUser:
            switch state {
            case .starting, .awaitingMovement, .startUnconfirmed: break
            default: emit(.externalMovement)
            }
        case let .targetSpeedChanged(v):
            speed.machineReported = v
            emit(.machineTargetReported(speed: v, incline: nil))
        case let .targetInclinationChanged(v):
            incline.machineReported = v
            emit(.machineTargetReported(speed: nil, incline: v))
        case .other:
            break
        }
    }

    public func handleControlPointIndication(_ bytes: [UInt8]) {
        queue.handleIndication(bytes, now: clock())
    }

    public func handleControlPointWrite(error: String?) {
        queue.handleWriteResult(error: error, now: clock())
    }

    public func tick() {
        let now = clock()
        queue.tick(now: now)
        evaluate(now: now)
    }

    // MARK: - Commandes utilisateur / programme

    public var isMoving: Bool { (telemetry.speedKmh ?? 0) >= 0.1 }

    /// Démarrage explicite. La séquence dépend du profil.
    public func start(targetSpeed: Double, targetIncline: Double?) -> Result<Void, ControllerError> {
        guard queue.isLinkReady else { return .failure(.notReady) }
        switch state {
        case .idle, .stopped: break
        case .paused: return .failure(.invalidState("tapis en pause, utilisez Reprendre"))
        default: return .failure(.invalidState("démarrage déjà en cours ou tapis actif (\(state.label))"))
        }
        if let e = checkSpeed(targetSpeed) { return .failure(e) }
        if let i = targetIncline, let e = checkIncline(i) { return .failure(e) }
        if isMoving {
            return .failure(.invalidState("le tapis est déjà en mouvement"))
        }
        log.log(.session, "Démarrage demandé (profil \(profile.name)) : séquence "
                + profile.startSteps.map(\.description).joined(separator: " → ") + " → attente du mouvement → consignes")
        beginSequence(steps: profile.startSteps, finalSpeed: targetSpeed, finalIncline: targetIncline, origin: .startSequence)
        return .success(())
    }

    /// Reprise explicite après pause, arrêt ou reconnexion. Jamais déclenchée automatiquement.
    public func resume(targetSpeed: Double, targetIncline: Double?) -> Result<Void, ControllerError> {
        guard queue.isLinkReady else { return .failure(.notReady) }
        switch state {
        case .paused, .stopped, .idle, .startUnconfirmed, .running: break
        default: return .failure(.invalidState(state.label))
        }
        if let e = checkSpeed(targetSpeed) { return .failure(e) }
        if let i = targetIncline, let e = checkIncline(i) { return .failure(e) }
        if isMoving {
            // Le tapis tourne déjà (ex. après reconnexion) : pas de Start, seulement les consignes.
            log.log(.session, "Reprise : tapis déjà en mouvement, envoi des consignes sans Start")
            beginSequence(steps: hasControl ? [] : [.requestControl], finalSpeed: targetSpeed,
                          finalIncline: targetIncline, origin: .resumeSequence, alreadyMoving: true)
        } else {
            log.log(.session, "Reprise : séquence " + profile.resumeSteps.map(\.description).joined(separator: " → "))
            beginSequence(steps: profile.resumeSteps, finalSpeed: targetSpeed, finalIncline: targetIncline, origin: .resumeSequence)
        }
        return .success(())
    }

    public func pause() -> Result<Void, ControllerError> {
        guard queue.isLinkReady else { return .failure(.notReady) }
        switch state {
        case .running, .awaitingMovement, .starting, .startUnconfirmed: break
        default: return .failure(.invalidState(state.label))
        }
        sequenceID += 1
        pendingFinal = nil
        reportedHaltIsPause = nil
        state = .pausing
        queue.enqueue(.pause, origin: .safety, now: clock()) { [weak self] outcome in
            guard let self else { return }
            if outcome.isSuccess {
                if !self.isMoving, self.state == .pausing {
                    self.state = .paused
                    self.emit(.pauseConfirmed)
                }
            } else {
                self.lastMessage = "Pause \(outcome). Utilisez Arrêter ou le bouton du tapis."
                self.log.log(.error, self.lastMessage!)
                self.state = self.isMoving ? .running : .idle
                self.emit(.commandFailed(self.lastMessage!))
            }
        }
        return .success(())
    }

    /// Arrêt : toujours accepté si le lien est prêt. L'arrêt n'est « confirmé » qu'avec une vitesse nulle observée.
    public func stop() -> Result<Void, ControllerError> {
        guard queue.isLinkReady else { return .failure(.notReady) }
        sequenceID += 1
        pendingFinal = nil
        reportedHaltIsPause = nil
        state = .stopping
        queue.enqueue(.stop, origin: .safety, now: clock()) { [weak self] outcome in
            guard let self else { return }
            if outcome.isSuccess {
                if !self.isMoving, self.state == .stopping {
                    self.state = .stopped
                    self.emit(.stopConfirmed)
                }
            } else {
                self.lastMessage = "Arrêt NON confirmé (\(outcome)). Utilisez le bouton ou la clé de sécurité du tapis."
                self.log.log(.error, self.lastMessage!)
                self.state = self.isMoving ? .running : .idle
                self.emit(.stopFailed(self.lastMessage!))
            }
        }
        return .success(())
    }

    /// Nouvelle consigne de vitesse. Hors marche, elle est mémorisée pour la prochaine reprise.
    @discardableResult
    public func setTargetSpeed(_ kmh: Double, origin: CommandOrigin) -> Result<Void, ControllerError> {
        if let e = checkSpeed(kmh) { return .failure(e) }
        let value = (kmh * 100).rounded() / 100
        switch state {
        case .running, .startUnconfirmed:
            guard queue.isLinkReady else { return .failure(.notReady) }
            sendSpeed(value, origin: origin)
        case .starting, .awaitingMovement:
            pendingFinal = (value, pendingFinal?.incline)
            speed.requested = value
            speed.status = .deferred
        default:
            speed.requested = value
            speed.status = .deferred
            speed.origin = origin
        }
        return .success(())
    }

    @discardableResult
    public func setTargetIncline(_ percent: Double, origin: CommandOrigin) -> Result<Void, ControllerError> {
        if let e = checkIncline(percent) { return .failure(e) }
        let value = (percent * 10).rounded() / 10
        switch state {
        case .running, .startUnconfirmed:
            guard queue.isLinkReady else { return .failure(.notReady) }
            sendIncline(value, origin: origin)
        case .starting, .awaitingMovement:
            pendingFinal = (pendingFinal?.speed, value)
            incline.requested = value
            incline.status = .deferred
        default:
            incline.requested = value
            incline.status = .deferred
            incline.origin = origin
        }
        return .success(())
    }

    /// Commande brute pour le diagnostic (journalisée, sérialisée par la file).
    public func sendDiagnosticCommand(_ c: ControlCommand, completion: @escaping (CommandOutcome) -> Void) {
        queue.enqueue(c, origin: .diagnostic, now: clock()) { [weak self] outcome in
            if c == .requestControl, outcome.isSuccess { self?.hasControl = true }
            completion(outcome)
        }
    }

    // MARK: - Validation

    func checkSpeed(_ v: Double) -> ControllerError? {
        guard capabilities.supportsSpeedControl else { return .notSupported("consigne de vitesse") }
        let r = capabilities.speed
        if v < r.minKmh - 0.001 || v > r.maxKmh + 0.001 {
            return .outOfRange(String(format: "%.2f km/h (plage %.1f–%.1f)", v, r.minKmh, r.maxKmh))
        }
        return nil
    }

    func checkIncline(_ v: Double) -> ControllerError? {
        guard capabilities.supportsInclinationControl, let r = capabilities.inclination else {
            return abs(v) < 0.001 ? nil : .notSupported("consigne d'inclinaison")
        }
        if v < r.minPercent - 0.001 || v > r.maxPercent + 0.001 {
            return .outOfRange(String(format: "%.1f %% (plage %.1f–%.1f)", v, r.minPercent, r.maxPercent))
        }
        return nil
    }

    // MARK: - Séquences

    private func beginSequence(steps: [TreadmillProfile.Step], finalSpeed: Double, finalIncline: Double?,
                               origin: CommandOrigin, alreadyMoving: Bool = false) {
        sequenceID += 1
        stateBeforeSequence = state
        pendingFinal = (finalSpeed, finalIncline)
        speed.requested = finalSpeed
        speed.status = .deferred
        speed.resendsUsed = 0
        if !alreadyMoving {
            // Après un arrêt, la consigne précédente du tapis n'est plus fiable.
            speed.acknowledged = nil
            incline.acknowledged = nil
        }
        if let i = finalIncline { incline.requested = i; incline.status = .deferred; incline.resendsUsed = 0 }
        lastMessage = nil
        runStep(steps, index: 0, seq: sequenceID, origin: origin, alreadyMoving: alreadyMoving)
    }

    private func runStep(_ steps: [TreadmillProfile.Step], index: Int, seq: Int, origin: CommandOrigin, alreadyMoving: Bool) {
        guard seq == sequenceID else { return }
        if index >= steps.count {
            if alreadyMoving {
                state = .running
                applyPendingFinal()
            } else {
                state = .awaitingMovement(deadline: clock() + profile.beltStartTimeout)
                evaluate(now: clock())
            }
            return
        }
        let step = steps[index]
        state = .starting(step.description)
        let next: () -> Void = { [weak self] in
            self?.runStep(steps, index: index + 1, seq: seq, origin: origin, alreadyMoving: alreadyMoving)
        }
        let fail: (CommandOutcome) -> Void = { [weak self] outcome in
            self?.abortSequence(seq: seq, message: "\(step) \(outcome)")
        }
        switch step {
        case .requestControl:
            queue.enqueue(.requestControl, origin: origin, now: clock()) { [weak self] outcome in
                guard let self, seq == self.sequenceID else { return }
                if outcome.isSuccess { self.hasControl = true; next() } else { fail(outcome) }
            }
        case .setInitialSpeed:
            let target = pendingFinal?.speed ?? profile.initialSpeedKmh
            let s = profile.initialSpeed(target: target, capabilities: capabilities)
            queue.enqueue(.setTargetSpeed(kmh: s), origin: origin, now: clock()) { [weak self] outcome in
                guard let self, seq == self.sequenceID else { return }
                if outcome.isSuccess {
                    self.speed.acknowledged = s
                    next()
                } else { fail(outcome) }
            }
        case .startOrResume:
            queue.enqueue(.startOrResume, origin: origin, now: clock()) { [weak self] outcome in
                guard let self, seq == self.sequenceID else { return }
                if outcome.isSuccess { next() } else { fail(outcome) }
            }
        }
    }

    private func abortSequence(seq: Int, message: String) {
        guard seq == sequenceID else { return }
        sequenceID += 1
        pendingFinal = nil
        lastMessage = "Démarrage interrompu : \(message)"
        log.log(.error, lastMessage!)
        speed.status = .failed(message)
        zeroObservedSinceHalt = !isMoving
        state = isMoving ? .running : (stateBeforeSequence == .paused ? .paused : .idle)
        emit(.startFailed(lastMessage!))
    }

    private func applyPendingFinal() {
        guard let final = pendingFinal else { return }
        pendingFinal = nil
        if let s = final.speed {
            if let ack = speed.acknowledged, abs(ack - s) < 0.001 {
                // Vitesse initiale = cible : il reste à vérifier qu'elle est observée.
                speed.requested = s
                speed.status = .acknowledged
                speed.deadline = clock() + profile.speedSettleTime(from: telemetry.speedKmh, to: s)
            } else {
                sendSpeed(s, origin: .startSequence)
            }
        }
        if let i = final.incline, capabilities.supportsInclinationControl {
            sendIncline(i, origin: .startSequence)
        }
    }

    private func sendSpeed(_ value: Double, origin: CommandOrigin, isResend: Bool = false) {
        speed.requested = value
        speed.status = .pending
        speed.origin = origin
        speed.deadline = nil
        speed.outOfToleranceSince = nil
        speed.observedAtSend = telemetry.speedKmh
        if !isResend { speed.resendsUsed = 0 }
        queue.enqueue(.setTargetSpeed(kmh: value), origin: origin, now: clock()) { [weak self] outcome in
            guard let self, self.speed.requested == value else { return }
            if outcome.isSuccess {
                self.speed.acknowledged = value
                self.speed.status = .acknowledged
                self.speed.deadline = self.clock() + self.profile.speedSettleTime(from: self.speed.observedAtSend, to: value)
                self.evaluate(now: self.clock())
            } else if case .cancelled = outcome {
                // Remplacée par une consigne plus récente ou annulée par un arrêt : rien à signaler.
            } else {
                self.speed.status = .failed("\(outcome)")
                self.emit(.commandFailed("Vitesse \(String(format: "%.1f", value)) km/h \(outcome)"))
            }
        }
    }

    private func sendIncline(_ value: Double, origin: CommandOrigin, isResend: Bool = false) {
        incline.requested = value
        incline.status = .pending
        incline.origin = origin
        incline.deadline = nil
        incline.outOfToleranceSince = nil
        incline.observedAtSend = telemetry.inclinePercent
        if !isResend { incline.resendsUsed = 0 }
        queue.enqueue(.setTargetInclination(percent: value), origin: origin, now: clock()) { [weak self] outcome in
            guard let self, self.incline.requested == value else { return }
            if outcome.isSuccess {
                self.incline.acknowledged = value
                self.incline.status = .acknowledged
                self.incline.deadline = self.clock() + self.profile.inclineSettleTime(from: self.incline.observedAtSend, to: value)
                self.evaluate(now: self.clock())
            } else if case .cancelled = outcome {
            } else {
                self.incline.status = .failed("\(outcome)")
                self.emit(.commandFailed("Inclinaison \(String(format: "%.0f", value)) % \(outcome)"))
            }
        }
    }

    private func abortActivity(reason: String, paused: Bool) {
        sequenceID += 1
        pendingFinal = nil
        queue.cancelAll(reason: reason)
        zeroObservedSinceHalt = !isMoving
        state = paused ? .paused : .stopped
        lastMessage = "Tapis \(paused ? "en pause" : "arrêté") : \(reason)"
        emit(.machineStopped(reason: reason, paused: paused))
    }

    // MARK: - Évaluation périodique

    private func evaluate(now: TimeInterval) {
        let moving = isMoving
        let fresh = telemetry.isFresh(now: now)
        switch state {
        case let .awaitingMovement(deadline):
            if moving {
                log.log(.session, String(format: "Mouvement observé (%.2f km/h)", telemetry.speedKmh ?? 0))
                state = .running
                emit(.beltStarted)
                applyPendingFinal()
            } else if now > deadline {
                state = .startUnconfirmed
                lastMessage = "Start acquitté mais aucun mouvement observé après \(Int(profile.beltStartTimeout)) s. Aucun nouvel essai automatique."
                log.log(.warning, lastMessage!)
                emit(.startFailed(lastMessage!))
            }
        case .startUnconfirmed:
            if moving {
                log.log(.session, "Mouvement observé tardivement")
                state = .running
                emit(.beltStarted)
                applyPendingFinal()
            }
        case .stopping:
            if !moving && fresh && queue.inFlightCommand != .stop {
                state = .stopped
                emit(.stopConfirmed)
            }
        case .pausing:
            if !moving && fresh && queue.inFlightCommand != .pause {
                if reportedHaltIsPause == false {
                    // Le tapis a annoncé un arrêt et non une pause.
                    log.log(.warning, "Pause demandée mais le tapis signale un arrêt")
                    state = .stopped
                    emit(.stopConfirmed)
                } else {
                    state = .paused
                    emit(.pauseConfirmed)
                }
            }
        case .running:
            if fresh && !moving {
                if let since = zeroSpeedSince {
                    if now - since > 3 {
                        zeroSpeedSince = nil
                        abortActivity(reason: "vitesse nulle observée", paused: false)
                        return
                    }
                } else {
                    zeroSpeedSince = now
                }
            } else {
                zeroSpeedSince = nil
            }
            verifySpeed(now: now)
            verifyIncline(now: now)
        case .idle, .stopped, .paused:
            if !moving {
                zeroObservedSinceHalt = true
            } else if fresh && zeroObservedSinceHalt {
                log.log(.warning, "Mouvement du tapis constaté sans commande de l'app")
                state = .running
                emit(.externalMovement)
            }
        case .disconnected, .linkLost, .starting:
            break
        }
    }

    private func verifySpeed(now: TimeInterval) {
        guard let goal = speed.acknowledged, speed.requested == goal else { return }
        let obs = telemetry.speedKmh
        let within = obs.map { abs($0 - goal) <= profile.speedToleranceKmh } ?? false
        switch speed.status {
        case .acknowledged:
            if within {
                speed.status = .reached
                log.log(.session, String(format: "Vitesse %.2f km/h observée", goal))
                emit(.speedReached(goal))
            } else if let d = speed.deadline, now > d {
                if speed.resendsUsed < profile.maxTargetResends {
                    speed.resendsUsed += 1
                    log.log(.warning, String(format: "Vitesse %.2f non observée (mesure %@) : renvoi unique de la consigne (sans Start)",
                                             goal, obs.map { String(format: "%.2f", $0) } ?? "—"))
                    let used = speed.resendsUsed
                    sendSpeed(goal, origin: .reconcile, isResend: true)
                    speed.resendsUsed = used
                } else {
                    speed.status = .mismatch
                    lastMessage = String(format: "Écart vitesse : consigne %.1f km/h acquittée, mesure %@ km/h",
                                         goal, obs.map { String(format: "%.1f", $0) } ?? "—")
                    log.log(.warning, lastMessage!)
                    emit(.speedMismatch(target: goal, observed: obs))
                }
            }
        case .mismatch:
            if within {
                speed.status = .reached
                log.log(.session, String(format: "Vitesse %.2f km/h finalement observée", goal))
                emit(.speedReached(goal))
            }
        case .reached:
            if within {
                speed.outOfToleranceSince = nil
            } else if let since = speed.outOfToleranceSince {
                if now - since > profile.speedSettleBase {
                    speed.status = .mismatch
                    speed.outOfToleranceSince = nil
                    log.log(.warning, String(format: "La vitesse mesurée s'écarte de la consigne %.2f km/h", goal))
                    emit(.speedMismatch(target: goal, observed: obs))
                }
            } else {
                speed.outOfToleranceSince = now
            }
        default:
            break
        }
    }

    private func verifyIncline(now: TimeInterval) {
        guard let goal = incline.acknowledged, incline.requested == goal else { return }
        let obs = telemetry.inclinePercent
        let within = obs.map { abs($0 - goal) <= profile.inclineTolerancePercent } ?? false
        switch incline.status {
        case .acknowledged:
            if within {
                incline.status = .reached
                emit(.inclineReached(goal))
            } else if let d = incline.deadline, now > d {
                if incline.resendsUsed < profile.maxTargetResends {
                    incline.resendsUsed += 1
                    log.log(.warning, String(format: "Inclinaison %.1f non observée : renvoi unique de la consigne", goal))
                    let used = incline.resendsUsed
                    sendIncline(goal, origin: .reconcile, isResend: true)
                    incline.resendsUsed = used
                } else {
                    incline.status = .mismatch
                    log.log(.warning, String(format: "Écart inclinaison : consigne %.1f %%, mesure %@", goal,
                                             obs.map { String(format: "%.1f", $0) } ?? "—"))
                    emit(.inclineMismatch(target: goal, observed: obs))
                }
            }
        case .mismatch:
            if within {
                incline.status = .reached
                emit(.inclineReached(goal))
            }
        default:
            break
        }
    }

    private func emit(_ e: ControllerEvent) {
        onEvent?(e)
    }

    private func summary(_ d: TreadmillData) -> String {
        var parts: [String] = []
        if let v = d.instantaneousSpeedKmh { parts.append(String(format: "v=%.2f", v)) }
        if let v = d.inclinationPercent { parts.append(String(format: "incl=%.1f", v)) }
        if let v = d.totalDistanceMeters { parts.append("dist=\(v)m") }
        if let v = d.totalEnergyKcal { parts.append("kcal=\(v)") }
        if let v = d.heartRateBpm { parts.append("fc=\(v)") }
        if let v = d.elapsedTimeSeconds { parts.append("t=\(v)s") }
        if let v = d.stepCountExtension { parts.append("pas=\(v)") }
        if d.flags.contains(.moreData) { parts.append("(suite)") }
        return parts.joined(separator: " ")
    }
}
