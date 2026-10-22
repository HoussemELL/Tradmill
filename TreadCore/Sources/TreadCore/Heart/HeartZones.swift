import Foundation

/// Méthode de calcul des zones.
public enum ZoneMethod: String, Codable, CaseIterable, Sendable {
    /// Pourcentage de la FC maximale.
    case percentOfMax
    /// Réserve cardiaque (Karvonen) : repos + % × (max − repos).
    case heartRateReserve
    /// Seuils saisis en bpm.
    case customBPM

    public var label: String {
        switch self {
        case .percentOfMax: return "% de FC max"
        case .heartRateReserve: return "Réserve cardiaque (Karvonen)"
        case .customBPM: return "Seuils personnalisés (bpm)"
        }
    }
}

public struct ZoneRange: Equatable, Sendable {
    public var zone: Int
    /// Borne basse incluse (bpm).
    public var lower: Int
    /// Borne haute exclue (bpm), sauf la zone 5 qui inclut la FC max.
    public var upper: Int
}

/// Réglages des cinq zones cardiaques.
public struct HeartZoneSettings: Codable, Equatable, Sendable {
    public var maxHR: Int
    public var restingHR: Int?
    public var method: ZoneMethod
    /// Six bornes croissantes en fraction (début Z1 … début Z5, fin Z5).
    public var percentBounds: [Double]
    /// Six bornes croissantes en bpm pour le mode personnalisé.
    public var customBounds: [Int]

    public init(maxHR: Int = 200, restingHR: Int? = nil, method: ZoneMethod = .percentOfMax,
                percentBounds: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00],
                customBounds: [Int] = [100, 120, 140, 160, 180, 200]) {
        self.maxHR = maxHR
        self.restingHR = restingHR
        self.method = method
        self.percentBounds = percentBounds
        self.customBounds = customBounds
    }

    /// Méthode réellement appliquée (la réserve cardiaque exige une FC de repos).
    public var effectiveMethod: ZoneMethod {
        if method == .heartRateReserve && (restingHR == nil || (restingHR ?? 0) >= maxHR) { return .percentOfMax }
        return method
    }

    public func validationError() -> String? {
        if maxHR < 100 || maxHR > 240 { return "FC max hors plage (100–240)" }
        if let r = restingHR, r < 30 || r >= maxHR { return "FC de repos incohérente" }
        let b = effectiveMethod == .customBPM ? customBounds.map(Double.init) : percentBounds
        guard b.count == 6 else { return "Six bornes sont nécessaires" }
        for i in 1..<6 where b[i] <= b[i - 1] { return "Les bornes doivent être strictement croissantes" }
        return nil
    }

    public var bounds: [Int] {
        switch effectiveMethod {
        case .customBPM:
            return customBounds
        case .percentOfMax:
            return percentBounds.map { Int((Double(maxHR) * $0).rounded()) }
        case .heartRateReserve:
            let rest = Double(restingHR ?? 0)
            return percentBounds.map { Int((rest + $0 * (Double(maxHR) - rest)).rounded()) }
        }
    }

    public var zones: [ZoneRange] {
        let b = bounds
        guard b.count == 6 else { return [] }
        return (0..<5).map { ZoneRange(zone: $0 + 1, lower: b[$0], upper: b[$0 + 1]) }
    }

    /// Zone 1…5, 0 sous la zone 1. Au-dessus de la borne haute de Z5 : zone 5.
    public func zone(for bpm: Int) -> Int {
        let b = bounds
        guard b.count == 6 else { return 0 }
        if bpm < b[0] { return 0 }
        for z in (1...5).reversed() where bpm >= b[z - 1] { return z }
        return 0
    }

    public var methodDescription: String {
        switch effectiveMethod {
        case .percentOfMax:
            var s = "Zones en % de la FC max (\(maxHR) bpm)"
            if method == .heartRateReserve { s += " — réserve cardiaque indisponible sans FC de repos valide" }
            return s
        case .heartRateReserve:
            return "Réserve cardiaque : repos \(restingHR ?? 0) + % × (\(maxHR) − \(restingHR ?? 0))"
        case .customBPM:
            return "Seuils personnalisés en bpm"
        }
    }
}

/// Temps passé par zone (index 0 = sous Z1, 1…5).
public struct ZoneTimeAccumulator: Codable, Equatable, Sendable {
    public private(set) var seconds: [TimeInterval] = Array(repeating: 0, count: 6)
    private var lastTime: TimeInterval?
    private var lastZone: Int?
    /// Écart maximal entre deux mesures comptabilisé (au-delà : trou, non compté).
    public var maxGap: TimeInterval

    public init(maxGap: TimeInterval = 5) { self.maxGap = maxGap }

    private enum CodingKeys: String, CodingKey { case seconds, maxGap }

    /// Ajoute une mesure ; `zone` nil = pas de FC valide.
    public mutating func add(zone: Int?, at t: TimeInterval) {
        if let lt = lastTime, let lz = lastZone {
            let dt = t - lt
            if dt > 0 && dt <= maxGap { seconds[lz] += dt }
        }
        lastTime = zone == nil ? nil : t
        lastZone = zone
    }

    /// Interruption (pause, perte de signal) : aucun temps compté jusqu'à la prochaine mesure.
    public mutating func interrupt() { lastTime = nil; lastZone = nil }

    public var total: TimeInterval { seconds.reduce(0, +) }
}

/// Alertes de zone avec temporisation : une alerte ne part qu'après un séjour
/// continu hors de la zone cible, puis un délai minimal entre deux alertes.
public struct ZoneAlertDebouncer: Equatable, Sendable {
    public enum Alert: Equatable, Sendable { case above(target: Int, current: Int), below(target: Int, current: Int) }

    public var dwell: TimeInterval
    public var cooldown: TimeInterval
    private var outsideSince: TimeInterval?
    private var outsideDirection: Int = 0
    private var lastAlertAt: TimeInterval?

    public init(dwell: TimeInterval = 20, cooldown: TimeInterval = 90) {
        self.dwell = dwell
        self.cooldown = cooldown
    }

    public mutating func reset() {
        outsideSince = nil
        outsideDirection = 0
    }

    public mutating func evaluate(currentZone: Int?, targetZone: Int?, at t: TimeInterval) -> Alert? {
        guard let target = targetZone, let current = currentZone else { reset(); return nil }
        let dir = current > target ? 1 : (current < target ? -1 : 0)
        if dir == 0 { reset(); return nil }
        if dir != outsideDirection {
            outsideDirection = dir
            outsideSince = t
            return nil
        }
        guard let since = outsideSince, t - since >= dwell else { return nil }
        if let last = lastAlertAt, t - last < cooldown { return nil }
        lastAlertAt = t
        outsideSince = t
        return dir > 0 ? .above(target: target, current: current) : .below(target: target, current: current)
    }
}
