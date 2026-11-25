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
        case corrected(from: UInt64, to: UInt64)
    }

    /// Valeur maximale représentable + 1 (ex. 1 << 24). nil = pas de débordement attendu.
    public var modulus: UInt64?
    /// Incrément maximal plausible par seconde (au-delà : saut ignoré).
    public var maxRatePerSecond: Double
    /// Si vrai, le premier échantillon sert de référence ; sinon le compteur est supposé partir de 0.
    public var baselineFromFirstSample: Bool
    /// Total recalculé par sa source (statistique Santé de l'Apple Watch, dédoublonnée quand des
    /// pas d'un autre appareil arrivent) : une baisse modérée est une correction, pas une remise à
    /// zéro. Sans cela, 5 209 → 4 753 était compté comme « repart de 0 » et ajoutait 4 753 pas
    /// (séance du 20/11). Optionnel pour relire les points de reprise d'une version antérieure.
    public var allowsDownwardCorrection: Bool?

    public private(set) var sessionTotal: Double = 0
    private var lastRaw: UInt64?
    private var lastTime: TimeInterval?
    /// Heure du dernier changement de valeur. Le rythme se juge depuis ce changement, pas depuis
    /// le dernier paquet : le Domyos RUN100 annonce sa distance par paliers de 10 m (toutes les
    /// 7 à 12 s) dans des paquets envoyés 4 fois par seconde ; comparé à 0,25 s, chaque palier
    /// passait pour un saut impossible et la distance du tapis n'était jamais retenue (25/11).
    private var lastChangeTime: TimeInterval?

    public init(modulus: UInt64?, maxRatePerSecond: Double, baselineFromFirstSample: Bool = true,
                allowsDownwardCorrection: Bool = false) {
        self.modulus = modulus
        self.maxRatePerSecond = maxRatePerSecond
        self.baselineFromFirstSample = baselineFromFirstSample
        self.allowsDownwardCorrection = allowsDownwardCorrection ? true : nil
    }

    /// Après une perte de lien : la prochaine valeur est comparée sans supposer de continuité temporelle.
    public mutating func markDiscontinuity() {
        lastTime = nil
        lastChangeTime = nil
    }

    @discardableResult
    public mutating func ingest(_ raw: UInt64, at t: TimeInterval) -> Anomaly? {
        defer {
            if lastRaw != raw || lastChangeTime == nil { lastChangeTime = t }
            lastRaw = raw; lastTime = t
        }
        guard let prev = lastRaw else {
            if !baselineFromFirstSample { sessionTotal += Double(raw) }
            return nil
        }
        if raw >= prev {
            let delta = Double(raw - prev)
            if let lt = lastChangeTime ?? lastTime {
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
        // Correction de la source (total recalculé à la baisse, pas une vraie remise à zéro).
        if allowsDownwardCorrection == true, raw >= prev / 2 {
            sessionTotal = max(0, sessionTotal - Double(prev - raw))
            return .corrected(from: prev, to: raw)
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

/// Modèle de foulée : cadence et longueur de pas typiques selon la vitesse (marche, puis course
/// à partir de 7 km/h). Sert à l'estimation des pas et au contrôle de cohérence pas / distance.
public enum StepModel {
    /// Vitesse de référence de la longueur de pas réglée par l'utilisateur (marche).
    public static let referenceSpeedKmh = 5.0

    /// Cadence typique (pas/min) : 111 à 4 km/h, 120 à 5 km/h, 150 à 7 km/h, 155 à 9 km/h, 163 à 12 km/h.
    public static func cadence(speedKmh v: Double) -> Double {
        v < 7 ? 75 + 9 * v : 150 + 2.5 * (v - 7)
    }

    /// Longueur de pas attendue (m) à `speedKmh`, mise à l'échelle par la longueur de pas réglée
    /// en marche à 5 km/h (0,70 m par défaut : 0,70 m à 5 km/h, 0,98 m à 9 km/h, 1,24 m à 12 km/h).
    public static func stepLength(speedKmh: Double, walkingStepLength: Double) -> Double {
        let v = min(max(speedKmh, 2), 20)
        let raw = v / 3.6 / (cadence(speedKmh: v) / 60)
        let ref = referenceSpeedKmh / 3.6 / (cadence(speedKmh: referenceSpeedKmh) / 60)
        return raw * walkingStepLength / ref
    }
}

/// Pas de la séance : une seule source à la fois, jamais d'addition entre sources.
/// Priorité : tapis (si son compteur avance) > Apple Watch > estimation facultative.
///
/// Une source n'est retenue que lorsqu'elle a compté au moins un pas : un tapis qui envoie le champ
/// figé à 0 ne masque plus la montre. Pendant les `takeoverWindow` premières secondes, une source
/// prioritaire qui arrive plus tard (montre relancée à 12 s puis 40 s) remplace la source retenue,
/// avec son propre total depuis le début ; ensuite la source ne change plus.
/// Toutes les heures `at` sont en temps de séance (s).
public struct StepTracker: Codable, Equatable, Sendable {
    public private(set) var source: MetricSource = .none
    private var treadmillCounter = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 6)
    private var watchCounter = CumulativeCounter(modulus: nil, maxRatePerSecond: 6, baselineFromFirstSample: false,
                                                 allowsDownwardCorrection: true)
    private var estimated: Double = 0
    public var estimationEnabled: Bool
    /// Longueur de pas en marche à 5 km/h (m) ; l'estimation l'adapte à la vitesse.
    public var strideLengthMeters: Double
    /// Délai de grâce au début de séance pendant lequel une meilleure source peut s'imposer
    /// avant que l'estimation ne soit retenue.
    public var estimationGracePeriod: TimeInterval = 20
    public private(set) var anomalies: Int = 0
    /// Heure de mesure du dernier total reçu de la montre (un message plus ancien est ignoré).
    private var lastWatchSampleAt: TimeInterval?
    private var lastWatchReceivedAt: TimeInterval?
    /// Horloge du contrôle de rythme de la montre : avance du plus grand des deux écarts
    /// (heures de mesure, heures de réception).
    private var watchClock: TimeInterval?

    /// Durée (s, depuis le début de la séance) pendant laquelle une source prioritaire peut
    /// remplacer la source retenue.
    public static let takeoverWindow: TimeInterval = 120

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
        let anomaly = treadmillCounter.ingest(UInt64(raw), at: t)
        if treadmillCounter.sessionTotal >= 1 { offer(.treadmill, at: t) }
        if anomaly != nil, source == .treadmill { anomalies += 1 }
    }

    /// Total de pas depuis le début de l'exercice Watch (statistique cumulée de la session).
    /// `t` : heure de la mesure sur la montre ; `receivedAt` : heure de réception (par défaut `t`).
    /// Le rythme (≤ 6 pas/s) est contrôlé sur le plus grand des deux écarts : des messages retardés
    /// puis reçus en rafale (mesures espacées) et un total complété après coup sous la même heure
    /// de mesure (réceptions espacées) ne passent plus pour des sauts impossibles.
    public mutating func ingestWatch(total: Double, at t: TimeInterval, receivedAt: TimeInterval? = nil) {
        guard total >= 0 else { return }
        if let last = lastWatchSampleAt, t < last { return }   // message plus ancien que le dernier reçu
        let received = receivedAt ?? t
        let clock: TimeInterval
        if let ls = lastWatchSampleAt, let lr = lastWatchReceivedAt, let c = watchClock {
            clock = c + max(t - ls, received - lr, 0)
        } else {
            clock = t
        }
        lastWatchSampleAt = t
        lastWatchReceivedAt = received
        watchClock = clock
        let anomaly = watchCounter.ingest(UInt64(total.rounded()), at: clock)
        if watchCounter.sessionTotal >= 1 { offer(.appleWatch, at: t) }
        switch anomaly {
        case nil, .corrected?: break
        default: if source == .appleWatch { anomalies += 1 }
        }
    }

    /// Distance parcourue depuis le dernier appel (m), pour l'estimation. La longueur de pas suit
    /// la vitesse mesurée (`StepModel`) ; sans vitesse, la longueur réglée est utilisée telle quelle.
    public mutating func ingestDistance(deltaMeters: Double, speedKmh: Double? = nil, at t: TimeInterval) {
        guard estimationEnabled, deltaMeters > 0, strideLengthMeters > 0.2 else { return }
        let length = speedKmh.map { $0 > 0.5 ? StepModel.stepLength(speedKmh: $0, walkingStepLength: strideLengthMeters)
                                             : strideLengthMeters } ?? strideLengthMeters
        estimated += deltaMeters / length
        if t >= estimationGracePeriod, estimated >= 1 { offer(.estimated, at: t) }
    }

    public mutating func markDiscontinuity() {
        treadmillCounter.markDiscontinuity()
        watchCounter.markDiscontinuity()
    }

    private static func rank(_ s: MetricSource) -> Int {
        switch s {
        case .treadmill: return 3
        case .appleWatch: return 2
        case .estimated: return 1
        case .none: return 0
        }
    }

    private mutating func offer(_ candidate: MetricSource, at t: TimeInterval) {
        guard Self.rank(candidate) > Self.rank(source) else { return }
        if source == .none || t <= Self.takeoverWindow { source = candidate }
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
