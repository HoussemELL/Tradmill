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
    /// Niveau (Football Endurance) et programme avancé (confirmation, jamais proposé d'office).
    public var level: Int?
    public var isAdvanced: Bool?

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
        level = p.level
        isAdvanced = p.isAdvanced ? true : nil
    }

    public var advanced: Bool { isAdvanced ?? false }

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
    /// un tapis sur une action ancienne. Doit rester inférieur à `watchGiveUpAfter`, pour que la
    /// montre n'annonce jamais « rien n'a démarré » alors que l'iPhone pourrait encore accepter.
    public static let maxRequestAge: TimeInterval = 20
    /// Délai après lequel la montre abandonne une demande sans réponse.
    public static let watchGiveUpAfter: TimeInterval = 30

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

// MARK: - Début de l'exercice Watch

/// Exercice Watch lancé alors que la bande de l'iPhone tourne déjà (montre réveillée ou app
/// lancée en retard, exercice relancé après une coupure) : son début est aligné sur le
/// démarrage de la bande et les pauses passées y sont reportées, pour que la séance Santé
/// couvre toute la séance (un seul exercice : il remplace dans Santé un morceau précédent,
/// même identifiant de synchronisation).
public enum WatchWorkoutAlignment {
    /// Retard en dessous duquel on garde l'heure courante.
    public static let minLag: TimeInterval = 5
    /// Au-delà, l'écart est jugé incohérent (horloge) : heure courante.
    public static let maxLag: TimeInterval = 4 * 3600
    /// Âge maximal de l'état de séance reçu de l'iPhone.
    public static let maxStatusAge: TimeInterval = 20

    public static func startDate(now: Date, live: WatchLiveStatus?) -> Date {
        guard let l = live, now.timeIntervalSince(l.sentAt) <= maxStatusAge,
              l.state == .running || l.state == .paused, let belt = l.beltStartDate else { return now }
        let lag = now.timeIntervalSince(belt)
        return lag > minLag && lag < maxLag ? belt : now
    }

    /// Pauses passées à reporter dans un exercice qui commence à `start` (aligné sur la bande).
    public static func pastPauses(start: Date, now: Date, live: WatchLiveStatus?) -> [DateInterval] {
        guard start < now, let pauses = live?.pauses else { return [] }
        return pauses.compactMap { p in
            guard p.count == 2, p[0] >= start, p[1] > p[0], p[1] <= now else { return nil }
            return DateInterval(start: p[0], end: p[1])
        }
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
