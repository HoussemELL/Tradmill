import Foundation

/// Profil matériel : comportements spécifiques à un modèle, séparés du FTMS générique.
///
/// Les profils ne modifient jamais le format des octets FTMS ; ils décrivent l'ordre
/// des commandes, les délais et tolérances observés sur un modèle donné.
public struct TreadmillProfile: Equatable, Sendable, Codable, Identifiable {
    public enum Step: String, Sendable, Codable, CustomStringConvertible {
        case requestControl
        case setInitialSpeed
        case startOrResume

        public var description: String {
            switch self {
            case .requestControl: return "Request Control"
            case .setInitialSpeed: return "Set Target Speed (initiale)"
            case .startOrResume: return "Start"
            }
        }
    }

    public var id: String
    public var name: String
    public var notes: String
    /// Préfixes de nom BLE reconnus automatiquement (comparaison insensible à la casse).
    public var namePrefixes: [String]
    public var startSteps: [Step]
    public var resumeSteps: [Step]
    /// Vitesse initiale explicite envoyée avant Start (bornée par la plage du tapis et la cible).
    public var initialSpeedKmh: Double
    /// Délai pour observer le tapis en mouvement après Start (inclut un éventuel compte à rebours).
    public var beltStartTimeout: TimeInterval
    public var speedToleranceKmh: Double
    public var inclineTolerancePercent: Double
    /// Accélération supposée pour calculer le délai d'atteinte d'une consigne.
    public var speedRampKmhPerSecond: Double
    public var speedSettleBase: TimeInterval
    public var inclineRampPercentPerSecond: Double
    public var inclineSettleBase: TimeInterval
    /// Nombre de renvois de la même consigne si la valeur n'est pas observée (jamais de Start).
    public var maxTargetResends: Int
    public var responseTimeout: TimeInterval
    public var commandSpacing: TimeInterval
    /// Capacités supposées si la lecture des plages échoue.
    public var fallbackCapabilities: TreadmillCapabilities

    public static let genericFTMS = TreadmillProfile(
        id: "generic-ftms",
        name: "FTMS générique",
        notes: "Request Control → Start → attente du mouvement → consignes du palier.",
        namePrefixes: [],
        startSteps: [.requestControl, .startOrResume],
        resumeSteps: [.requestControl, .startOrResume],
        initialSpeedKmh: 1.0,
        beltStartTimeout: 15,
        speedToleranceKmh: 0.2,
        inclineTolerancePercent: 0.6,
        speedRampKmhPerSecond: 0.3,
        speedSettleBase: 5,
        inclineRampPercentPerSecond: 0.3,
        inclineSettleBase: 8,
        maxTargetResends: 0,
        responseTimeout: 4,
        commandSpacing: 0.3,
        fallbackCapabilities: TreadmillCapabilities(
            speed: SpeedRange(minKmh: 1.0, maxKmh: 10.0, incrementKmh: 0.1),
            inclination: nil, feature: nil,
            speedRangeFromDevice: false, inclinationRangeFromDevice: false)
    )

    /// UREVO FoldiMix 5L (nom BLE « URTM047 »).
    ///
    /// Observations rapportées (à confirmer par le diagnostic) :
    /// - Request Control → Set Target Speed → Start produit un mouvement ;
    /// - Request Control → Start (avec ou sans vitesse ensuite) n'en a pas produit ;
    /// - une commande peut être acquittée sans effet observable.
    /// D'où : vitesse initiale basse et explicite avant Start, puis consigne du palier
    /// une fois le mouvement observé dans la télémétrie, avec au plus un renvoi de consigne.
    public static let urtm047 = TreadmillProfile(
        id: "urevo-urtm047",
        name: "UREVO FoldiMix 5L (URTM047)",
        notes: "Request Control → Set Target Speed (vitesse basse) → Start → attente du mouvement → consigne du palier. Aucun Start supplémentaire lors des changements de vitesse.",
        namePrefixes: ["URTM047", "URTM"],
        startSteps: [.requestControl, .setInitialSpeed, .startOrResume],
        resumeSteps: [.requestControl, .setInitialSpeed, .startOrResume],
        initialSpeedKmh: 1.5,
        beltStartTimeout: 15,
        speedToleranceKmh: 0.15,
        inclineTolerancePercent: 0.6,
        speedRampKmhPerSecond: 0.25,
        speedSettleBase: 5,
        inclineRampPercentPerSecond: 0.25,
        inclineSettleBase: 10,
        maxTargetResends: 1,
        responseTimeout: 4,
        commandSpacing: 0.4,
        fallbackCapabilities: TreadmillCapabilities(
            speed: SpeedRange(minKmh: 1.0, maxKmh: 12.0, incrementKmh: 0.1),
            inclination: InclinationRange(minPercent: 0, maxPercent: 9, incrementPercent: 1),
            feature: nil,
            speedRangeFromDevice: false, inclinationRangeFromDevice: false)
    )

    public static let all: [TreadmillProfile] = [.urtm047, .genericFTMS]

    public static func profile(id: String) -> TreadmillProfile? {
        all.first { $0.id == id }
    }

    /// Profil correspondant au nom BLE annoncé, sinon FTMS générique.
    public static func match(deviceName: String?) -> TreadmillProfile {
        guard let name = deviceName?.uppercased(), !name.isEmpty else { return .genericFTMS }
        return all.first { p in p.namePrefixes.contains { name.hasPrefix($0.uppercased()) } } ?? .genericFTMS
    }

    /// Vitesse initiale effectivement envoyée : basse, dans la plage, jamais supérieure à la cible.
    public func initialSpeed(target: Double, capabilities: TreadmillCapabilities) -> Double {
        capabilities.snapSpeed(min(initialSpeedKmh, target))
    }

    public func speedSettleTime(from: Double?, to: Double) -> TimeInterval {
        let delta = abs(to - (from ?? 0))
        return speedSettleBase + delta / max(speedRampKmhPerSecond, 0.05)
    }

    public func inclineSettleTime(from: Double?, to: Double) -> TimeInterval {
        let delta = abs(to - (from ?? 0))
        return inclineSettleBase + delta / max(inclineRampPercentPerSecond, 0.05)
    }
}
