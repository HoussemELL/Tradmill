import Foundation
import HealthKit
import Observation
import TreadCore

/// Apple Santé côté iPhone : autorisations minimales et enregistrement idempotent
/// d'une séance quand l'iPhone est propriétaire de l'enregistrement (voir `HealthSyncPlan`).
@Observable
final class HealthService {
    private(set) var isAvailable = HKHealthStore.isHealthDataAvailable()
    private(set) var authorizationRequested = false
    private(set) var lastError: String?

    @ObservationIgnored let store = HKHealthStore()
    @ObservationIgnored private let log: DiagnosticLog

    init(log: DiagnosticLog) {
        self.log = log
    }

    private var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(),
         HKQuantityType(.heartRate),
         HKQuantityType(.distanceWalkingRunning),
         HKQuantityType(.activeEnergyBurned)]
    }

    private var readTypes: Set<HKObjectType> {
        // Lecture des exercices : nécessaire pour vérifier qu'une séance n'est pas déjà enregistrée.
        [HKObjectType.workoutType()]
    }

    var sharingStatusLabel: String {
        guard isAvailable else { return "Santé indisponible sur cet appareil" }
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return "Écriture des exercices autorisée"
        case .sharingDenied: return "Écriture refusée (Réglages > Santé > Accès aux données)"
        default: return "Autorisation non demandée"
        }
    }

    @MainActor
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            authorizationRequested = true
            log.log(.health, "Autorisations Santé demandées")
            return true
        } catch {
            lastError = error.localizedDescription
            log.log(.error, "Autorisation Santé : \(error.localizedDescription)")
            return false
        }
    }

    /// Enregistre la séance si le plan l'autorise. Renvoie le nouveau statut.
    @MainActor
    func save(_ record: SessionRecord, plan: HealthSyncPlan) async -> HealthSaveStatus {
        switch plan.owner {
        case .watch: return .ownedByWatch
        case .none: return record.healthStatus
        case .phone: break
        }
        guard isAvailable else { return .failed("Santé indisponible") }
        if store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingDenied { return .denied }

        // Idempotence : un exercice portant déjà cet identifiant n'est jamais réécrit.
        if let existing = await existingWorkout(for: record.id) {
            log.log(.health, "Séance déjà présente dans Santé (\(existing.uuidString))")
            return .saved(workoutUUID: existing.uuidString)
        }

        let config = HKWorkoutConfiguration()
        config.activityType = (record.maxSpeed ?? 0) >= 8 ? .running : .walking
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        let start = record.startDate
        let end = record.endDate ?? start.addingTimeInterval(max(record.activeSeconds + record.pausedSeconds, 60))

        do {
            try await builder.beginCollection(at: start)
            var samples: [HKSample] = []
            if plan.writeHeartRate {
                samples += heartRateSamples(record, start: start)
            }
            if plan.writeDistance {
                samples.append(HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                                                quantity: HKQuantity(unit: .meter(), doubleValue: record.distanceMeters),
                                                start: start, end: end))
            }
            if plan.writeEnergy, let kcal = record.calories.treadmillKcal {
                samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                                                start: start, end: end))
            }
            if !samples.isEmpty {
                try await add(samples, to: builder)
            }
            try await addMetadata([HKMetadataKeyExternalUUID: record.id.uuidString,
                                   HKMetadataKeyIndoorWorkout: true], to: builder)
            try await builder.endCollection(at: end)
            let workout = try await builder.finishWorkout()
            let uuid = workout?.uuid.uuidString ?? "?"
            log.log(.health, "Séance enregistrée dans Santé (\(uuid))")
            return .saved(workoutUUID: uuid)
        } catch {
            builder.discardWorkout()
            log.log(.error, "Enregistrement Santé : \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private func heartRateSamples(_ r: SessionRecord, start: Date) -> [HKSample] {
        let unit = HKUnit.count().unitDivided(by: .minute())
        var out: [HKSample] = []
        var lastT = -Double.infinity
        for s in r.samples {
            guard let hr = s.hr, s.hrSource == .bleSensor || s.hrSource == .treadmill, s.t - lastT >= 5 else { continue }
            lastT = s.t
            let d = start.addingTimeInterval(s.t)
            out.append(HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: unit, doubleValue: Double(hr)),
                                        start: d, end: d))
        }
        return out
    }

    private func add(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            builder.add(samples) { ok, error in
                if let error { c.resume(throwing: error) } else if !ok { c.resume(throwing: HealthError.rejected) } else { c.resume() }
            }
        }
    }

    private func addMetadata(_ metadata: [String: Any], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            builder.addMetadata(metadata) { ok, error in
                if let error { c.resume(throwing: error) } else if !ok { c.resume(throwing: HealthError.rejected) } else { c.resume() }
            }
        }
    }

    private func existingWorkout(for id: UUID) async -> UUID? {
        await withCheckedContinuation { (c: CheckedContinuation<UUID?, Never>) in
            let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                                        allowedValues: [id.uuidString])
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 1,
                                  sortDescriptors: nil) { _, samples, _ in
                c.resume(returning: samples?.first?.uuid)
            }
            store.execute(q)
        }
    }

    enum HealthError: LocalizedError {
        case rejected
        var errorDescription: String? { "Santé a refusé les données" }
    }
}
