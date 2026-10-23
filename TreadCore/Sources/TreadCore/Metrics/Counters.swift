import Foundation

/// Compteur cumulatif d'appareil (pas, distance, énergie) converti en total de séance.
///
/// Gère :
/// - la valeur initiale non nulle (référence prise au premier échantillon) ;
/// - le débordement (ex. uint24 pour la distance FTMS) ;
/// - la remise à zéro par l'appareil (Stop/Start du tapis, reconnexion) ;
/// - les sauts aberrants, ignorés et signalés.
public struct CumulativeCounter: Codable, Equatable, Sendable {
    public enum Anomaly: Equatable, Sendable {
        case wrapped(from: UInt64, to: UInt64)
        case reset(from: UInt64, to: UInt64)
        case implausibleJump(from: UInt64, to: UInt64)
    }

    /// Valeur maximale représentable + 1 (ex. 1 << 24). nil = pas de débordement attendu.
    public var modulus: UInt64?
    /// Incrément maximal plausible par seconde (au-delà : saut ignoré).
    public var maxRatePerSecond: Double
    /// Si vrai, le premier échantillon sert de référence ; sinon le compteur est supposé partir de 0.
    public var baselineFromFirstSample: Bool

    public private(set) var sessionTotal: Double = 0
    private var lastRaw: UInt64?
    private var lastTime: TimeInterval?

    public init(modulus: UInt64?, maxRatePerSecond: Double, baselineFromFirstSample: Bool = true) {
        self.modulus = modulus
        self.maxRatePerSecond = maxRatePerSecond
        self.baselineFromFirstSample = baselineFromFirstSample
    }

    /// Après une perte de lien : la prochaine valeur est comparée sans supposer de continuité temporelle.
    public mutating func markDiscontinuity() {
        lastTime = nil
    }

    @discardableResult
    public mutating func ingest(_ raw: UInt64, at t: TimeInterval) -> Anomaly? {
        defer { lastRaw = raw; lastTime = t }
        guard let prev = lastRaw else {
            if !baselineFromFirstSample { sessionTotal += Double(raw) }
            return nil
        }
        if raw >= prev {
            let delta = Double(raw - prev)
            if let lt = lastTime {
                let allowed = maxRatePerSecond * max(t - lt, 1) + 5
                if delta > allowed { return .implausibleJump(from: prev, to: raw) }
            } else if delta > maxRatePerSecond * 120 + 5 {
                // Après discontinuité, on accepte au plus ~2 min d'activité manquée.
                return .implausibleJump(from: prev, to: raw)
            }
            sessionTotal += delta
            return nil
        }
        // raw < prev : débordement ou remise à zéro.
        if let m = modulus, prev > m * 9 / 10, raw < m / 10 {
            sessionTotal += Double(m - prev + raw)
            return .wrapped(from: prev, to: raw)
        }
        // Remise à zéro : l'appareil recompte depuis 0.
        sessionTotal += Double(raw)
        return .reset(from: prev, to: raw)
    }
}

/// Provenance d'une métrique, conservée dans l'historique.
public enum MetricSource: String, Codable, Sendable, CaseIterable {
    case treadmill
    case appleWatch
    case estimated
    case none

    public var label: String {
        switch self {
        case .treadmill: return "tapis"
        case .appleWatch: return "Apple Watch"
        case .estimated: return "estimée"
        case .none: return "—"
        }
    }
}

/// Pas de la séance : une seule source, verrouillée dès la première valeur fiable.
/// Priorité : tapis (si le champ existe) > Apple Watch > estimation facultative.
/// Jamais d'addition entre sources.
public struct StepTracker: Codable, Equatable, Sendable {
    public private(set) var source: MetricSource = .none
    private var treadmillCounter = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 6)
    private var watchCounter = CumulativeCounter(modulus: nil, maxRatePerSecond: 6, baselineFromFirstSample: false)
    private var estimated: Double = 0
    public var estimationEnabled: Bool
    /// Longueur de pas pour l'estimation (m).
    public var strideLengthMeters: Double
    /// Délai de grâce au début de séance pendant lequel une meilleure source peut s'imposer
    /// avant que l'estimation ne soit retenue.
    public var estimationGracePeriod: TimeInterval = 20
    public private(set) var anomalies: Int = 0

    public init(estimationEnabled: Bool, strideLengthMeters: Double = 0.7) {
        self.estimationEnabled = estimationEnabled
        self.strideLengthMeters = strideLengthMeters
    }

    public var value: Int? {
        switch source {
        case .treadmill: return Int(treadmillCounter.sessionTotal)
        case .appleWatch: return Int(watchCounter.sessionTotal)
        case .estimated: return Int(estimated)
        case .none: return nil
        }
    }

    /// Valeur cumulative brute du tapis (extension Step Count).
    public mutating func ingestTreadmill(raw: UInt32, at t: TimeInterval) {
        if source == .none || source == .estimated && estimated < 1 { source = .treadmill }
        guard source == .treadmill else { return }
        if treadmillCounter.ingest(UInt64(raw), at: t) != nil { anomalies += 1 }
    }

    /// Total de pas depuis le début de l'exercice Watch (statistique cumulée de la session).
    public mutating func ingestWatch(total: Double, at t: TimeInterval) {
        if source == .none || source == .estimated && estimated < 1 { source = .appleWatch }
        guard source == .appleWatch, total >= 0 else { return }
        if watchCounter.ingest(UInt64(total.rounded()), at: t) != nil { anomalies += 1 }
    }

    /// Distance parcourue depuis le dernier appel (m), pour l'estimation.
    public mutating func ingestDistance(deltaMeters: Double, sessionElapsed: TimeInterval) {
        guard estimationEnabled, deltaMeters > 0, strideLengthMeters > 0.2 else { return }
        if source == .none && sessionElapsed >= estimationGracePeriod { source = .estimated }
        if source == .estimated || source == .none { estimated += deltaMeters / strideLengthMeters }
    }

    public mutating func markDiscontinuity() {
        treadmillCounter.markDiscontinuity()
        watchCounter.markDiscontinuity()
    }
}

/// Estimation de dépense énergétique (équations ACSM marche/course), affichée comme « estimée ».
public enum EnergyEstimator {
    /// kcal/min pour une vitesse (km/h), une pente (%) et un poids (kg).
    public static func kcalPerMinute(speedKmh: Double, gradePercent: Double, weightKg: Double) -> Double {
        guard speedKmh > 0, weightKg > 0 else { return 0 }
        let mPerMin = speedKmh * 1000 / 60
        let grade = max(gradePercent, 0) / 100
        let vo2: Double
        if speedKmh < 7.5 {
            vo2 = 0.1 * mPerMin + 1.8 * mPerMin * grade + 3.5
        } else {
            vo2 = 0.2 * mPerMin + 0.9 * mPerMin * grade + 3.5
        }
        // VO2 en ml/kg/min ; ~5 kcal par litre d'O2. Énergie brute (repos inclus).
        return vo2 * weightKg / 1000 * 5
    }
}

public extension EnergyEstimator {
    /// Énergie active (kcal/min) : équation ACSM moins la dépense de repos (3,5 ml/kg/min),
    /// pour ne pas compter la dépense de base dans « énergie active ».
    static func activeKcalPerMinute(speedKmh: Double, gradePercent: Double, weightKg: Double) -> Double {
        guard speedKmh > 0, weightKg > 0 else { return 0 }
        let gross = kcalPerMinute(speedKmh: speedKmh, gradePercent: gradePercent, weightKg: weightKg)
        let resting = 3.5 * weightKg / 1000 * 5
        return max(0, gross - resting)
    }
}
