import Foundation

/// Réglages d'une phase dont la vitesse suit la fréquence cardiaque (programme « Zone 2 auto »).
/// Toutes les vitesses sont en km/h. L'objectif est le temps passé dans la zone, pas la vitesse.
public struct AutoSpeedSettings: Codable, Equatable, Hashable, Sendable {
    /// Zone visée (1…5).
    public var targetZone: Int
    /// Bornes de la vitesse automatique (en plus des limites du tapis).
    public var minKmh: Double
    public var maxKmh: Double
    /// Palier de chaque ajustement.
    public var stepKmh: Double
    /// Délai minimal entre deux accélérations (inertie cardiaque).
    public var increaseInterval: TimeInterval
    /// Délai minimal entre deux ralentissements quand la FC reste trop haute.
    public var decreaseInterval: TimeInterval
    /// Fenêtre de la FC filtrée (moyenne glissante).
    public var filterSeconds: TimeInterval
    /// Marge sous la limite haute de la zone (bpm) : au-delà, on ralentit.
    public var upperMarginBpm: Int
    /// Accélérer doucement (deux fois moins souvent) quand la FC est dans le quart bas de la
    /// zone, pour viser son milieu. Désactivé : la vitesse est maintenue dans toute la zone.
    public var nudgeTowardMiddle: Bool
    /// Allure lente sécurisée en cas de perte de la FC.
    public var fallbackKmh: Double

    public init(targetZone: Int = 2, minKmh: Double = 4.0, maxKmh: Double = 7.0, stepKmh: Double = 0.2,
                increaseInterval: TimeInterval = 60, decreaseInterval: TimeInterval = 20,
                filterSeconds: TimeInterval = 18, upperMarginBpm: Int = 3, nudgeTowardMiddle: Bool = true,
                fallbackKmh: Double = 4.5) {
        self.targetZone = targetZone
        self.minKmh = minKmh
        self.maxKmh = maxKmh
        self.stepKmh = stepKmh
        self.increaseInterval = increaseInterval
        self.decreaseInterval = decreaseInterval
        self.filterSeconds = filterSeconds
        self.upperMarginBpm = upperMarginBpm
        self.nudgeTowardMiddle = nudgeTowardMiddle
        self.fallbackKmh = fallbackKmh
    }

    var signature: String {
        String(format: "z%d,%.1f-%.1f,s%.2f,u%.0f,d%.0f,f%.0f,m%d,n%d,fb%.1f", targetZone, minKmh, maxKmh, stepKmh,
               increaseInterval, decreaseInterval, filterSeconds, upperMarginBpm, nudgeTowardMiddle ? 1 : 0, fallbackKmh)
    }

    public func validationError() -> String? {
        if !(1...5).contains(targetZone) { return "Zone visée invalide" }
        if minKmh <= 0 || maxKmh <= minKmh { return "Bornes de vitesse automatique invalides" }
        if stepKmh <= 0 || stepKmh > 1 { return "Palier d'ajustement invalide (0,1–1 km/h)" }
        if increaseInterval < 20 { return "Délai entre accélérations trop court (≥ 20 s)" }
        if decreaseInterval < 5 { return "Délai entre ralentissements trop court (≥ 5 s)" }
        if filterSeconds < 5 || filterSeconds > 60 { return "Filtre de FC hors plage (5–60 s)" }
        if fallbackKmh <= 0 { return "Allure de sécurité invalide" }
        return nil
    }
}

/// Moyenne glissante de la FC sur une fenêtre de temps, pour ne pas réagir à une mesure isolée.
/// Une seule source à la fois : changer de source vide le filtre.
public struct HeartRateFilter: Equatable, Sendable {
    public var window: TimeInterval
    private var points: [(t: TimeInterval, bpm: Int)] = []
    private var source: HeartRateSource?

    public init(window: TimeInterval) { self.window = window }

    public static func == (a: HeartRateFilter, b: HeartRateFilter) -> Bool {
        a.window == b.window && a.source == b.source && a.points.map(\.t) == b.points.map(\.t)
            && a.points.map(\.bpm) == b.points.map(\.bpm)
    }

    public mutating func add(_ r: HeartRateReading) {
        if source != r.source { points.removeAll(); source = r.source }
        if let last = points.last, r.receivedAt <= last.t { return }
        points.append((r.receivedAt, r.bpm))
        points.removeAll { r.receivedAt - $0.t > window * 2 }
    }

    public mutating func reset() { points.removeAll(); source = nil }

    /// FC filtrée, ou nil si la fenêtre n'est pas assez remplie (≥ 2 mesures couvrant au moins
    /// un tiers de la fenêtre — l'Apple Watch n'envoie qu'une mesure toutes les ≈ 5 s —, la plus
    /// récente datant de moins de 10 s).
    public func value(at now: TimeInterval) -> Double? {
        let recent = points.filter { now - $0.t <= window }
        guard recent.count >= 2, let first = recent.first, let last = recent.last,
              last.t - first.t >= window / 3, now - last.t <= 10 else { return nil }
        return Double(recent.map(\.bpm).reduce(0, +)) / Double(recent.count)
    }
}

/// Ajustement automatique enregistré dans la séance.
public struct AutoAdjustment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case increase, decrease, safety }
    /// Secondes depuis le début de la séance.
    public var t: Double
    public var fromKmh: Double
    public var toKmh: Double
    public var filteredBPM: Int?
    public var kind: Kind
    public var reason: String

    public init(t: Double, fromKmh: Double, toKmh: Double, filteredBPM: Int?, kind: Kind, reason: String) {
        self.t = t
        self.fromKmh = fromKmh
        self.toKmh = toKmh
        self.filteredBPM = filteredBPM
        self.kind = kind
        self.reason = reason
    }
}

/// Pilote de vitesse par la FC (une phase « auto »). Logique pure, sans E/S :
/// la séance lui fournit la FC filtrée et applique la consigne retournée.
///
/// Règles :
/// - FC sous la zone : +palier, au plus une accélération par `increaseInterval` (60 s), et
///   jamais dans les 60 s qui suivent un changement (délai de réaction du cœur).
/// - FC dans la zone : vitesse maintenue (option : accélération deux fois plus rare dans le
///   quart bas de la zone, pour viser le milieu).
/// - FC au-dessus de (limite haute − marge) pendant `decreaseInterval` : −palier, toutes les
///   `decreaseInterval` (20 s) ; −2 paliers si la FC dépasse la limite haute de plus de 5 bpm.
/// - FC indisponible : plus aucune accélération, immédiatement ; après 15 s sans FC, descente
///   progressive (−palier toutes les 5 s) vers l'allure de sécurité, si le tapis est pilotable ;
///   sinon pilotage suspendu.
/// - Consigne manuelle : le pilote se retire jusqu'à réactivation explicite.
public final class ZoneAutopilot {
    public enum Mode: Equatable, Sendable {
        /// FC filtrée pas encore disponible : vitesse de départ maintenue.
        case warmingUp
        case regulating
        /// FC perdue : accélérations désactivées, retour progressif à l'allure de sécurité.
        case heartRateLost
        /// FC momentanément absente (moins de `heartRateGrace`) : vitesse figée, aucune accélération.
        case heartRateGap
        /// L'utilisateur a pris la main.
        case manual
        /// Tapis non pilotable (connexion perdue, pause…).
        case suspended

        public var label: String {
            switch self {
            case .warmingUp: return "Lecture de la FC…"
            case .regulating: return "Pilotage FC actif"
            case .heartRateLost: return "FC indisponible : accélérations désactivées"
            case .heartRateGap: return "FC momentanément absente : vitesse maintenue, aucune accélération"
            case .manual: return "Contrôle manuel"
            case .suspended: return "Pilotage suspendu"
            }
        }
    }

    public enum Trend: Equatable, Sendable { case below, inZone, nearTop, above, unknown }

    public let settings: AutoSpeedSettings
    public private(set) var mode: Mode = .warmingUp
    /// Consigne automatique courante (km/h, arrondie à l'incrément).
    public private(set) var targetKmh: Double
    public private(set) var trend: Trend = .unknown
    public private(set) var lastFilteredBPM: Double?
    public private(set) var adjustmentCount = 0
    /// Dernier message d'état (pour l'affichage).
    public private(set) var status: String = ""

    private let speedMin: Double
    private let speedMax: Double
    private let increment: Double
    private var lastChangeAt: TimeInterval
    private var aboveSince: TimeInterval?
    private var lastSafetyStepAt: TimeInterval = -.infinity
    public static let safetyStepInterval: TimeInterval = 5
    /// Délai sans FC avant le ralentissement de sécurité (les accélérations, elles, cessent
    /// immédiatement) : une mesure retardée de la montre ne fait pas freiner le tapis.
    public static let heartRateGrace: TimeInterval = 15
    private var heartRateMissingSince: TimeInterval?

    /// - Parameters:
    ///   - startKmh: vitesse de départ de la phase.
    ///   - capabilities: limites réelles du tapis (plage et incrément).
    public init(settings: AutoSpeedSettings, startKmh: Double, capabilities: TreadmillCapabilities, now: TimeInterval) {
        self.settings = settings
        let s = capabilities.speed
        speedMin = max(settings.minKmh, s.minKmh)
        speedMax = max(speedMin, min(settings.maxKmh, s.maxKmh))
        increment = s.incrementKmh > 0 ? s.incrementKmh : 0.1
        targetKmh = 0
        lastChangeAt = now
        targetKmh = snap(startKmh)
        status = mode.label
    }

    private func snap(_ v: Double) -> Double {
        let c = min(max(v, speedMin), speedMax)
        let steps = ((c - speedMin) / increment).rounded()
        return ((speedMin + steps * increment) * 100).rounded() / 100
    }

    /// Reprise après une pause : on repart du délai complet avant toute accélération.
    public func didResume(at now: TimeInterval) {
        lastChangeAt = now
        aboveSince = nil
        if mode == .suspended { mode = .warmingUp }
    }

    public func suspend() {
        if mode != .manual { mode = .suspended }
        status = mode.label
    }

    /// L'utilisateur a réglé la vitesse lui-même : le pilote se retire.
    public func takeManualControl() {
        mode = .manual
        status = mode.label
    }

    /// Réactivation explicite : on repart de la vitesse actuelle (pas de saut).
    public func resumeAutomatic(fromKmh current: Double, at now: TimeInterval) {
        mode = .warmingUp
        targetKmh = snap(current)
        lastChangeAt = now
        aboveSince = nil
        status = mode.label
    }

    /// Calcule la consigne. Renvoie un ajustement si elle change.
    /// - Parameters:
    ///   - filteredBPM: FC filtrée (nil si la fenêtre n'est pas remplie).
    ///   - heartRateLive: une mesure en direct est disponible (sinon : perte de FC).
    ///   - zone: bornes de la zone visée.
    ///   - controllable: le tapis tourne et accepte des consignes.
    public func update(now: TimeInterval, sessionTime: Double, filteredBPM: Double?, heartRateLive: Bool,
                       zone: ZoneRange?, controllable: Bool) -> AutoAdjustment? {
        if mode == .manual { return nil }
        guard controllable else {
            suspend()
            return nil
        }
        if mode == .suspended { mode = .warmingUp }
        lastFilteredBPM = filteredBPM

        // Perte de FC : jamais d'accélération, descente progressive vers l'allure de sécurité.
        guard heartRateLive, let zone else {
            let since = heartRateMissingSince ?? now
            heartRateMissingSince = since
            trend = .unknown
            aboveSince = nil
            if now - since < Self.heartRateGrace {
                if mode != .heartRateLost { mode = .heartRateGap }
                status = mode.label
                return nil
            }
            mode = .heartRateLost
            let floor = snap(settings.fallbackKmh)
            guard targetKmh > floor + 0.001, now - lastSafetyStepAt >= Self.safetyStepInterval else {
                status = targetKmh > floor + 0.001 ? mode.label : "FC indisponible : allure de sécurité \(fmt(targetKmh)) km/h"
                return nil
            }
            lastSafetyStepAt = now
            return change(to: snap(max(floor, targetKmh - settings.stepKmh)), now: now, sessionTime: sessionTime,
                          kind: .safety, reason: "FC indisponible : ralentissement progressif vers l'allure de sécurité")
        }
        heartRateMissingSince = nil
        if mode == .heartRateLost {
            // FC revenue : on repart sans accélérer avant le délai complet.
            mode = .warmingUp
            lastChangeAt = now
        } else if mode == .heartRateGap {
            mode = .warmingUp
        }
        guard let hr = filteredBPM else {
            status = mode.label
            return nil
        }
        mode = .regulating

        let lower = Double(zone.lower)
        let upper = Double(zone.upper)
        let ceiling = upper - Double(settings.upperMarginBpm)
        let width = max(upper - lower, 1)
        let sinceChange = now - lastChangeAt

        if hr >= ceiling {
            trend = hr >= upper ? .above : .nearTop
            if aboveSince == nil { aboveSince = now }
            let sustained = now - (aboveSince ?? now) >= settings.decreaseInterval
            if sustained, sinceChange >= settings.decreaseInterval, targetKmh > speedMin + 0.001 {
                let steps = hr > upper + 5 ? 2.0 : 1.0
                return change(to: snap(targetKmh - settings.stepKmh * steps), now: now, sessionTime: sessionTime,
                              kind: .decrease,
                              reason: String(format: "FC %.0f ≥ %.0f (limite haute − marge) : ralentissement", hr, ceiling))
            }
            status = targetKmh <= speedMin + 0.001 ? "FC haute, vitesse minimale atteinte" : "FC haute : ralentissement si elle se maintient"
            return nil
        }
        aboveSince = nil

        if hr < lower {
            trend = .below
            if targetKmh >= speedMax - 0.001 {
                status = "Sous la zone, vitesse maximale automatique atteinte"
                return nil
            }
            if sinceChange >= settings.increaseInterval {
                return change(to: snap(targetKmh + settings.stepKmh), now: now, sessionTime: sessionTime, kind: .increase,
                              reason: String(format: "FC %.0f sous la zone (%.0f) : accélération", hr, lower))
            }
            status = "Sous la zone : prochaine accélération dans \(Int(settings.increaseInterval - sinceChange)) s"
            return nil
        }

        trend = .inZone
        if settings.nudgeTowardMiddle, hr < lower + width * 0.25, targetKmh < speedMax - 0.001,
           sinceChange >= settings.increaseInterval * 2 {
            return change(to: snap(targetKmh + settings.stepKmh), now: now, sessionTime: sessionTime, kind: .increase,
                          reason: String(format: "FC %.0f dans le bas de la zone : légère accélération vers le milieu", hr))
        }
        status = "Dans la zone : vitesse maintenue"
        return nil
    }

    private func change(to v: Double, now: TimeInterval, sessionTime: Double, kind: AutoAdjustment.Kind, reason: String) -> AutoAdjustment? {
        guard abs(v - targetKmh) > 0.001 else { return nil }
        let adj = AutoAdjustment(t: sessionTime, fromKmh: targetKmh, toKmh: v,
                                 filteredBPM: lastFilteredBPM.map { Int($0.rounded()) }, kind: kind, reason: reason)
        targetKmh = v
        lastChangeAt = now
        if kind != .safety { aboveSince = nil }
        adjustmentCount += 1
        status = reason
        return adj
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
