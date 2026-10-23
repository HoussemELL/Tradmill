import Foundation

// MARK: - Catalogue de programmes pour la montre

/// Étape d'un programme telle qu'affichée sur la montre (km/h, %).
public struct WatchProgramStep: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var kind: PhaseKind
    public var seconds: Int
    public var speedKmh: Double
    public var endSpeedKmh: Double?
    public var inclinePercent: Double
    public var targetZone: Int?
    /// Plage de la vitesse automatique [min, max] (phase pilotée par la FC).
    public var autoRange: [Double]?

    public init(_ p: ProgramPhase) {
        name = p.name
        kind = p.kind
        seconds = p.durationSeconds
        speedKmh = p.speedKmh
        endSpeedKmh = p.isRamp ? p.endSpeedKmh : nil
        inclinePercent = p.inclinePercent
        targetZone = p.autoSpeed?.targetZone ?? p.targetZone
        autoRange = p.autoSpeed.map { [$0.minKmh, $0.maxKmh] }
    }

    /// « 5,8 km/h », « 4,0 → 5,5 km/h » ou « auto 4,0–7,0 km/h ».
    public var speedText: String {
        if let r = autoRange, r.count == 2 { return String(format: "auto %.1f–%.1f km/h", r[0], r[1]) }
        if let e = endSpeedKmh { return String(format: "%.1f → %.1f km/h", speedKmh, e) }
        return String(format: "%.1f km/h", speedKmh)
    }
}

/// Groupe d'étapes : une phase simple (`repeatCount` = 1, `isBlock` faux) ou un bloc répété.
public struct WatchProgramGroup: Codable, Equatable, Hashable, Sendable {
    public var isBlock: Bool
    public var repeatCount: Int
    public var steps: [WatchProgramStep]
}

/// Résumé d'un programme pour la montre (liste et détail).
public struct WatchProgramSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var totalSeconds: Int
    public var maxSpeedKmh: Double
    public var maxInclinePercent: Double
    public var isAuto: Bool
    public var isLocked: Bool
    public var isTemplate: Bool
    public var groups: [WatchProgramGroup]
    /// Exercice Santé suggéré (course si une phase atteint 8 km/h).
    public var suggestsRunning: Bool

    public init(_ p: WorkoutProgram) {
        id = p.id
        name = p.name
        notes = p.notes
        totalSeconds = p.totalDurationSeconds
        maxSpeedKmh = p.maxSpeedKmh
        maxInclinePercent = p.schedule.map(\.phase.inclinePercent).max() ?? 0
        isAuto = p.hasAutoSpeed
        isLocked = p.isLocked
        isTemplate = p.templateID != nil
        groups = p.items.map { item in
            switch item {
            case let .phase(ph): return WatchProgramGroup(isBlock: false, repeatCount: 1, steps: [WatchProgramStep(ph)])
            case let .block(b): return WatchProgramGroup(isBlock: true, repeatCount: b.repeatCount, steps: b.phases.map(WatchProgramStep.init))
            }
        }
        suggestsRunning = p.maxSpeedKmh >= 8
    }

    public var stepCount: Int { groups.reduce(0) { $0 + $1.steps.count * max($1.repeatCount, 1) } }
}

/// État du tapis vu par l'iPhone, pour l'écran d'accueil de la montre.
public struct WatchTreadmillBrief: Codable, Equatable, Hashable, Sendable {
    public var name: String?
    /// Connecté et prêt à recevoir des commandes.
    public var ready: Bool
    public var simulated: Bool
    public var label: String

    public init(name: String?, ready: Bool, simulated: Bool, label: String) {
        self.name = name
        self.ready = ready
        self.simulated = simulated
        self.label = label
    }
}

/// Contexte publié par l'iPhone (WatchConnectivity `applicationContext`, dernier état gagnant) :
/// programmes, tapis, séance en cours, zones.
public struct WatchPhoneContext: Codable, Equatable, Sendable {
    public var programs: [WatchProgramSummary]
    public var treadmill: WatchTreadmillBrief
    /// Séance en cours sur l'iPhone (nil sinon).
    public var activeSessionID: UUID?
    public var activeProgramName: String?
    public var zoneBounds: [Int]
    public var sentAt: Date
    /// Dernier résultat de démarrage (la montre peut le récupérer si le message direct s'est perdu).
    public var lastStartResult: WatchStartResult?

    public init(programs: [WatchProgramSummary], treadmill: WatchTreadmillBrief, activeSessionID: UUID?,
                activeProgramName: String?, zoneBounds: [Int], sentAt: Date, lastStartResult: WatchStartResult? = nil) {
        self.programs = programs
        self.treadmill = treadmill
        self.activeSessionID = activeSessionID
        self.activeProgramName = activeProgramName
        self.zoneBounds = zoneBounds
        self.sentAt = sentAt
        self.lastStartResult = lastStartResult
    }

    /// Égalité hors date d'envoi (évite de republier un contexte inchangé).
    public func sameContent(as o: WatchPhoneContext?) -> Bool {
        guard let o else { return false }
        return programs == o.programs && treadmill == o.treadmill && activeSessionID == o.activeSessionID
            && activeProgramName == o.activeProgramName && zoneBounds == o.zoneBounds
            && lastStartResult == o.lastStartResult
    }

    public static let key = "foulee.context"
    /// Clé de l'état de séance dans la réponse à `requestContext`.
    public static let liveKey = "foulee.live"

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> WatchPhoneContext {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(WatchPhoneContext.self, from: data)
    }
}

// MARK: - Démarrage depuis la montre

/// Demande de démarrage envoyée par la montre (action explicite de l'utilisateur, confirmée).
public struct WatchStartRequest: Codable, Equatable, Sendable {
    public var requestID: UUID
    /// nil = séance libre.
    public var programID: UUID?
    public var issuedAt: Date

    public init(requestID: UUID = UUID(), programID: UUID?, issuedAt: Date) {
        self.requestID = requestID
        self.programID = programID
        self.issuedAt = issuedAt
    }
}

/// Réponse de l'iPhone : démarrage accepté (tapis en route) ou refusé, avec la raison.
public struct WatchStartResult: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var accepted: Bool
    public var sessionID: UUID?
    public var message: String

    public init(requestID: UUID, accepted: Bool, sessionID: UUID?, message: String) {
        self.requestID = requestID
        self.accepted = accepted
        self.sessionID = sessionID
        self.message = message
    }
}

/// Règles de l'iPhone pour une demande de démarrage venue de la montre.
public enum WatchStartPolicy {
    /// Au-delà, une demande est jugée périmée (message retardé) et refusée : on ne démarre jamais
    /// un tapis sur une action ancienne.
    public static let maxRequestAge: TimeInterval = 30

    public enum Decision: Equatable {
        case start(WorkoutProgram?)
        case refuse(String)
    }

    public static func evaluate(_ r: WatchStartRequest, now: Date, programs: [WorkoutProgram], treadmillReady: Bool,
                                sessionActive: Bool, diagnosticRunning: Bool, capabilities: TreadmillCapabilities) -> Decision {
        if now.timeIntervalSince(r.issuedAt) > maxRequestAge { return .refuse("Demande trop ancienne, renvoyez-la depuis la montre") }
        if sessionActive { return .refuse("Une séance est déjà en cours sur l'iPhone") }
        if diagnosticRunning { return .refuse("Un diagnostic est en cours sur l'iPhone") }
        if !treadmillReady { return .refuse("Tapis non connecté à l'iPhone") }
        guard let id = r.programID else { return .start(nil) }
        guard let p = programs.first(where: { $0.id == id }) else { return .refuse("Programme introuvable sur l'iPhone") }
        if let issue = ProgramValidator.validate(p, against: capabilities).first(where: { $0.severity == .error }) {
            return .refuse("Programme incompatible avec le tapis : \(issue.message)")
        }
        return .start(p)
    }
}

// MARK: - Commandes horodatées

/// Commande de séance depuis la montre, liée à une séance et horodatée : une commande retardée
/// (reconnexion) ou destinée à une autre séance est ignorée ; une reprise n'est jamais rejouée
/// en retard (pas de redémarrage du tapis sur un ancien message).
public struct WatchControl: Codable, Equatable, Sendable {
    public var command: WatchRemoteCommand
    public var sessionID: UUID?
    public var issuedAt: Date

    public init(command: WatchRemoteCommand, sessionID: UUID?, issuedAt: Date) {
        self.command = command
        self.sessionID = sessionID
        self.issuedAt = issuedAt
    }

    /// Délais d'acceptation : arrêt et pause restent utiles même un peu retardés ; reprise et
    /// réactivation du pilotage FC doivent être immédiates.
    public static func maxAge(for c: WatchRemoteCommand) -> TimeInterval {
        switch c {
        case .stop: return 120
        case .pause: return 30
        case .resume, .resumeAutopilot: return 8
        }
    }

    public func isAcceptable(now: Date, currentSessionID: UUID?) -> Bool {
        if let s = sessionID, let c = currentSessionID, s != c { return false }
        if sessionID != nil && currentSessionID == nil { return false }
        return now.timeIntervalSince(issuedAt) <= Self.maxAge(for: command)
    }
}

// MARK: - FC simulée (tests et démonstration)

/// FC simulée qui suit la vitesse avec un temps de réponse, pour tester le pilotage sans capteur.
/// Régime établi : `restBPM + gainPerKmh × vitesse` (+ inclinaison).
public struct SimulatedHeartModel: Equatable, Sendable {
    public var restBPM: Double
    public var gainPerKmh: Double
    public var gainPerInclinePercent: Double
    /// Constante de temps (s).
    public var tau: Double
    public private(set) var bpm: Double

    public init(restBPM: Double = 30, gainPerKmh: Double = 16, gainPerInclinePercent: Double = 2, tau: Double = 20) {
        self.restBPM = restBPM
        self.gainPerKmh = gainPerKmh
        self.gainPerInclinePercent = gainPerInclinePercent
        self.tau = tau
        bpm = 70
    }

    public func steadyState(speedKmh: Double, inclinePercent: Double) -> Double {
        max(60, restBPM + gainPerKmh * speedKmh + gainPerInclinePercent * inclinePercent)
    }

    public mutating func advance(dt: Double, speedKmh: Double, inclinePercent: Double) -> Int {
        let target = steadyState(speedKmh: speedKmh, inclinePercent: inclinePercent)
        let a = min(1, max(0, dt) / max(tau, 0.1))
        bpm += (target - bpm) * a
        return Int(bpm.rounded())
    }
}
