import Foundation

/// Type de phase, utilisé pour l'affichage et la couleur.
public enum PhaseKind: String, Codable, CaseIterable, Sendable {
    case warmup, work, recovery, steady, cooldown

    public var label: String {
        switch self {
        case .warmup: return "Échauffement"
        case .work: return "Effort"
        case .recovery: return "Récupération"
        case .steady: return "Allure stable"
        case .cooldown: return "Retour au calme"
        }
    }
}

/// Une phase : durée, vitesse cible, inclinaison cible, zone cardiaque indicative.
public struct ProgramPhase: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: PhaseKind
    public var durationSeconds: Int
    public var speedKmh: Double
    public var inclinePercent: Double
    /// Zone 1…5 indicative (aucun pilotage automatique du tapis par la FC en V1).
    public var targetZone: Int?

    public init(id: UUID = UUID(), name: String, kind: PhaseKind = .steady, durationSeconds: Int,
                speedKmh: Double, inclinePercent: Double = 0, targetZone: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.speedKmh = speedKmh
        self.inclinePercent = inclinePercent
        self.targetZone = targetZone
    }

    public func withNewID() -> ProgramPhase {
        var p = self
        p.id = UUID()
        return p
    }
}

/// Bloc répété N fois (ex. 6 × [1 min rapide, 2 min lent]).
public struct RepeatBlock: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var repeatCount: Int
    public var phases: [ProgramPhase]

    public init(id: UUID = UUID(), name: String, repeatCount: Int, phases: [ProgramPhase]) {
        self.id = id
        self.name = name
        self.repeatCount = repeatCount
        self.phases = phases
    }

    public var singleIterationSeconds: Int { phases.reduce(0) { $0 + $1.durationSeconds } }
}

public enum ProgramItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    case phase(ProgramPhase)
    case block(RepeatBlock)

    public var id: UUID {
        switch self {
        case let .phase(p): return p.id
        case let .block(b): return b.id
        }
    }

    public var durationSeconds: Int {
        switch self {
        case let .phase(p): return p.durationSeconds
        case let .block(b): return b.singleIterationSeconds * max(b.repeatCount, 0)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, phase, block }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "phase": self = .phase(try c.decode(ProgramPhase.self, forKey: .phase))
        case "block": self = .block(try c.decode(RepeatBlock.self, forKey: .block))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "type d'élément inconnu : \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .phase(p):
            try c.encode("phase", forKey: .type)
            try c.encode(p, forKey: .phase)
        case let .block(b):
            try c.encode("block", forKey: .type)
            try c.encode(b, forKey: .block)
        }
    }

    public func withNewIDs() -> ProgramItem {
        switch self {
        case let .phase(p): return .phase(p.withNewID())
        case let .block(b):
            var nb = b
            nb.id = UUID()
            nb.phases = b.phases.map { $0.withNewID() }
            return .block(nb)
        }
    }
}

public struct WorkoutProgram: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var items: [ProgramItem]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, notes: String = "", items: [ProgramItem],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.notes = notes
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var totalDurationSeconds: Int { items.reduce(0) { $0 + $1.durationSeconds } }

    /// Copie avec de nouveaux identifiants (duplication, import).
    public func duplicated(name: String? = nil, now: Date = Date()) -> WorkoutProgram {
        WorkoutProgram(name: name ?? "\(self.name) (copie)", notes: notes,
                       items: items.map { $0.withNewIDs() }, createdAt: now, updatedAt: now)
    }

    /// Phases à plat, blocs déroulés, avec heure de début relative.
    public var schedule: [ScheduledPhase] {
        var out: [ScheduledPhase] = []
        var t = 0
        for item in items {
            switch item {
            case let .phase(p):
                out.append(ScheduledPhase(index: out.count, phase: p, start: t, repetition: nil))
                t += p.durationSeconds
            case let .block(b):
                guard b.repeatCount > 0 else { continue }
                for i in 1...b.repeatCount {
                    for p in b.phases {
                        out.append(ScheduledPhase(index: out.count, phase: p, start: t,
                                                  repetition: .init(blockName: b.name, iteration: i, count: b.repeatCount)))
                        t += p.durationSeconds
                    }
                }
            }
        }
        return out
    }

    public var maxSpeedKmh: Double { schedule.map(\.phase.speedKmh).max() ?? 0 }
}

public struct ScheduledPhase: Equatable, Sendable, Identifiable {
    public struct Repetition: Equatable, Sendable {
        public var blockName: String
        public var iteration: Int
        public var count: Int
    }

    public var index: Int
    public var phase: ProgramPhase
    /// Début relatif en secondes depuis le début du programme.
    public var start: Int
    public var repetition: Repetition?

    public var id: Int { index }
    public var end: Int { start + phase.durationSeconds }

    public var displayName: String {
        if let r = repetition { return "\(phase.name) · \(r.iteration)/\(r.count)" }
        return phase.name
    }
}

public extension WorkoutProgram {
    /// Programmes fournis au premier lancement (modifiables).
    static var templates: [WorkoutProgram] {
        [
            WorkoutProgram(name: "Marche active 30 min", notes: "Marche régulière avec une légère côte.", items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 300, speedKmh: 3.5, inclinePercent: 0, targetZone: 1)),
                .phase(.init(name: "Marche", kind: .steady, durationSeconds: 600, speedKmh: 5.0, inclinePercent: 1, targetZone: 2)),
                .phase(.init(name: "Côte", kind: .work, durationSeconds: 600, speedKmh: 5.0, inclinePercent: 4, targetZone: 3)),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 300, speedKmh: 3.5, inclinePercent: 0, targetZone: 1)),
            ]),
            WorkoutProgram(name: "Intervalles marche/course", notes: "6 répétitions course/marche.", items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 300, speedKmh: 4.5, targetZone: 2)),
                .block(.init(name: "Intervalles", repeatCount: 6, phases: [
                    .init(name: "Course", kind: .work, durationSeconds: 60, speedKmh: 8.5, targetZone: 4),
                    .init(name: "Marche", kind: .recovery, durationSeconds: 120, speedKmh: 5.0, targetZone: 2),
                ])),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 300, speedKmh: 4.0, targetZone: 1)),
            ]),
            WorkoutProgram(name: "Collines", notes: "Paliers d'inclinaison à vitesse constante.", items: [
                .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 300, speedKmh: 4.0)),
                .block(.init(name: "Montées", repeatCount: 3, phases: [
                    .init(name: "Montée", kind: .work, durationSeconds: 180, speedKmh: 5.0, inclinePercent: 6, targetZone: 3),
                    .init(name: "Plat", kind: .recovery, durationSeconds: 120, speedKmh: 5.0, inclinePercent: 1, targetZone: 2),
                ])),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 300, speedKmh: 3.5)),
            ]),
        ]
    }
}
