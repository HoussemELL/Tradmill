import Foundation

/// Longueur de pas personnelle, apprise sur les séances où les pas mesurés (montre ou tapis) sont
/// cohérents avec la distance du tapis.
///
/// Elle est exprimée comme un facteur appliqué au modèle de foulée de base (`StepModel` avec
/// 0,70 m en marche à 5 km/h), séparément pour la marche (< 7 km/h) et la course. Chaque séance
/// retenue compte au prorata de sa distance, et les 10 derniers kilomètres pèsent au plus :
/// la calibration suit l'évolution de la foulée.
public struct StepCalibration: Codable, Equatable, Sendable {
    public struct Band: Codable, Equatable, Sendable {
        /// Longueur de pas réelle / longueur du modèle de base.
        public var factor: Double
        /// Distance prise en compte (m, plafonnée à `maxWeightMeters`).
        public var meters: Double
        public var sessions: Int

        public init(factor: Double, meters: Double, sessions: Int) {
            self.factor = factor
            self.meters = meters
            self.sessions = sessions
        }
    }

    public var walk: Band?
    public var run: Band?
    /// Séances déjà apprises (les 100 dernières) : une séance n'est jamais comptée deux fois.
    public var learnedSessionIDs: [UUID] = []

    public static let baseWalkingStepLength = 0.70
    public static let runThresholdKmh = 7.0
    public static let maxWeightMeters = 10_000.0
    /// Distance minimale dans une allure (marche ou course) pour l'apprendre.
    public static let minBandMeters = 300.0
    /// Pas mesurés / pas attendus par le modèle de base : en dehors, la séance n'est pas apprise
    /// (montre qui sous-compte, mains sur les poignées, distance douteuse).
    public static let acceptedRatio = 0.8...1.25

    public init() {}

    public var isEmpty: Bool { walk == nil && run == nil }

    /// Facteur pour une vitesse : celui de l'allure, sinon celui de l'autre allure, sinon nil.
    public func factor(speedKmh: Double) -> Double? {
        let band = speedKmh < Self.runThresholdKmh ? walk : run
        return (band ?? walk ?? run)?.factor
    }

    /// Longueur de pas (m) à une vitesse : apprise si possible, sinon le modèle mis à l'échelle
    /// par la longueur de pas réglée (`walkingStepLength`, en marche à 5 km/h).
    public func stepLength(speedKmh: Double, walkingStepLength: Double) -> Double {
        if let f = factor(speedKmh: speedKmh) {
            return StepModel.stepLength(speedKmh: speedKmh, walkingStepLength: Self.baseWalkingStepLength) * f
        }
        return StepModel.stepLength(speedKmh: speedKmh, walkingStepLength: walkingStepLength)
    }

    /// Longueur de pas apprise à une vitesse donnée (pour l'affichage), nil sans calibration.
    public func learnedStepLength(speedKmh: Double) -> Double? {
        guard let f = (speedKmh < Self.runThresholdKmh ? walk : run)?.factor else { return nil }
        return StepModel.stepLength(speedKmh: speedKmh, walkingStepLength: Self.baseWalkingStepLength) * f
    }

    /// Apprend une séance dont les pas sont mesurés. Renvoie vrai si la calibration a changé.
    @discardableResult
    public mutating func learn(from r: SessionRecord, measuredSteps: Int) -> Bool {
        guard !learnedSessionIDs.contains(r.id), measuredSteps > 0,
              r.stepsSource == .appleWatch || r.stepsSource == .treadmill || r.watchSteps != nil else { return false }
        let base = r.stepSegments { StepModel.stepLength(speedKmh: $0, walkingStepLength: Self.baseWalkingStepLength) }
        guard base.expected >= 1, base.covered >= r.distanceMeters * 0.8, r.distanceMeters >= StepCheck.minDistanceMeters else { return false }
        let expectedTotal = base.expected * r.distanceMeters / base.covered
        let ratio = Double(measuredSteps) / expectedTotal
        guard Self.acceptedRatio.contains(ratio) else { return false }
        // Pas mesurés par allure : écarts de la série si elle couvre l'essentiel, sinon même rapport partout.
        var changed = false
        for running in [false, true] {
            let seg = running ? base.run : base.walk
            guard seg.meters >= Self.minBandMeters, seg.expected >= 1 else { continue }
            let measured: Double
            if let m = running ? base.runMeasured : base.walkMeasured, base.measuredCoverage >= 0.8 {
                measured = m * Double(measuredSteps) / max(base.measuredTotal, 1)
            } else {
                measured = seg.expected * ratio
            }
            guard measured >= 1 else { continue }
            let factor = seg.expected / measured
            var band = (running ? run : walk) ?? Band(factor: factor, meters: 0, sessions: 0)
            let total = band.meters + seg.meters
            band.factor = (band.factor * band.meters + factor * seg.meters) / total
            band.meters = min(total, Self.maxWeightMeters)
            band.sessions += 1
            if running { run = band } else { walk = band }
            changed = true
        }
        if changed {
            learnedSessionIDs.append(r.id)
            if learnedSessionIDs.count > 100 { learnedSessionIDs.removeFirst(learnedSessionIDs.count - 100) }
        }
        return changed
    }
}

/// Segments de la série d'une séance (hors pauses) : distance et pas attendus par allure, et pas
/// mesurés par allure quand la série porte les pas.
struct StepSegments {
    struct Part { var meters = 0.0; var expected = 0.0 }
    var walk = Part()
    var run = Part()
    var walkMeasured: Double?
    var runMeasured: Double?
    /// Distance couverte par les segments (m).
    var covered: Double { walk.meters + run.meters }
    var expected: Double { walk.expected + run.expected }
    var measuredTotal: Double { (walkMeasured ?? 0) + (runMeasured ?? 0) }
    /// Part de la distance dont les pas mesurés sont connus.
    var measuredCoverage = 0.0
}

extension SessionRecord {
    func stepSegments(stepLength: (Double) -> Double) -> StepSegments {
        var out = StepSegments()
        var measuredMeters = 0.0
        var prev: SessionSample?
        for s in samples {
            defer { prev = s }
            guard let p = prev, !s.paused, !p.paused else { continue }
            let dd = s.distance - p.distance, dt = s.t - p.t
            guard dd > 0, dt > 0 else { continue }
            let speeds = [s.speed, p.speed].compactMap { $0 }.filter { $0 > 0.5 }
            let v = speeds.isEmpty ? dd / dt * 3.6 : speeds.reduce(0, +) / Double(speeds.count)
            let running = v >= StepCalibration.runThresholdKmh
            let e = dd / stepLength(v)
            if running { out.run.meters += dd; out.run.expected += e } else { out.walk.meters += dd; out.walk.expected += e }
            if let a = p.steps, let b = s.steps, b >= a {
                measuredMeters += dd
                if running { out.runMeasured = (out.runMeasured ?? 0) + Double(b - a) }
                else { out.walkMeasured = (out.walkMeasured ?? 0) + Double(b - a) }
            }
        }
        out.measuredCoverage = out.covered > 0 ? measuredMeters / out.covered : 0
        return out
    }

    /// Pas attendus pour toute la distance avec une longueur de pas donnée par vitesse ; nil si la
    /// série est trop incomplète (moins de 80 % de la distance).
    public func expectedSteps(stepLength: (Double) -> Double) -> Double? {
        let seg = stepSegments(stepLength: stepLength)
        guard distanceMeters > 0, seg.expected >= 1, seg.covered >= distanceMeters * 0.8 else { return nil }
        return seg.expected * distanceMeters / seg.covered
    }

    /// Intervalles d'activité (entre deux échantillons hors pause), en dates, fusionnés.
    public func activeIntervals() -> [DateInterval] {
        var spans: [(Double, Double)] = []
        var prev: SessionSample?
        for s in samples {
            defer { prev = s }
            guard let p = prev, !s.paused, !p.paused, s.t > p.t else { continue }
            if let last = spans.last, abs(last.1 - p.t) < 0.001 { spans[spans.count - 1].1 = s.t } else { spans.append((p.t, s.t)) }
        }
        return spans.map { DateInterval(start: date(at: $0.0), end: date(at: $0.1)) }
    }
}

/// Pas de la montre relus dans Santé et choix final des pas de la séance.
public enum StepReconciliation {
    public struct HealthStepSample: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var count: Double
        public init(start: Date, end: Date, count: Double) {
            self.start = start
            self.end = end
            self.count = count
        }
    }

    /// Pas de la montre pendant les intervalles d'activité : chaque échantillon compte au prorata
    /// de son recouvrement (un échantillon instantané compte s'il tombe dedans).
    public static func watchSteps(_ samples: [HealthStepSample], during intervals: [DateInterval]) -> Double {
        var total = 0.0
        for s in samples {
            let length = s.end.timeIntervalSince(s.start)
            for i in intervals {
                if length <= 0 {
                    if i.contains(s.start) { total += s.count; break }
                    continue
                }
                let overlap = min(s.end, i.end).timeIntervalSince(max(s.start, i.start))
                if overlap > 0 { total += s.count * overlap / length }
            }
        }
        return total
    }

    /// Ratio pas de la montre / pas attendus en dessous duquel la montre est jugée sous-compter.
    public static let undercountRatio = 0.7

    /// Choix final des pas d'une séance terminée.
    /// - Pas de la montre : le plus grand de la valeur reçue en direct et de celle relue dans Santé
    ///   (Santé est complète même si la liaison s'est coupée ; tant qu'elle n'est pas synchronisée,
    ///   elle peut être plus basse).
    /// - Si la montre a compté moins de 70 % des pas attendus pour la distance (mains sur les
    ///   poignées, bras immobiles), les pas deviennent distance ÷ longueur de pas personnelle,
    ///   marqués « estimée » ; le compte de la montre est conservé dans `watchSteps`.
    /// - Pas estimés en direct : recalculés avec la longueur de pas personnelle.
    /// - Pas du tapis : inchangés.
    public static func finalize(_ record: SessionRecord, healthWatchSteps: Int?, calibration: StepCalibration,
                                walkingStepLength: Double) -> SessionRecord {
        var r = record
        guard r.stepsSource != .treadmill else { return r }
        let live = r.watchSteps ?? (r.stepsSource == .appleWatch ? r.steps : nil)
        let watch = [live, healthWatchSteps].compactMap { $0 }.filter { $0 > 0 }.max()
        if let h = healthWatchSteps, h > 0, h >= (live ?? 0) { r.watchStepsFromHealth = true }
        let expected = r.distanceMeters >= StepCheck.minDistanceMeters
            ? r.expectedSteps { calibration.stepLength(speedKmh: $0, walkingStepLength: walkingStepLength) } : nil
        if let w = watch {
            r.watchSteps = w
            if let e = expected, Double(w) < e * undercountRatio {
                r.steps = Int(e.rounded())
                r.stepsSource = .estimated
                r.stepsReplacedUndercount = true
            } else {
                r.steps = w
                r.stepsSource = .appleWatch
                r.stepsReplacedUndercount = nil
            }
        } else if r.stepsSource == .estimated, let e = expected {
            r.steps = Int(e.rounded())
        }
        return r
    }
}
