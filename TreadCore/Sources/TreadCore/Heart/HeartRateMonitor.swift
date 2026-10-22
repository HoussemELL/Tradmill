import Foundation

public enum HeartRateSource: String, Codable, CaseIterable, Sendable {
    case bleSensor
    case appleWatch
    case treadmill

    public var label: String {
        switch self {
        case .bleSensor: return "Ceinture/brassard BLE"
        case .appleWatch: return "Apple Watch"
        case .treadmill: return "Capteur du tapis"
        }
    }

    public var shortLabel: String {
        switch self {
        case .bleSensor: return "Ceinture"
        case .appleWatch: return "Watch"
        case .treadmill: return "Tapis"
        }
    }
}

/// Choix de la source par l'utilisateur.
public enum HeartRateSourcePreference: String, Codable, CaseIterable, Sendable {
    /// Priorité ceinture > Watch > tapis, sans mélange : on reste sur la source retenue
    /// tant qu'elle est vivante.
    case automatic
    case bleSensor
    case appleWatch
    case treadmill
    case none

    public var label: String {
        switch self {
        case .automatic: return "Automatique (ceinture > Watch > tapis)"
        case .bleSensor: return "Ceinture/brassard BLE"
        case .appleWatch: return "Apple Watch"
        case .treadmill: return "Capteur du tapis"
        case .none: return "Aucune"
        }
    }
}

public struct HeartRateReading: Equatable, Sendable, Codable {
    public var bpm: Int
    /// Instant de la mesure (horloge monotone de l'iPhone à réception).
    public var receivedAt: TimeInterval
    public var source: HeartRateSource

    public init(bpm: Int, receivedAt: TimeInterval, source: HeartRateSource) {
        self.bpm = bpm
        self.receivedAt = receivedAt
        self.source = source
    }
}

public enum HeartRateStatus: Equatable, Sendable {
    case live(bpm: Int, source: HeartRateSource, age: TimeInterval)
    case stale(lastBPM: Int, source: HeartRateSource, age: TimeInterval)
    case unavailable

    public var liveBPM: Int? {
        if case let .live(bpm, _, _) = self { return bpm }
        return nil
    }
}

/// Sélection d'une seule source cardio à la fois (jamais de moyenne entre sources)
/// et détection des mesures périmées.
public final class HeartRateMonitor {
    public var preference: HeartRateSourcePreference
    /// Âge au-delà duquel une mesure n'est plus affichée comme en direct.
    public var staleAfter: [HeartRateSource: TimeInterval] = [.bleSensor: 5, .appleWatch: 10, .treadmill: 5]
    /// En mode automatique : délai sans mesure avant de basculer vers une autre source.
    public var switchAfter: TimeInterval = 15

    public private(set) var latest: [HeartRateSource: HeartRateReading] = [:]
    public private(set) var activeSource: HeartRateSource?
    public var onSourceChange: ((HeartRateSource?, HeartRateSource?) -> Void)?

    public init(preference: HeartRateSourcePreference = .automatic) {
        self.preference = preference
    }

    public func ingest(_ r: HeartRateReading) {
        guard r.bpm >= 25 && r.bpm <= 250 else { return }
        latest[r.source] = r
        reselect(now: r.receivedAt)
    }

    public func clear(source: HeartRateSource) {
        latest[source] = nil
    }

    private static let priority: [HeartRateSource] = [.bleSensor, .appleWatch, .treadmill]

    private func isAlive(_ s: HeartRateSource, now: TimeInterval, within: TimeInterval) -> Bool {
        guard let r = latest[s] else { return false }
        return now - r.receivedAt <= within
    }

    public func reselect(now: TimeInterval) {
        let newSource: HeartRateSource?
        switch preference {
        case .none: newSource = nil
        case .bleSensor: newSource = .bleSensor
        case .appleWatch: newSource = .appleWatch
        case .treadmill: newSource = .treadmill
        case .automatic:
            if let cur = activeSource, isAlive(cur, now: now, within: switchAfter) {
                newSource = cur
            } else {
                newSource = Self.priority.first { isAlive($0, now: now, within: staleAfter[$0] ?? 5) } ?? activeSource
            }
        }
        if newSource != activeSource {
            let old = activeSource
            activeSource = newSource
            onSourceChange?(old, newSource)
        }
    }

    public func status(now: TimeInterval) -> HeartRateStatus {
        reselect(now: now)
        guard let s = activeSource, let r = latest[s] else { return .unavailable }
        let age = max(0, now - r.receivedAt)
        if age <= (staleAfter[s] ?? 5) { return .live(bpm: r.bpm, source: s, age: age) }
        return .stale(lastBPM: r.bpm, source: s, age: age)
    }
}
