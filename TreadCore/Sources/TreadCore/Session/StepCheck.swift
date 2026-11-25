import Foundation

/// Contrôle de cohérence entre les pas mesurés (tapis ou Apple Watch) et la distance de la séance.
///
/// Les pas attendus sont calculés échantillon par échantillon avec `StepModel` (longueur de pas
/// selon la vitesse). Un écart de plus de 30 % en moins ou de 40 % en plus est signalé : la montre
/// sous-compte quand les bras bougent peu (mains sur les poignées, téléphone à la main).
public struct StepCheck: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case plausible
        /// Moins de pas qu'attendu (longueur de pas apparente trop grande).
        case tooFew
        /// Plus de pas qu'attendu (longueur de pas apparente trop petite).
        case tooMany
    }

    public static let minRatio = 0.7
    public static let maxRatio = 1.4
    /// En dessous, la distance est trop courte pour juger.
    public static let minDistanceMeters = 500.0

    public var measuredSteps: Int
    public var expectedSteps: Int
    /// Pas mesurés / pas attendus.
    public var ratio: Double
    /// Distance / pas mesurés (m).
    public var stepLengthMeters: Double
    /// Distance / pas attendus (m).
    public var expectedStepLengthMeters: Double
    public var source: MetricSource

    public var verdict: Verdict {
        if ratio < Self.minRatio { return .tooFew }
        if ratio > Self.maxRatio { return .tooMany }
        return .plausible
    }

    /// Texte d'alerte (nil si cohérent).
    public var warning: String? {
        let measured = String(format: "%.2f", stepLengthMeters).replacingOccurrences(of: ".", with: ",")
        let expected = String(format: "%.2f", expectedStepLengthMeters).replacingOccurrences(of: ".", with: ",")
        let who = source == .appleWatch ? "la montre" : "le tapis"
        switch verdict {
        case .plausible:
            return nil
        case .tooFew:
            return "Peu de pas pour la distance : \(measured) m par pas, environ \(expected) m attendus. "
                + (source == .appleWatch ? "La montre a pu sous-compter (mains sur les poignées ou bras immobiles)."
                                         : "Le tapis a pu sous-compter.")
        case .tooMany:
            return "Beaucoup de pas pour la distance : \(measured) m par pas, environ \(expected) m attendus. "
                + "Vérifiez la distance du tapis, ou la longueur de pas réglée (Réglages › Pas) si \(who) compte juste."
        }
    }
}

public extension SessionRecord {
    /// Contrôle pas / distance ; nil si les pas ne sont pas mesurés (estimés ou absents) ou si la
    /// distance est trop courte. `walkingStepLength` : longueur de pas réglée en marche à 5 km/h.
    func stepCheck(walkingStepLength: Double) -> StepCheck? {
        guard let measured = steps, measured > 0, stepsSource == .appleWatch || stepsSource == .treadmill,
              distanceMeters >= StepCheck.minDistanceMeters, walkingStepLength > 0.2 else { return nil }
        var expected = 0.0
        var covered = 0.0
        var prev: SessionSample?
        for s in samples {
            defer { prev = s }
            guard let p = prev, !s.paused, !p.paused else { continue }
            let dd = s.distance - p.distance
            let dt = s.t - p.t
            guard dd > 0, dt > 0 else { continue }
            let speed = [s.speed, p.speed].compactMap { $0 }.filter { $0 > 0.5 }
            let v = speed.isEmpty ? dd / dt * 3.6 : speed.reduce(0, +) / Double(speed.count)
            expected += dd / StepModel.stepLength(speedKmh: v, walkingStepLength: walkingStepLength)
            covered += dd
        }
        // Séries trop incomplètes (anciens enregistrements) : pas de verdict.
        guard covered >= distanceMeters * 0.8, expected >= 1 else { return nil }
        // Distance manquante dans les échantillons : même longueur de pas moyenne.
        expected *= distanceMeters / covered
        return StepCheck(measuredSteps: measured, expectedSteps: Int(expected.rounded()),
                         ratio: Double(measured) / expected,
                         stepLengthMeters: distanceMeters / Double(measured),
                         expectedStepLengthMeters: distanceMeters / expected,
                         source: stepsSource)
    }
}
