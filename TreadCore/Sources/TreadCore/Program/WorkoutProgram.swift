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
    /// Zone 1…5 indicative : affichage et alertes, jamais de pilotage (sauf `autoSpeed`).
    public var targetZone: Int?
    /// Vitesse de fin d'une phase progressive : la consigne passe linéairement de
    /// `speedKmh` à `endSpeedKmh` par incréments du tapis (nil = vitesse constante).
    public var endSpeedKmh: Double?
    /// Phase dont la vitesse est réglée automatiquement par la FC (programme « Zone 2 auto »).
    /// `speedKmh` vaut alors la vitesse de départ. Seules ces phases pilotent le tapis par la FC.
    public var autoSpeed: AutoSpeedSettings?

    public init(id: UUID = UUID(), name: String, kind: PhaseKind = .steady, durationSeconds: Int,
                speedKmh: Double, inclinePercent: Double = 0, targetZone: Int? = nil,
                endSpeedKmh: Double? = nil, autoSpeed: AutoSpeedSettings? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.speedKmh = speedKmh
        self.inclinePercent = inclinePercent
        self.targetZone = targetZone
        self.endSpeedKmh = endSpeedKmh
        self.autoSpeed = autoSpeed
    }

    public var isRamp: Bool { endSpeedKmh.map { abs($0 - speedKmh) > 0.001 } ?? false }
    public var isAuto: Bool { autoSpeed != nil }

    /// Vitesse prévue après `elapsed` secondes dans la phase (rampe incluse), avant arrondi
    /// à l'incrément du tapis. Pour une phase automatique : la vitesse de départ.
    public func plannedSpeed(at elapsed: TimeInterval) -> Double {
        guard let end = endSpeedKmh, isRamp, durationSeconds > 0 else { return speedKmh }
        let f = min(max(elapsed / TimeInterval(durationSeconds), 0), 1)
        return speedKmh + (end - speedKmh) * f
    }

    /// Vitesses extrêmes que la phase peut demander.
    public var speedBounds: (min: Double, max: Double) {
        if let a = autoSpeed { return (min(a.minKmh, speedKmh), max(a.maxKmh, speedKmh)) }
        let e = endSpeedKmh ?? speedKmh
        return (min(speedKmh, e), max(speedKmh, e))
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
    /// Programme prédéfini d'origine (nil pour un programme créé ou dupliqué).
    public var templateID: String?
    /// Protocole verrouillé (ex. Cardio Baseline) : les phases ne se modifient qu'après
    /// déverrouillage explicite, pour garder des séances strictement comparables.
    public var locked: Bool?
    /// Version du protocole d'un programme prédéfini (incrémentée quand ses étapes changent).
    public var protocolVersion: Int?
    /// Niveau dans une famille de programmes (ex. Football Endurance 1, 2, 3).
    public var level: Int?
    /// Programme avancé : jamais proposé automatiquement, lancement après confirmation explicite.
    public var advanced: Bool?

    public init(id: UUID = UUID(), name: String, notes: String = "", items: [ProgramItem],
                createdAt: Date = Date(), updatedAt: Date = Date(), templateID: String? = nil, locked: Bool? = nil,
                protocolVersion: Int? = nil, level: Int? = nil, advanced: Bool? = nil) {
        self.id = id
        self.name = name
        self.notes = notes
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.templateID = templateID
        self.locked = locked
        self.protocolVersion = protocolVersion
        self.level = level
        self.advanced = advanced
    }

    public var isAdvanced: Bool { advanced ?? false }

    public var isLocked: Bool { locked ?? false }

    /// Programme contenant une phase pilotée par la FC.
    public var hasAutoSpeed: Bool { schedule.contains { $0.phase.isAuto } }

    /// Empreinte du déroulé (durées, vitesses, rampes, inclinaisons, pilotage), indépendante
    /// des noms et identifiants : deux séances de même empreinte ont suivi le même protocole.
    public var protocolSignature: String {
        var text = ""
        for sp in schedule {
            let p = sp.phase
            text += String(format: "%d/%.2f/%.1f", p.durationSeconds, p.speedKmh, p.inclinePercent)
            if let e = p.endSpeedKmh, p.isRamp { text += String(format: ">%.2f", e) }
            if let a = p.autoSpeed { text += "/auto:" + a.signature }
            text += ";"
        }
        // FNV-1a 64 bits : stable d'une plateforme et d'une version à l'autre.
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    public var totalDurationSeconds: Int { items.reduce(0) { $0 + $1.durationSeconds } }

    /// Copie avec de nouveaux identifiants (duplication, import).
    public func duplicated(name: String? = nil, now: Date = Date()) -> WorkoutProgram {
        WorkoutProgram(name: name ?? "\(self.name) (copie)", notes: notes,
                       items: items.map { $0.withNewIDs() }, createdAt: now, updatedAt: now, advanced: advanced)
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

    public var maxSpeedKmh: Double { schedule.map(\.phase.speedBounds.max).max() ?? 0 }

    /// Exercice de course plutôt que de marche (≥ 8 km/h prévus). Une phase pilotée par la FC
    /// compte pour sa vitesse de départ, pas pour son plafond automatique.
    public var suggestsRunning: Bool {
        (schedule.map { $0.phase.isAuto ? $0.phase.speedKmh : $0.phase.speedBounds.max }.max() ?? 0) >= 8
    }
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
