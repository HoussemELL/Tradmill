import Foundation
import HealthKit
import WatchConnectivity
import Observation
import TreadCore

/// Session d'exercice watchOS réelle (HKWorkoutSession + HKLiveWorkoutBuilder),
/// envoyée en miroir à l'iPhone (watchOS 10+). La Watch est propriétaire de
/// l'enregistrement Santé quand elle est utilisée.
@Observable
final class WorkoutManager {
    static let shared = WorkoutManager()

    enum Phase: Equatable { case idle, starting, running, paused, ending, ended(saved: Bool), failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var heartRate: Double?
    private(set) var heartRateDate: Date?
    private(set) var steps: Double?
    private(set) var activeEnergy: Double?
    private(set) var startDate: Date?
    private(set) var mirroring = false
    private(set) var linkedTitle: String?

    @ObservationIgnored let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private let proxy = WorkoutProxy()
    @ObservationIgnored private let wcProxy = WatchConnectivityProxy()
    @ObservationIgnored private var discardOnEnd = false
    @ObservationIgnored private var linkedSessionID: UUID?
    /// Métadonnées Foulée reçues avant que le builder existe : appliquées au démarrage.
    @ObservationIgnored private var pendingMetadata: [String: Any] = [:]

    private init() {
        proxy.owner = self
        wcProxy.owner = self
        if WCSession.isSupported() {
            WCSession.default.delegate = wcProxy
            WCSession.default.activate()
        }
    }

    var isActive: Bool {
        switch phase {
        case .starting, .running, .paused, .ending: return true
        default: return false
        }
    }

    func requestAuthorization() async {
        // Sans ces clés, HealthKit lève une exception Objective-C (plantage).
        for key in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"] {
            guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty else { return }
        }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.stepCount),
                                       HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning),
                                       HKObjectType.workoutType()]
        try? await healthStore.requestAuthorization(toShare: share, read: read)
    }

    /// Démarre l'exercice (depuis la Watch ou à la demande de l'iPhone).
    @MainActor
    func start(activity: HKWorkoutActivityType) async {
        guard !isActive else { return }
        phase = .starting
        await requestAuthorization()
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        config.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let b = s.associatedWorkoutBuilder()
            let source = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            source.enableCollection(for: HKQuantityType(.stepCount), predicate: nil)
            b.dataSource = source
            s.delegate = proxy
            b.delegate = proxy
            session = s
            builder = b
            discardOnEnd = false
            heartRate = nil
            steps = nil
            activeEnergy = nil
            let date = Date()
            startDate = date
            s.startActivity(with: date)
            try await b.beginCollection(at: date)
            do {
                try await s.startMirroringToCompanionDevice()
                mirroring = true
            } catch {
                // Repli : WatchConnectivity si l'iPhone est joignable.
                mirroring = false
            }
            send(.workoutState(.running, startDate: date))
            if let id = linkedSessionID { addLinkMetadata(id) }
            if !pendingMetadata.isEmpty {
                try? await b.addMetadata(pendingMetadata)
                pendingMetadata = [:]
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    func end(discard: Bool = false) {
        discardOnEnd = discard
        phase = .ending
        session?.end()
    }

    func reset() {
        phase = .idle
        session = nil
        builder = nil
        startDate = nil
        linkedTitle = nil
        linkedSessionID = nil
    }

    // MARK: - Échanges avec l'iPhone

    func send(_ message: WatchMessage) {
        guard let data = try? message.encoded() else { return }
        if mirroring, let s = session {
            s.sendToRemoteWorkoutSession(data: data) { [weak self] ok, _ in
                if !ok { DispatchQueue.main.async { self?.sendViaConnectivity(data) } }
            }
        } else {
            sendViaConnectivity(data)
        }
    }

    private func sendViaConnectivity(_ data: Data) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([WatchMessage.wcKey: data], replyHandler: nil, errorHandler: nil)
    }

    fileprivate func receive(_ data: Data) {
        guard let msg = try? WatchMessage.decode(data) else { return }
        switch msg {
        case let .linkSession(id, title):
            linkedSessionID = id
            linkedTitle = title
            addLinkMetadata(id)
        case let .workoutMetadata(standard, foulee):
            var meta: [String: Any] = [
                HKMetadataKeySyncIdentifier: standard.syncIdentifier,
                HKMetadataKeySyncVersion: NSNumber(value: standard.syncVersion),
                HKMetadataKeyExternalUUID: standard.syncIdentifier,
                HKMetadataKeyIndoorWorkout: NSNumber(value: standard.indoor),
            ]
            for (k, v) in foulee {
                switch v {
                case let .string(x): meta[k] = x
                case let .number(x): meta[k] = NSNumber(value: x)
                case let .integer(x): meta[k] = NSNumber(value: x)
                case let .bool(x): meta[k] = NSNumber(value: x)
                }
            }
            if let b = builder, isActive {
                b.addMetadata(meta) { _, _ in }
            } else {
                pendingMetadata.merge(meta) { _, new in new }
            }
        case let .command(c):
            switch c {
            case .pause: pause()
            case .resume: resume()
            case .end: end()
            case .discard: end(discard: true)
            }
        default:
            break
        }
    }

    private func addLinkMetadata(_ id: UUID) {
        // Identifiant de la séance iPhone : même clé que la séance Foulée (anti-doublon).
        builder?.addMetadata([HKMetadataKeyExternalUUID: id.uuidString,
                              HKMetadataKeySyncIdentifier: id.uuidString,
                              HKMetadataKeySyncVersion: NSNumber(value: 1),
                              HKMetadataKeyIndoorWorkout: true]) { _, _ in }
    }

    // MARK: - Délégués

    fileprivate func stateChanged(_ state: HKWorkoutSessionState, date: Date) {
        switch state {
        case .running:
            phase = .running
            send(.workoutState(.running, startDate: startDate))
        case .paused:
            phase = .paused
            send(.workoutState(.paused, startDate: startDate))
        case .ended:
            finish(at: date)
        default:
            break
        }
    }

    private func finish(at date: Date) {
        guard let b = builder else { return }
        let discard = discardOnEnd
        b.endCollection(withEnd: date) { [weak self] _, _ in
            if discard {
                b.discardWorkout()
                DispatchQueue.main.async {
                    self?.phase = .ended(saved: false)
                    self?.send(.workoutState(.ended, startDate: self?.startDate))
                }
            } else {
                b.finishWorkout { workout, _ in
                    DispatchQueue.main.async {
                        self?.phase = .ended(saved: workout != nil)
                        self?.send(.workoutState(.ended, startDate: self?.startDate))
                    }
                }
            }
        }
    }

    fileprivate func failed(_ error: Error) {
        phase = .failed(error.localizedDescription)
        send(.workoutState(.failed, startDate: startDate))
    }

    fileprivate func collected(_ types: Set<HKSampleType>) {
        guard let b = builder else { return }
        for type in types {
            guard let qt = type as? HKQuantityType, let stats = b.statistics(for: qt) else { continue }
            let date = stats.mostRecentQuantityDateInterval()?.end ?? Date()
            switch qt {
            case HKQuantityType(.heartRate):
                if let q = stats.mostRecentQuantity() {
                    let bpm = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    heartRate = bpm
                    heartRateDate = date
                    send(.heartRate(bpm: bpm, sampleDate: date))
                }
            case HKQuantityType(.stepCount):
                if let q = stats.sumQuantity() {
                    let v = q.doubleValue(for: .count())
                    steps = v
                    send(.steps(total: v, sampleDate: date))
                }
            case HKQuantityType(.activeEnergyBurned):
                if let q = stats.sumQuantity() {
                    let v = q.doubleValue(for: .kilocalorie())
                    activeEnergy = v
                    send(.activeEnergy(kcal: v, sampleDate: date))
                }
            default:
                break
            }
        }
    }
}

private final class WorkoutProxy: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    weak var owner: WorkoutManager?

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async { self.owner?.stateChanged(toState, date: date) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.owner?.failed(error) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        DispatchQueue.main.async { data.forEach { self.owner?.receive($0) } }
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        DispatchQueue.main.async { self.owner?.collected(collectedTypes) }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

private final class WatchConnectivityProxy: NSObject, WCSessionDelegate {
    weak var owner: WorkoutManager?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchMessage.wcKey] as? Data else { return }
        DispatchQueue.main.async { self.owner?.receive(data) }
    }
}
