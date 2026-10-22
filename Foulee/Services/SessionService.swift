import Foundation
import Observation
import TreadCore

/// Instantané observable de la séance pour l'interface (rafraîchi ≈ 4 Hz).
struct SessionSnapshot: Equatable {
    var status: WorkoutSession.Status = .ready
    var activeTime: TimeInterval = 0
    var programRemaining: TimeInterval?
    var phaseRemaining: TimeInterval?
    var phaseElapsed: TimeInterval?
    var phaseIndex: Int?
    var phaseCount = 0
    var currentPhaseName: String?
    var currentPhaseKind: PhaseKind?
    var currentTargetZone: Int?
    var nextPhaseName: String?
    var nextPhaseSummary: String?
    var targetSpeed: Double = 0
    var targetIncline: Double = 0
    var overrideActive = false
    var zone: Int?
    var steps: Int?
    var stepsSource: MetricSource = .none
    var distanceMeters: Double = 0
    var distanceSource: MetricSource = .none
    var treadmillKcal: Double?
    var watchKcal: Double?
    var estimatedKcal: Double?
    var zoneSeconds: [Double] = Array(repeating: 0, count: 6)
    var message: String?
    var lastAlert: String?
    var isFreeRun = true
}

/// Orchestration d'une séance : relie TreadCore.WorkoutSession aux services de l'app
/// (tapis, cardio, Watch, Santé, persistance, écran).
@Observable
final class SessionService {
    private(set) var snapshot = SessionSnapshot()
    @ObservationIgnored let session: WorkoutSession
    @ObservationIgnored private let checkpointStore: CheckpointStore
    @ObservationIgnored private var lastCheckpoint: TimeInterval = 0
    @ObservationIgnored var onFinished: ((SessionRecord) -> Void)?
    @ObservationIgnored var onAlert: ((String) -> Void)?

    init(session: WorkoutSession, checkpointStore: CheckpointStore) {
        self.session = session
        self.checkpointStore = checkpointStore
        session.onFinished = { [weak self] r in
            self?.checkpointStore.clear()
            self?.refresh()
            self?.onFinished?(r)
        }
        session.onAlert = { [weak self] a in self?.onAlert?(a) }
        refresh()
    }

    var program: WorkoutProgram? { session.program }

    func tick() {
        session.tick()
        let now = MonotonicClock.now()
        if session.status != .ready && session.status != .finished && now - lastCheckpoint > 15 {
            saveCheckpoint()
        }
        refresh()
    }

    func saveCheckpoint() {
        lastCheckpoint = MonotonicClock.now()
        try? checkpointStore.save(session.checkpoint())
    }

    func refresh() {
        let s = session
        let pos = s.position
        var n = SessionSnapshot()
        n.status = s.status
        n.activeTime = s.activeTime
        n.isFreeRun = s.isFreeRun
        if !s.isFreeRun {
            n.programRemaining = pos.programRemaining
            n.phaseRemaining = pos.phaseIndex != nil ? pos.phaseRemaining : nil
            n.phaseElapsed = pos.phaseIndex != nil ? pos.phaseElapsed : nil
            n.phaseIndex = s.engine.currentIndex
            n.phaseCount = s.engine.schedule.count
        }
        if let cp = s.currentPhase {
            n.currentPhaseName = cp.displayName
            n.currentPhaseKind = cp.phase.kind
            n.currentTargetZone = cp.phase.targetZone
        }
        if let np = s.nextPhase {
            n.nextPhaseName = np.displayName
            n.nextPhaseSummary = String(format: "%.1f km/h · %.0f %%", np.phase.speedKmh, np.phase.inclinePercent)
        }
        let t = s.effectiveTargets
        n.targetSpeed = t.speed
        n.targetIncline = t.incline
        n.overrideActive = s.manualOverride != nil
        n.zone = s.currentZone
        n.steps = s.steps.value
        n.stepsSource = s.steps.source
        n.distanceMeters = s.distanceMeters
        n.distanceSource = s.distanceSource
        n.treadmillKcal = s.treadmillKcal
        n.watchKcal = s.record.calories.healthKitActiveKcal
        n.estimatedKcal = s.estimatedKcalValue
        n.zoneSeconds = s.zoneTime.seconds
        n.message = s.message
        n.lastAlert = s.lastAlert
        if n != snapshot { snapshot = n }
    }
}
