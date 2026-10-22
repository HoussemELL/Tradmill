import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Horloge monotone en secondes. Sur Darwin, CLOCK_MONOTONIC continue pendant la veille
/// de l'appareil (contrairement à `systemUptime`) et ne saute pas si l'heure système change.
public enum MonotonicClock {
    public static func now() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }
}

/// Position dans le programme à un instant donné.
public struct EnginePosition: Equatable, Sendable {
    public var phaseIndex: Int?
    public var phaseElapsed: TimeInterval
    public var phaseRemaining: TimeInterval
    public var programElapsed: TimeInterval
    public var programRemaining: TimeInterval
    public var isFinished: Bool
}

public enum EngineEvent: Equatable, Sendable {
    /// Nouvelle phase active. `skipped` = phases entièrement écoulées entre deux mises à jour
    /// (ex. app suspendue) : leurs consignes ne sont pas rejouées.
    case phaseStarted(index: Int, skipped: [Int])
    case finished
}

/// Moteur de programme : calcule la phase courante à partir d'une base de temps
/// monotone et de segments actifs, sans dépendre d'un Timer d'affichage.
/// Pause/reprise conservent la progression ; « phase suivante » décale la position.
public final class ProgramEngine {
    public enum State: Equatable, Sendable {
        case ready
        case running(since: TimeInterval)
        case paused
        case finished
    }

    public let schedule: [ScheduledPhase]
    public let totalDuration: TimeInterval
    public private(set) var state: State = .ready
    /// Temps actif cumulé des segments terminés (hors pauses).
    public private(set) var accumulatedActive: TimeInterval = 0
    /// Avance de programme due aux sauts de phase.
    public private(set) var skipOffset: TimeInterval = 0
    public private(set) var currentIndex: Int?

    /// `schedule` vide = séance libre (pas de phases, temps actif seulement).
    public init(schedule: [ScheduledPhase]) {
        self.schedule = schedule
        self.totalDuration = TimeInterval(schedule.last?.end ?? 0)
    }

    public var isFreeRun: Bool { schedule.isEmpty }

    public func activeElapsed(at now: TimeInterval) -> TimeInterval {
        if case let .running(since) = state { return accumulatedActive + max(0, now - since) }
        return accumulatedActive
    }

    public func programElapsed(at now: TimeInterval) -> TimeInterval {
        let t = activeElapsed(at: now) + skipOffset
        return isFreeRun ? t : min(t, totalDuration)
    }

    @discardableResult
    public func start(at now: TimeInterval) -> [EngineEvent] {
        guard state == .ready else { return [] }
        state = .running(since: now)
        return update(at: now)
    }

    public func pause(at now: TimeInterval) {
        guard case let .running(since) = state else { return }
        accumulatedActive += max(0, now - since)
        state = .paused
    }

    @discardableResult
    public func resume(at now: TimeInterval) -> [EngineEvent] {
        guard state == .paused else { return [] }
        state = .running(since: now)
        return update(at: now)
    }

    /// Termine immédiatement (arrêt utilisateur).
    public func finish(at now: TimeInterval) {
        if case .running = state { pause(at: now) }
        state = .finished
    }

    /// Passe au début de la phase suivante.
    @discardableResult
    public func skipToNextPhase(at now: TimeInterval) -> [EngineEvent] {
        guard !isFreeRun, state != .finished, state != .ready else { return [] }
        let pos = programElapsed(at: now)
        guard let idx = phaseIndex(at: pos) else { return [] }
        let nextStart = TimeInterval(schedule[idx].end)
        skipOffset += max(0, nextStart - pos)
        return update(at: now)
    }

    public func phaseIndex(at programTime: TimeInterval) -> Int? {
        guard !schedule.isEmpty, programTime < totalDuration else { return nil }
        // Recherche binaire : la dernière phase dont le début ≤ t.
        var lo = 0, hi = schedule.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if TimeInterval(schedule[mid].start) <= programTime { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func position(at now: TimeInterval) -> EnginePosition {
        let t = programElapsed(at: now)
        guard let idx = phaseIndex(at: t) else {
            return EnginePosition(phaseIndex: nil, phaseElapsed: 0, phaseRemaining: 0, programElapsed: t,
                                  programRemaining: isFreeRun ? 0 : max(0, totalDuration - t),
                                  isFinished: !isFreeRun && t >= totalDuration)
        }
        let sp = schedule[idx]
        return EnginePosition(phaseIndex: idx,
                              phaseElapsed: t - TimeInterval(sp.start),
                              phaseRemaining: TimeInterval(sp.end) - t,
                              programElapsed: t,
                              programRemaining: max(0, totalDuration - t),
                              isFinished: false)
    }

    /// Calcule les transitions depuis le dernier appel. Chaque transition n'est émise qu'une fois.
    public func update(at now: TimeInterval) -> [EngineEvent] {
        guard !isFreeRun, state != .ready, state != .finished else { return [] }
        let t = programElapsed(at: now)
        var events: [EngineEvent] = []
        let newIndex = phaseIndex(at: t)
        if let n = newIndex, n != currentIndex {
            let from = (currentIndex ?? -1) + 1
            let skipped = from < n ? Array(from..<n) : []
            currentIndex = n
            events.append(.phaseStarted(index: n, skipped: skipped))
        }
        if newIndex == nil && t >= totalDuration {
            if case let .running(since) = state {
                // Le temps actif s'arrête à la fin exacte du programme.
                let overshoot = (accumulatedActive + max(0, now - since) + skipOffset) - totalDuration
                accumulatedActive += max(0, now - since) - max(0, overshoot)
            }
            state = .finished
            currentIndex = nil
            events.append(.finished)
        }
        return events
    }

    public var currentPhase: ScheduledPhase? { currentIndex.map { schedule[$0] } }
    public var nextPhase: ScheduledPhase? {
        guard let i = currentIndex, i + 1 < schedule.count else { return nil }
        return schedule[i + 1]
    }

    /// Instantané pour la reprise après crash.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var accumulatedActive: TimeInterval
        public var skipOffset: TimeInterval
        public var currentIndex: Int?
        public var finished: Bool
    }

    public func snapshot(at now: TimeInterval) -> Snapshot {
        Snapshot(accumulatedActive: activeElapsed(at: now), skipOffset: skipOffset,
                 currentIndex: currentIndex, finished: state == .finished)
    }

    /// Restaure en état « en pause » : jamais de reprise automatique.
    public func restore(_ s: Snapshot) {
        accumulatedActive = s.accumulatedActive
        skipOffset = s.skipOffset
        currentIndex = s.currentIndex
        state = s.finished ? .finished : .paused
    }
}
