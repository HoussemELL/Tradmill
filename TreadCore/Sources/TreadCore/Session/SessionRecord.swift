import Foundation

/// Échantillon de série temporelle (≈ 1 Hz pendant la séance).
public struct SessionSample: Codable, Equatable, Sendable {
    /// Secondes depuis le début de la séance (temps réel, pauses incluses).
    public var t: Double
    /// Temps actif écoulé (hors pauses).
    public var active: Double
    public var speed: Double?
    public var incline: Double?
    public var targetSpeed: Double?
    public var targetIncline: Double?
    public var hr: Int?
    public var hrSource: HeartRateSource?
    public var zone: Int?
    public var distance: Double
    public var steps: Int?
    public var phase: Int?
    public var paused: Bool

    public init(t: Double, active: Double, speed: Double?, incline: Double?, targetSpeed: Double?, targetIncline: Double?,
                hr: Int?, hrSource: HeartRateSource?, zone: Int?, distance: Double, steps: Int?, phase: Int?, paused: Bool) {
        self.t = t
        self.active = active
        self.speed = speed
        self.incline = incline
        self.targetSpeed = targetSpeed
        self.targetIncline = targetIncline
        self.hr = hr
        self.hrSource = hrSource
        self.zone = zone
        self.distance = distance
        self.steps = steps
        self.phase = phase
        self.paused = paused
    }
}

public struct SessionEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case start, pause, resume, stop, finish
        case phaseChange, phaseSkipped, manualOverride
        case connectionLost, connectionRestored
        case speedMismatch, inclineMismatch, commandFailed
        case machineStopped, externalMovement
        case hrSourceChanged, zoneAlert
        case recovered, info
    }

    public var t: Double
    public var kind: Kind
    public var detail: String

    public init(t: Double, kind: Kind, detail: String) {
        self.t = t
        self.kind = kind
        self.detail = detail
    }
}

/// État de l'enregistrement Apple Santé d'une séance.
public enum HealthSaveStatus: Codable, Equatable, Sendable {
    case notRequested
    /// L'exercice est enregistré par l'Apple Watch (propriétaire de l'enregistrement).
    case ownedByWatch
    case saved(workoutUUID: String)
    case denied
    case failed(String)

    public var label: String {
        switch self {
        case .notRequested: return "Non enregistré dans Santé"
        case .ownedByWatch: return "Enregistré par l'Apple Watch"
        case .saved: return "Enregistré dans Santé"
        case .denied: return "Accès Santé refusé"
        case let .failed(m): return "Échec Santé : \(m)"
        }
    }
}

public struct CalorieBreakdown: Codable, Equatable, Sendable {
    public var treadmillKcal: Double?
    public var healthKitActiveKcal: Double?
    public var estimatedKcal: Double?

    public init(treadmillKcal: Double? = nil, healthKitActiveKcal: Double? = nil, estimatedKcal: Double? = nil) {
        self.treadmillKcal = treadmillKcal
        self.healthKitActiveKcal = healthKitActiveKcal
        self.estimatedKcal = estimatedKcal
    }
}

/// Séance complète, sérialisable (historique, export, reprise après crash).
public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int = SessionRecord.formatVersion
    public var id: UUID
    public var startDate: Date
    public var endDate: Date?
    public var programName: String?
    public var program: WorkoutProgram?
    public var treadmillName: String?
    public var profileID: String?
    public var simulated: Bool
    public var interrupted: Bool

    public var activeSeconds: Double = 0
    public var pausedSeconds: Double = 0
    public var distanceMeters: Double = 0
    public var distanceSource: MetricSource = .none
    public var steps: Int?
    public var stepsSource: MetricSource = .none
    public var avgSpeed: Double?
    public var maxSpeed: Double?
    public var avgIncline: Double?
    public var maxIncline: Double?
    public var avgHR: Int?
    public var maxHR: Int?
    public var hrSources: [HeartRateSource] = []
    public var zoneSeconds: [Double] = Array(repeating: 0, count: 6)
    public var zoneSettings: HeartZoneSettings?
    public var calories = CalorieBreakdown()
    public var samples: [SessionSample] = []
    public var events: [SessionEvent] = []
    public var healthStatus: HealthSaveStatus = .notRequested

    public init(id: UUID = UUID(), startDate: Date, program: WorkoutProgram?, treadmillName: String?,
                profileID: String?, simulated: Bool) {
        self.id = id
        self.startDate = startDate
        self.program = program
        self.programName = program?.name
        self.treadmillName = treadmillName
        self.profileID = profileID
        self.simulated = simulated
        self.interrupted = false
    }

    public var title: String { programName ?? "Séance libre" }

    /// Recalcule les agrégats depuis les échantillons (pondération temporelle, hors pauses).
    public mutating func recomputeAggregates() {
        var speedSum = 0.0, speedTime = 0.0, inclSum = 0.0, inclTime = 0.0, hrSum = 0.0, hrTime = 0.0
        var mxS: Double?, mxI: Double?, mxH: Int?
        var sources: [HeartRateSource] = []
        for (i, s) in samples.enumerated() where !s.paused {
            let dt: Double = i + 1 < samples.count ? max(0, min(samples[i + 1].t - s.t, 5)) : 1
            if let v = s.speed { speedSum += v * dt; speedTime += dt; mxS = max(mxS ?? v, v) }
            if let v = s.incline { inclSum += v * dt; inclTime += dt; mxI = max(mxI ?? v, v) }
            if let v = s.hr { hrSum += Double(v) * dt; hrTime += dt; mxH = max(mxH ?? v, v) }
            if let src = s.hrSource, !sources.contains(src) { sources.append(src) }
        }
        avgSpeed = speedTime > 0 ? speedSum / speedTime : nil
        maxSpeed = mxS
        avgIncline = inclTime > 0 ? inclSum / inclTime : nil
        maxIncline = mxI
        avgHR = hrTime > 0 ? Int((hrSum / hrTime).rounded()) : nil
        maxHR = mxH
        hrSources = sources
    }

    /// Programme dérivé de la séance (« enregistrer comme modèle »).
    /// Programme exécuté s'il existe, sinon segments de consignes constantes ≥ 30 s.
    public func derivedProgram(name: String) -> WorkoutProgram? {
        if let p = program { return p.duplicated(name: name) }
        var phases: [ProgramPhase] = []
        var segStart: Double?
        var cur: (Double, Double)?
        func close(at t: Double) {
            guard let s = segStart, let c = cur else { return }
            let d = Int((t - s).rounded())
            guard d >= 30 else { return }
            phases.append(ProgramPhase(name: "Phase \(phases.count + 1)", kind: .steady, durationSeconds: d,
                                       speedKmh: c.0, inclinePercent: c.1))
        }
        for s in samples where !s.paused {
            guard let ts = s.targetSpeed ?? s.speed else { continue }
            let key = ((ts * 10).rounded() / 10, ((s.targetIncline ?? s.incline ?? 0)).rounded())
            if cur == nil || cur! != key {
                close(at: s.active)
                segStart = s.active
                cur = key
            }
        }
        close(at: samples.last?.active ?? 0)
        guard !phases.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return WorkoutProgram(name: name, notes: "Créé depuis la séance du \(f.string(from: startDate))", items: phases.map { .phase($0) })
    }
}
