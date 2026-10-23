import Foundation

/// Méthode de calcul des zones.
public enum ZoneMethod: String, Codable, CaseIterable, Sendable {
    /// Méthode par défaut, identique à Rythme et à l'Apple Watch : réserve cardiaque,
    /// bornes basses Z2…Z5 à 60/70/80/90 % de (FC max − FC repos) + FC repos ; sans FC de
    /// repos, mêmes pourcentages de la FC max. La zone 1 n'a pas de plancher.
    case rythme
    /// Pourcentage de la FC maximale.
    case percentOfMax
    /// Réserve cardiaque (Karvonen) avec bornes personnalisables : repos + % × (max − repos).
    case heartRateReserve
    /// Seuils saisis en bpm.
    case customBPM

    public var label: String {
        switch self {
        case .rythme: return "Automatique (comme Rythme et l'Apple Watch)"
        case .percentOfMax: return "% de FC max"
        case .heartRateReserve: return "Réserve cardiaque personnalisée"
        case .customBPM: return "Seuils personnalisés (bpm)"
        }
    }
}

public struct ZoneRange: Equatable, Sendable {
    public var zone: Int
    /// Borne basse incluse (bpm). 0 = pas de plancher (zone 1 de la méthode Rythme).
    public var lower: Int
    /// Borne haute exclue (bpm), sauf la zone 5 qui inclut la FC max.
    public var upper: Int
}

/// Réglages des cinq zones cardiaques.
public struct HeartZoneSettings: Codable, Equatable, Sendable {
    /// FC max effectivement utilisée (saisie par l'utilisateur ou calculée depuis Santé).
    public var maxHR: Int
    /// FC de repos effectivement utilisée.
    public var restingHR: Int?
    public var method: ZoneMethod
    /// Six bornes croissantes en fraction (début Z1 … début Z5, fin Z5) — méthodes % et réserve personnalisée.
    public var percentBounds: [Double]
    /// Six bornes croissantes en bpm pour le mode personnalisé.
    public var customBounds: [Int]
    /// Vrai si la FC max a été saisie dans Foulée (prioritaire sur le calcul depuis Santé).
    public var maxHRIsUserValue: Bool
    /// Vrai si la FC de repos a été saisie dans Foulée.
    public var restingHRIsUserValue: Bool
    /// Origine des valeurs, affichée à l'utilisateur.
    public var maxHRSource: String
    public var restingHRSource: String

    /// Pourcentages des bornes basses Z2…Z5 de la méthode Rythme.
    public static let rythmePercents: [Double] = [0.60, 0.70, 0.80, 0.90]

    public init(maxHR: Int = 200, restingHR: Int? = nil, method: ZoneMethod = .rythme,
                percentBounds: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00],
                customBounds: [Int] = [100, 120, 140, 160, 180, 200],
                maxHRIsUserValue: Bool = false, restingHRIsUserValue: Bool = false,
                maxHRSource: String = "valeur par défaut (Santé non lu)",
                restingHRSource: String = "non disponible") {
        self.maxHR = maxHR
        self.restingHR = restingHR
        self.method = method
        self.percentBounds = percentBounds
        self.customBounds = customBounds
        self.maxHRIsUserValue = maxHRIsUserValue
        self.restingHRIsUserValue = restingHRIsUserValue
        self.maxHRSource = maxHRSource
        self.restingHRSource = restingHRSource
    }

    private enum CodingKeys: String, CodingKey {
        case maxHR, restingHR, method, percentBounds, customBounds
        case maxHRIsUserValue, restingHRIsUserValue, maxHRSource, restingHRSource
    }

    /// Décodage tolérant : les réglages enregistrés par une version antérieure restent lisibles.
    public init(from decoder: Decoder) throws {
        let d = HeartZoneSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxHR = try c.decodeIfPresent(Int.self, forKey: .maxHR) ?? d.maxHR
        restingHR = try c.decodeIfPresent(Int.self, forKey: .restingHR)
        method = (try? c.decodeIfPresent(ZoneMethod.self, forKey: .method)) ?? d.method
        percentBounds = try c.decodeIfPresent([Double].self, forKey: .percentBounds) ?? d.percentBounds
        customBounds = try c.decodeIfPresent([Int].self, forKey: .customBounds) ?? d.customBounds
        maxHRIsUserValue = try c.decodeIfPresent(Bool.self, forKey: .maxHRIsUserValue) ?? false
        restingHRIsUserValue = try c.decodeIfPresent(Bool.self, forKey: .restingHRIsUserValue) ?? false
        maxHRSource = try c.decodeIfPresent(String.self, forKey: .maxHRSource) ?? d.maxHRSource
        restingHRSource = try c.decodeIfPresent(String.self, forKey: .restingHRSource) ?? d.restingHRSource
    }

    /// Anciens réglages par défaut (versions antérieures à la méthode Rythme) : % de FC max avec
    /// les bornes d'origine, sans FC max ni FC de repos saisies. Rien n'y a été choisi.
    public var isLegacyDefault: Bool {
        method == .percentOfMax && !maxHRIsUserValue && !restingHRIsUserValue
            && percentBounds == HeartZoneSettings().percentBounds
    }

    /// Méthode réellement appliquée (la réserve personnalisée exige une FC de repos).
    public var effectiveMethod: ZoneMethod {
        if method == .heartRateReserve && (restingHR == nil || (restingHR ?? 0) >= maxHR) { return .percentOfMax }
        return method
    }

    public func validationError() -> String? {
        if maxHR < 100 || maxHR > 240 { return "FC max hors plage (100–240)" }
        if let r = restingHR, r < 30 || r >= maxHR { return "FC de repos incohérente" }
        if effectiveMethod == .rythme { return nil }
        let b = effectiveMethod == .customBPM ? customBounds.map(Double.init) : percentBounds
        guard b.count == 6 else { return "Six bornes sont nécessaires" }
        for i in 1..<6 where b[i] <= b[i - 1] { return "Les bornes doivent être strictement croissantes" }
        return nil
    }

    /// Six bornes : début Z1 (0 = sans plancher), début Z2…Z5, FC max.
    public var bounds: [Int] {
        switch effectiveMethod {
        case .rythme:
            let max = Double(maxHR)
            let rest = Double(restingHR ?? 0)
            let lows = Self.rythmePercents.map { Int((rest + $0 * (max - rest)).rounded()) }
            return [0] + lows + [maxHR]
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

    /// Zone 1…5. Méthode Rythme : tout ce qui est sous Z2 compte en Z1 (jamais 0).
    /// Autres méthodes : 0 sous la zone 1. Au-dessus de la FC max : zone 5.
    public func zone(for bpm: Int) -> Int {
        let b = bounds
        guard b.count == 6 else { return 0 }
        for z in (2...5).reversed() where bpm >= b[z - 1] { return z }
        if effectiveMethod == .rythme { return 1 }
        return bpm >= b[0] ? 1 : 0
    }

    public var methodDescription: String {
        let maxText = "FC max \(maxHR) bpm (\(maxHRIsUserValue ? "saisie dans Foulée" : maxHRSource))"
        let restText = restingHR.map { "FC repos \($0) bpm (\(restingHRIsUserValue ? "saisie dans Foulée" : restingHRSource))" }
        switch effectiveMethod {
        case .rythme:
            if let restText {
                return "Comme Rythme : Z2…Z5 à 60/70/80/90 % de la réserve cardiaque + repos. \(maxText), \(restText)."
            }
            return "Comme Rythme : Z2…Z5 à 60/70/80/90 % de la FC max (FC de repos indisponible). \(maxText)."
        case .percentOfMax:
            var s = "Zones en % de la FC max. \(maxText)."
            if method == .heartRateReserve { s += " Réserve cardiaque indisponible sans FC de repos valide." }
            return s
        case .heartRateReserve:
            return "Réserve cardiaque personnalisée. \(maxText), \(restText ?? "")."
        case .customBPM:
            return "Seuils personnalisés en bpm"
        }
    }
}

/// Calcul de la FC max et de la FC de repos à partir des données de Santé (règles de Rythme).
public enum ZoneProfileResolver {
    public struct HRPoint: Equatable, Sendable {
        public var date: Date
        public var bpm: Double
        public init(date: Date, bpm: Double) { self.date = date; self.bpm = bpm }
    }

    public struct Result: Equatable, Sendable {
        public var maxHR: Int
        public var maxSource: String
        public var restingHR: Int?
        public var restingSource: String
    }

    /// Seuil de lecture des mesures dans Santé : 170 bpm, moins la tolérance de 5 bpm
    /// (une mesure voisine à 166 bpm valide une mesure à 171).
    public static let highHRQueryThreshold: Double = 165
    public static let candidateThreshold: Double = 170
    public static let maxPlausible: Double = 230

    /// Plus haute FC « tenue » : une mesure ≥ 170 et ≤ 230 n'est retenue que si une autre
    /// mesure, dans les 2 minutes, est au plus 5 bpm en dessous. Un pic isolé est ignoré.
    public static func sustainedMax(_ points: [HRPoint]) -> HRPoint? {
        let valid = points.filter { $0.bpm <= maxPlausible }.sorted { $0.date < $1.date }
        var best: HRPoint?
        for (i, p) in valid.enumerated() where p.bpm >= candidateThreshold {
            if let b = best, b.bpm >= p.bpm { continue }
            var confirmed = false
            // Voisins avant/après dans la fenêtre de 2 minutes.
            var j = i - 1
            while j >= 0, p.date.timeIntervalSince(valid[j].date) <= 120 {
                if valid[j].bpm >= p.bpm - 5 { confirmed = true; break }
                j -= 1
            }
            var k = i + 1
            while !confirmed, k < valid.count, valid[k].date.timeIntervalSince(p.date) <= 120 {
                if valid[k].bpm >= p.bpm - 5 { confirmed = true; break }
                k += 1
            }
            if confirmed { best = p }
        }
        return best
    }

    public static func age(birthDate: Date, now: Date) -> Int? {
        let cal = Calendar(identifier: .gregorian)
        let years = cal.dateComponents([.year], from: birthDate, to: now).year
        return years.flatMap { $0 > 0 && $0 < 120 ? $0 : nil }
    }

    /// - userMax / userResting : valeurs saisies dans Foulée (prioritaires).
    /// - highHR : mesures de FC ≥ 165 bpm des 12 derniers mois.
    /// - restingHR : valeurs restingHeartRate des 30 derniers jours.
    public static func resolve(userMax: Int?, userResting: Int?, birthDate: Date?, now: Date,
                               highHR: [HRPoint], restingHR: [Double], fallbackMax: Int = 200) -> Result {
        let maxHR: Int
        let maxSource: String
        if let u = userMax {
            maxHR = u
            maxSource = "saisie dans Foulée"
        } else {
            let ageBased = birthDate.flatMap { age(birthDate: $0, now: now) }.map { 220 - $0 }
            let sustained = sustainedMax(highHR)
            let df = DateFormatter()
            df.locale = Locale(identifier: "fr_FR")
            df.dateStyle = .medium
            switch (ageBased, sustained) {
            case let (a?, s?) where Int(s.bpm.rounded()) > a:
                maxHR = Int(s.bpm.rounded())
                maxSource = "FC tenue la plus haute sur 12 mois (\(df.string(from: s.date))) > 220 − âge (\(a))"
            case let (a?, _):
                maxHR = a
                maxSource = "220 − âge" + (sustained.map { " (FC tenue max 12 mois : \(Int($0.bpm.rounded())))" } ?? "")
            case let (nil, s?):
                maxHR = Int(s.bpm.rounded())
                maxSource = "FC tenue la plus haute sur 12 mois (\(df.string(from: s.date))) ; date de naissance indisponible"
            case (nil, nil):
                maxHR = fallbackMax
                maxSource = "valeur par défaut : date de naissance et mesures ≥ 170 bpm indisponibles dans Santé"
            }
        }
        if let r = userResting {
            return Result(maxHR: maxHR, maxSource: maxSource, restingHR: r, restingSource: "saisie dans Foulée")
        }
        guard !restingHR.isEmpty else {
            return Result(maxHR: maxHR, maxSource: maxSource, restingHR: nil, restingSource: "aucune FC de repos dans Santé (30 j)")
        }
        let avg = restingHR.reduce(0, +) / Double(restingHR.count)
        let rounded = Int(avg.rounded())
        if rounded < 30 || rounded > maxHR - 40 {
            return Result(maxHR: maxHR, maxSource: maxSource, restingHR: nil,
                          restingSource: "moyenne 30 j (\(rounded) bpm) ignorée : hors plage 30…FC max − 40")
        }
        return Result(maxHR: maxHR, maxSource: maxSource, restingHR: rounded,
                      restingSource: "moyenne Santé sur 30 j (\(restingHR.count) valeurs)")
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
