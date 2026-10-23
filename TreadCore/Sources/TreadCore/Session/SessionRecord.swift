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
    /// Énergie cumulée annoncée par le tapis (kcal), si le tapis la fournit.
    public var energy: Double?

    public init(t: Double, active: Double, speed: Double?, incline: Double?, targetSpeed: Double?, targetIncline: Double?,
                hr: Int?, hrSource: HeartRateSource?, zone: Int?, distance: Double, steps: Int?, phase: Int?, paused: Bool,
                energy: Double? = nil) {
        self.energy = energy
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

/// Phase effectivement exécutée (pour les événements « segment » de Santé).
public struct PhaseSpan: Codable, Equatable, Sendable {
    public var index: Int
    public var name: String
    public var kind: PhaseKind
    public var targetSpeedKmh: Double
    public var targetInclinePercent: Double
    /// Secondes depuis le début de la séance (même base que les échantillons).
    public var start: Double
    public var end: Double?
    /// Phase dont la vitesse était pilotée par la FC.
    public var auto: Bool?
    /// Zone cible indicative de la phase.
    public var targetZone: Int?
    /// Vitesse de fin d'une phase progressive.
    public var endSpeedKmh: Double?

    public init(index: Int, name: String, kind: PhaseKind, targetSpeedKmh: Double, targetInclinePercent: Double,
                start: Double, end: Double? = nil, auto: Bool? = nil, targetZone: Int? = nil, endSpeedKmh: Double? = nil) {
        self.index = index
        self.name = name
        self.kind = kind
        self.targetSpeedKmh = targetSpeedKmh
        self.targetInclinePercent = targetInclinePercent
        self.start = start
        self.end = end
        self.auto = auto
        self.targetZone = targetZone
        self.endSpeedKmh = endSpeedKmh
    }
}

/// Mesure de FC avec son heure réelle (secondes depuis le début de la séance).
public struct HeartRatePoint: Codable, Equatable, Sendable {
    public var t: Double
    public var bpm: Int
    public var source: HeartRateSource

    public init(t: Double, bpm: Int, source: HeartRateSource) {
        self.t = t
        self.bpm = bpm
        self.source = source
    }
}

/// Type d'activité Santé.
public enum HealthActivityType: String, Codable, CaseIterable, Sendable {
    case walking, running, hiit

    public var label: String {
        switch self {
        case .walking: return "Marche"
        case .running: return "Course"
        case .hiit: return "Entraînement fractionné (HIIT)"
        }
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
        case autoAdjust, autoSafety
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
    /// Une autre séance Santé (Watch, Fitness, app du tapis…) couvre déjà ce créneau.
    case alreadyRecorded(by: String)
    /// Rien n'est écrit, volontairement (séance trop courte, simulée, Santé désactivé…).
    case notWritten(String)

    public var label: String {
        switch self {
        case .notRequested: return "Non enregistré dans Santé"
        case .ownedByWatch: return "Enregistrée par l'Apple Watch (métadonnées Foulée ajoutées)"
        case .saved: return "Enregistrée dans Santé par Foulée"
        case .denied: return "Accès Santé refusé"
        case let .failed(m): return "Échec Santé : \(m)"
        case let .alreadyRecorded(by): return "Déjà enregistrée par \(by)"
        case let .notWritten(why): return "Non enregistrée : \(why)"
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

    // Champs ajoutés en V1.1 : tous optionnels pour relire les séances déjà enregistrées.
    /// Démarrage réel de la bande (premier mouvement observé).
    public var beltStartDate: Date?
    /// Arrêt réel de la bande (vitesse nulle observée après l'arrêt).
    public var beltStopDate: Date?
    public var phaseSpans: [PhaseSpan]?
    /// Mesures de FC horodatées (y compris les 2 minutes après l'arrêt de la bande).
    public var heartRateReadings: [HeartRatePoint]?
    /// Révision de la séance : 1 à l'enregistrement, +1 à chaque correction.
    public var revision: Int?
    /// Type d'activité choisi à la main (sinon déduit).
    public var activityTypeOverride: HealthActivityType?
    /// Version (HKMetadataKeySyncVersion) écrite dans Santé.
    public var healthSyncVersion: Int?
    /// Ce qui a été écrit dans Santé (pour vérification).
    public var healthReport: HealthWriteReport?
    public var elevationGainMeters: Double?

    // Champs ajoutés en V1.2 (programmes de référence, pilotage FC).
    /// Empreinte du protocole suivi (`WorkoutProgram.protocolSignature`).
    public var programSignature: String?
    /// Programme prédéfini d'origine.
    public var templateID: String?
    /// Nombre de consignes manuelles (vitesse/inclinaison) et de phases passées pendant la séance.
    public var manualChanges: Int?
    public var skippedPhases: Int?
    /// Ajustements du pilote FC.
    public var autoAdjustments: [AutoAdjustment]?

    // Champs ajoutés en V1.3 (bibliothèque révisée, export Rythme).
    /// Version du protocole du programme prédéfini au moment de la séance.
    public var protocolVersion: Int?
    /// Niveau du programme (Football Endurance 1, 2, 3).
    public var programLevel: Int?
    /// Ressenti de l'effort saisi par l'utilisateur (échelle CR10 de Borg : 0 = repos, 10 = maximal).
    public var perceivedExertion: Int?

    public init(id: UUID = UUID(), startDate: Date, program: WorkoutProgram?, treadmillName: String?,
                profileID: String?, simulated: Bool) {
        self.id = id
        self.startDate = startDate
        self.program = program
        self.programName = program?.name
        self.programSignature = program?.protocolSignature
        self.templateID = program?.templateID
        self.protocolVersion = program?.protocolVersion
        self.programLevel = program?.level
        self.treadmillName = treadmillName
        self.profileID = profileID
        self.simulated = simulated
        self.interrupted = false
    }

    public var title: String { programName ?? "Séance libre" }

    /// Date réelle correspondant à un instant de la séance.
    public func date(at t: Double) -> Date { startDate.addingTimeInterval(t) }

    /// Recalcule les agrégats depuis les échantillons (pondération temporelle, hors pauses).
    public mutating func recomputeAggregates() {
        var speedSum = 0.0, speedTime = 0.0, inclSum = 0.0, inclTime = 0.0, hrSum = 0.0, hrTime = 0.0
        var mxS: Double?, mxI: Double?, mxH: Int?
        var sources: [HeartRateSource] = []
        var elevation = 0.0
        var hasIncline = false
        for (i, s) in samples.enumerated() where i > 0 && !s.paused {
            let prev = samples[i - 1]
            if let incl = s.incline ?? prev.incline {
                hasIncline = true
                let dd = s.distance - prev.distance
                if dd > 0 && dd < 50 && incl > 0 { elevation += dd * incl / 100 }
            }
        }
        elevationGainMeters = hasIncline ? elevation : nil
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

public extension SessionRecord {
    /// Vrai si les zones enregistrées ont été calculées avec des bornes différentes de `zones`.
    func zonesDiffer(from zones: HeartZoneSettings) -> Bool {
        guard let z = zoneSettings else { return true }
        return z.bounds != zones.bounds || z.effectiveMethod != zones.effectiveMethod
    }

    /// Même séance, zones recalculées depuis la FC enregistrée avec `zones` (changement de
    /// méthode ou de FC max après coup) : zone de chaque échantillon, temps par zone, réglages.
    /// Rien d'autre ne change. Mêmes bornes qu'à l'enregistrement : séance renvoyée telle quelle.
    func rezoned(with zones: HeartZoneSettings) -> SessionRecord {
        guard zonesDiffer(from: zones) else { return self }
        var r = self
        var time = ZoneTimeAccumulator()
        for i in r.samples.indices {
            let s = r.samples[i]
            let zone = s.hr.map { zones.zone(for: $0) }
            r.samples[i].zone = zone
            // Comme pendant la séance : pas de temps compté en pause ni sans FC.
            if s.paused { time.interrupt() } else { time.add(zone: zone, at: s.t) }
        }
        r.zoneSeconds = time.seconds
        r.zoneSettings = zones
        return r
    }
}
