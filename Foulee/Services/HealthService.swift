import Foundation
import HealthKit
import Observation
import TreadCore

/// Apple Santé côté iPhone.
///
/// - Écrit une séance seulement quand l'iPhone en est le propriétaire (`HealthWritePlan`).
/// - Idempotent : HKMetadataKeySyncIdentifier = HKMetadataKeyExternalUUID = UUID Foulée,
///   HKMetadataKeySyncVersion = révision ; une version déjà présente n'est jamais réécrite,
///   une correction remplace l'ancienne (séance + échantillons supprimés puis réécrits).
/// - N'écrit pas si une autre séance couvre déjà plus de 50 % du créneau.
/// - Lit le poids (ACSM), la date de naissance, la FC et la FC de repos (zones).
@Observable
final class HealthService {
    private(set) var isAvailable = HKHealthStore.isHealthDataAvailable()
    private(set) var authorizationRequested = false
    private(set) var lastError: String?

    @ObservationIgnored let store = HKHealthStore()
    @ObservationIgnored private let log: DiagnosticLog
    @ObservationIgnored private var bpm: HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    init(log: DiagnosticLog) {
        self.log = log
    }

    // MARK: - Autorisations

    /// Types écrits, avec ce qui manquera si l'écriture est refusée.
    static let writeTypes: [(HKSampleType, String)] = [
        (HKObjectType.workoutType(), "les séances"),
        (HKQuantityType(.distanceWalkingRunning), "la distance"),
        (HKQuantityType(.stepCount), "les pas du tapis"),
        (HKQuantityType(.activeEnergyBurned), "l'énergie active"),
        (HKQuantityType(.heartRate), "la fréquence cardiaque de la ceinture"),
    ]

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(),
         HKQuantityType(.bodyMass),
         HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
         HKQuantityType(.heartRate),
         HKQuantityType(.restingHeartRate)]
    }

    /// Ce qui ne sera pas enregistré (types dont l'écriture est refusée). La lecture refusée
    /// n'est pas détectable (HealthKit la masque) : les valeurs lues sont alors simplement absentes.
    var missingWritePermissions: [String] {
        guard isAvailable else { return ["Santé indisponible sur cet appareil"] }
        return Self.writeTypes.filter { store.authorizationStatus(for: $0.0) == .sharingDenied }.map(\.1)
    }

    /// État de l'autorisation d'écriture de chaque type, tel que HealthKit le donne (fiable pour
    /// l'écriture, contrairement à la lecture).
    var writeStatuses: [(label: String, status: String)] {
        guard isAvailable else { return [] }
        return Self.writeTypes.map { type, label in
            let status: String
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized: status = "autorisée"
            case .sharingDenied: status = "refusée"
            default: status = "jamais demandée"
            }
            return (label.prefix(1).uppercased() + label.dropFirst(), status)
        }
    }

    var sharingStatusLabel: String {
        guard isAvailable else { return "Santé indisponible sur cet appareil" }
        let keys = Self.missingUsageKeys
        if !keys.isEmpty { return "App mal configurée (\(keys.joined(separator: ", ")) absent de l'Info.plist) : rien ne sera enregistré" }
        let missing = missingWritePermissions
        if store.authorizationStatus(for: HKObjectType.workoutType()) == .notDetermined { return "Autorisations non demandées" }
        if missing.isEmpty { return "Écriture autorisée pour tous les types" }
        return "Ne seront pas enregistrés : " + missing.joined(separator: ", ")
    }

    /// Clés exigées par HealthKit : sans elles, `requestAuthorization` lève une exception
    /// Objective-C (plantage), qu'on ne peut pas intercepter en Swift.
    static let requiredUsageKeys = ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"]

    static var missingUsageKeys: [String] {
        requiredUsageKeys.filter { (Bundle.main.object(forInfoDictionaryKey: $0) as? String)?.isEmpty ?? true }
    }

    @MainActor
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let missing = Self.missingUsageKeys
        guard missing.isEmpty else {
            lastError = "App mal configurée : \(missing.joined(separator: ", ")) absent de l'Info.plist. Santé est désactivé."
            log.log(.error, "Autorisation Santé non demandée : \(missing.joined(separator: ", ")) absent de l'Info.plist")
            return false
        }
        do {
            try await store.requestAuthorization(toShare: Set(Self.writeTypes.map(\.0)), read: readTypes)
            authorizationRequested = true
            log.log(.health, "Autorisations Santé demandées")
            return true
        } catch {
            lastError = error.localizedDescription
            log.log(.error, "Autorisation Santé : \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Lectures

    /// Poids le plus récent (kg).
    func latestBodyMass() async -> Double? {
        let samples = await query(HKQuantityType(.bodyMass), predicate: nil, limit: 1, newestFirst: true)
        return (samples.first as? HKQuantitySample)?.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }

    struct ZoneInputs {
        var birthDate: Date?
        var highHR: [ZoneProfileResolver.HRPoint]
        var restingHR: [Double]
    }

    func zoneInputs(now: Date = Date()) async -> ZoneInputs {
        var birth: Date?
        if let comps = try? store.dateOfBirthComponents() {
            birth = Calendar(identifier: .gregorian).date(from: comps)
        }
        let yearAgo = now.addingTimeInterval(-365 * 86_400)
        let high = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: yearAgo, end: now, options: []),
            HKQuery.predicateForQuantitySamples(with: .greaterThanOrEqualTo,
                                                quantity: HKQuantity(unit: bpm, doubleValue: ZoneProfileResolver.highHRQueryThreshold)),
        ])
        let highSamples = await query(HKQuantityType(.heartRate), predicate: high, limit: HKObjectQueryNoLimit, newestFirst: false)
        let points = highSamples.compactMap { $0 as? HKQuantitySample }.map {
            ZoneProfileResolver.HRPoint(date: $0.startDate, bpm: $0.quantity.doubleValue(for: bpm))
        }
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        let resting = await query(HKQuantityType(.restingHeartRate),
                                  predicate: HKQuery.predicateForSamples(withStart: monthAgo, end: now, options: []),
                                  limit: HKObjectQueryNoLimit, newestFirst: false)
        let restValues = resting.compactMap { $0 as? HKQuantitySample }.map { $0.quantity.doubleValue(for: bpm) }
        log.log(.health, "Zones : \(points.count) mesures ≥ \(Int(ZoneProfileResolver.highHRQueryThreshold)) bpm sur 12 mois, \(restValues.count) FC de repos sur 30 j, date de naissance \(birth == nil ? "absente" : "lue")")
        return ZoneInputs(birthDate: birth, highHR: points, restingHR: restValues)
    }

    // MARK: - Écriture

    struct WriteResult {
        var status: HealthSaveStatus
        var report: HealthWriteReport?
    }

    /// Écrit la séance si le plan désigne l'iPhone comme propriétaire.
    @MainActor
    func write(_ record: SessionRecord, plan: HealthWritePlan) async -> WriteResult {
        switch plan.owner {
        case .watch:
            return WriteResult(status: .ownedByWatch, report: HealthWriteReport(plan: plan, outcome: "écrit par l'Apple Watch", workoutUUID: nil))
        case .none:
            return WriteResult(status: .notWritten(plan.reason), report: HealthWriteReport(plan: plan, outcome: "rien écrit", workoutUUID: nil))
        case .phone:
            break
        }
        guard isAvailable else { return WriteResult(status: .failed("Santé indisponible"), report: nil) }
        guard await ensureWorkoutSharing() else {
            return WriteResult(status: .denied, report: HealthWriteReport(plan: plan, outcome: "écriture des séances refusée", workoutUUID: nil))
        }
        var plan = plan
        _ = keepAuthorizedQuantities(&plan)

        let existing = await existingWorkouts(syncIdentifier: plan.standard.syncIdentifier, start: plan.start, end: plan.end)
        let decision = HealthWriteDecision.decide(plan: plan, existing: existing)
        switch decision {
        case let .alreadySaved(uuid):
            log.log(.health, "Séance déjà dans Santé (version ≥ \(plan.standard.syncVersion)) : rien réécrit")
            return WriteResult(status: .saved(workoutUUID: uuid),
                               report: HealthWriteReport(plan: plan, outcome: "déjà présente avec cette version : rien réécrit", workoutUUID: uuid))
        case let .overlapping(by):
            log.log(.health, "Séance non écrite : déjà enregistrée par \(by)")
            return WriteResult(status: .alreadyRecorded(by: by),
                               report: HealthWriteReport(plan: plan, outcome: "non écrite : déjà enregistrée par \(by)", workoutUUID: nil))
        case let .write(replacing):
            if !replacing.isEmpty {
                let msg = await deleteSession(id: plan.standard.syncIdentifier)
                log.log(.health, "Correction : ancienne version supprimée (\(msg))")
            }
            do {
                let uuid = try await build(plan)
                log.log(.health, "Séance écrite dans Santé (\(uuid), version \(plan.standard.syncVersion))")
                let missing = missingWritePermissions
                var report = HealthWriteReport(plan: plan, outcome: missing.isEmpty ? "écrite" : "écrite ; refusé par Santé : " + missing.joined(separator: ", "),
                                               workoutUUID: uuid, replaced: replacing)
                report.notWritten += missing.map { "Autorisation refusée : \($0)" }
                return WriteResult(status: .saved(workoutUUID: uuid), report: report)
            } catch {
                log.log(.error, "Écriture Santé : \(error.localizedDescription)")
                return WriteResult(status: .failed(error.localizedDescription),
                                   report: HealthWriteReport(plan: plan, outcome: "échec : \(error.localizedDescription)", workoutUUID: nil))
            }
        }
    }

    private func hkMetadata(_ m: [String: MetadataValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in m {
            switch v {
            case let .string(s): out[k] = s
            case let .number(d): out[k] = NSNumber(value: d)
            case let .integer(i): out[k] = NSNumber(value: i)
            case let .bool(b): out[k] = NSNumber(value: b)
            }
        }
        return out
    }

    private func standardMetadata(_ s: StandardWorkoutMetadata) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: s.syncIdentifier,
         HKMetadataKeySyncVersion: NSNumber(value: s.syncVersion),
         HKMetadataKeyExternalUUID: s.syncIdentifier,
         HKMetadataKeyIndoorWorkout: NSNumber(value: s.indoor)]
    }

    private func quantityType(_ k: HealthWritePlan.QuantityKind) -> HKQuantityType {
        switch k {
        case .distanceWalkingRunning: return HKQuantityType(.distanceWalkingRunning)
        case .stepCount: return HKQuantityType(.stepCount)
        case .activeEnergyBurned: return HKQuantityType(.activeEnergyBurned)
        case .heartRate: return HKQuantityType(.heartRate)
        }
    }

    private func unit(_ k: HealthWritePlan.QuantityKind) -> HKUnit {
        switch k {
        case .distanceWalkingRunning: return .meter()
        case .stepCount: return .count()
        case .activeEnergyBurned: return .kilocalorie()
        case .heartRate: return bpm
        }
    }

    @MainActor
    private func build(_ plan: HealthWritePlan) async throws -> String {
        let config = HKWorkoutConfiguration()
        switch plan.activityType {
        case .walking: config.activityType = .walking
        case .running: config.activityType = .running
        case .hiit: config.activityType = .highIntensityIntervalTraining
        }
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        let sampleMeta = hkMetadata(plan.sampleMetadata)
        do {
            try await builder.beginCollection(at: plan.start)

            // Pauses (la durée de la séance les exclut) puis phases du programme.
            var events: [HKWorkoutEvent] = []
            for p in plan.pauses {
                events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: p.start, duration: 0), metadata: nil))
                events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: p.end, duration: 0), metadata: nil))
            }
            for s in plan.segments {
                let meta: [String: Any] = [
                    FouleeMetadataKey.phaseName: s.name,
                    FouleeMetadataKey.phaseIndex: NSNumber(value: s.index),
                    FouleeMetadataKey.phaseTargetSpeed: NSNumber(value: s.targetSpeedKmh),
                    FouleeMetadataKey.phaseTargetIncline: NSNumber(value: s.targetInclinePercent),
                ]
                events.append(HKWorkoutEvent(type: .segment, dateInterval: DateInterval(start: s.start, end: s.end), metadata: meta))
            }
            if !events.isEmpty { try await addEvents(events, to: builder) }

            // Échantillons associés à la séance (tranches ≤ 1 min, FC ~5 s).
            let associated: [HKSample] = plan.quantities.filter(\.associated).map {
                HKQuantitySample(type: quantityType($0.kind), quantity: HKQuantity(unit: unit($0.kind), doubleValue: $0.value),
                                 start: $0.start, end: $0.end, metadata: sampleMeta)
            }
            if !associated.isEmpty { try await add(associated, to: builder) }

            var meta = standardMetadata(plan.standard)
            for (k, v) in hkMetadata(plan.fouleeMetadata) { meta[k] = v }
            try await addMetadata(meta, to: builder)
            try await builder.endCollection(at: plan.end)
            guard let workout = try await builder.finishWorkout() else { throw HealthError.rejected }

            // FC des 2 minutes après l'arrêt : hors de l'intervalle de la séance, enregistrée à part,
            // marquée FouleeSessionID pour pouvoir la supprimer avec la séance.
            let recovery: [HKObject] = plan.quantities.filter { !$0.associated }.map {
                HKQuantitySample(type: quantityType($0.kind), quantity: HKQuantity(unit: unit($0.kind), doubleValue: $0.value),
                                 start: $0.start, end: $0.end, metadata: sampleMeta)
            }
            if !recovery.isEmpty { try await save(recovery) }
            return workout.uuid.uuidString
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    // MARK: - Autorisations d'écriture

    /// Demande les autorisations si l'une n'a jamais été posée (sinon une écriture échoue avec
    /// « Not authorized »). Vrai si l'écriture des séances est accordée.
    @MainActor
    private func ensureWorkoutSharing() async -> Bool {
        if Self.writeTypes.contains(where: { store.authorizationStatus(for: $0.0) == .notDetermined }) {
            _ = await requestAuthorization()
        }
        return store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    /// Retire du plan les échantillons dont l'écriture n'est pas accordée (la séance est écrite
    /// sans eux plutôt que pas du tout) ; renvoie ce qui est omis.
    private func keepAuthorizedQuantities(_ plan: inout HealthWritePlan) -> [String] {
        var skipped = Set<String>()
        plan.quantities = plan.quantities.filter { q in
            let type = quantityType(q.kind)
            let status = store.authorizationStatus(for: type)
            guard status == .sharingAuthorized else {
                let label = Self.writeTypes.first { $0.0 == (type as HKSampleType) }?.1 ?? q.kind.rawValue
                skipped.insert(label + (status == .sharingDenied ? " (écriture refusée)" : " (écriture jamais demandée)"))
                return false
            }
            return true
        }
        let list = skipped.sorted()
        plan.notWritten += list.map { "Non autorisé : \($0)" }
        return list
    }

    // MARK: - Récupération d'une séance Watch incomplète

    /// Remplace dans Santé une séance Watch partielle (exercice coupé) par la séance complète,
    /// écrite par l'iPhone depuis les données Foulée. Ne supprime rien si une séance complète
    /// existe déjà ; n'écrit rien si la séance partielle ne peut pas être supprimée (doublon).
    @MainActor
    /// - Parameter onlyIfPartialExists: vérification automatique de fin de séance : n'écrit que
    ///   si une séance partielle de la montre est déjà dans Santé (sinon la montre n'a peut-être
    ///   pas fini d'enregistrer : on ne crée pas de doublon).
    func recoverFullSession(_ record: SessionRecord, bodyMassKg: Double?,
                            onlyIfPartialExists: Bool = false) async -> (updated: SessionRecord?, message: String) {
        guard isAvailable else { return (nil, "Santé indisponible") }
        var r = record
        r.healthStatus = .notRequested
        var plan = HealthWritePlan.make(record: r, inputs: .init(healthEnabled: true, watchWorkoutUsed: false, bodyMassKg: bodyMassKg))
        guard plan.owner == .phone else { return (nil, "Rien à écrire : \(plan.reason)") }
        // Autorisation vérifiée AVANT de toucher à quoi que ce soit dans Santé.
        guard await ensureWorkoutSharing() else {
            return (nil, "Échec : Foulée n'est pas autorisée à écrire les séances dans Santé (Réglages › Santé › "
                    + "Accès aux données et appareils › Foulée › activer « Entraînements »). Rien n'a été modifié.")
        }
        let skipped = keepAuthorizedQuantities(&plan)
        let existing = await existingWorkouts(syncIdentifier: plan.standard.syncIdentifier, start: plan.start, end: plan.end)
        switch HealthRecoveryDecision.decide(plan: plan, existing: existing) {
        case let .complete(_, minutes):
            return (nil, "Santé contient déjà la séance complète (\(minutes) min) : rien à récupérer")
        case let .blocked(by):
            return (nil, "Non écrite : une séance de \(by) couvre déjà ce créneau")
        case let .replace(partial, version):
            if onlyIfPartialExists && partial.isEmpty {
                return (nil, "Aucune séance de la montre dans Santé pour l'instant : rien n'est écrit automatiquement")
            }
            let partialText = partial.map { "\(Int(($0.end.timeIntervalSince($0.start) / 60).rounded())) min" }.joined(separator: ", ")
            plan.standard.syncVersion = version
            plan.reason = "récupération : séance Watch incomplète dans Santé" + (partial.isEmpty ? "" : " (\(partialText))")
                + ", séance complète écrite par l'iPhone"
            // D'abord écrire la séance complète ; la partie de la montre n'est supprimée qu'ensuite
            // (un échec d'écriture ne fait jamais rien perdre).
            let uuid: String
            do {
                uuid = try await build(plan)
            } catch {
                log.log(.error, "Récupération Santé : \(error.localizedDescription)")
                return (nil, "Échec de l'écriture dans Santé : \(error.localizedDescription). Rien n'a été supprimé.")
            }
            log.log(.health, "Séance complète récupérée dans Santé (\(uuid), version \(version))")
            let refused = await deleteWorkouts(uuids: Set(partial.map(\.uuid)))
            r.healthStatus = .saved(workoutUUID: uuid)
            r.healthSyncVersion = version
            r.revision = max(r.revision ?? 1, version)
            var outcome = "séance complète écrite par l'iPhone"
            if !partial.isEmpty {
                outcome += refused.isEmpty ? ", remplace l'exercice Watch partiel (\(partialText))"
                    : " ; exercice Watch partiel (\(partialText)) à supprimer dans l'app Santé"
            }
            r.healthReport = HealthWriteReport(plan: plan, outcome: outcome, workoutUUID: uuid, replaced: partial.map(\.uuid))
            var message = "Séance complète écrite dans Santé (\(Int((plan.activeDuration / 60).rounded())) min actives)"
            if !refused.isEmpty {
                message += ". Santé ne laisse pas Foulée supprimer la partie enregistrée par la montre (\(partialText)) : "
                    + "supprimez-la dans l'app Santé (Parcourir › Activité › Entraînements) pour éviter un doublon."
            }
            if !skipped.isEmpty {
                message += ". Non écrits : " + skipped.joined(separator: ", ")
                    + " — Foulée › Réglages › Apple Santé › Demander les autorisations"
            }
            return (r, message)
        }
    }

    /// Supprime ces séances (par identifiant) ; renvoie les sources qui ont refusé.
    private func deleteWorkouts(uuids: Set<String>) async -> [String] {
        guard !uuids.isEmpty else { return [] }
        let ids = Set(uuids.compactMap(UUID.init(uuidString:)))
        let workouts = await query(HKObjectType.workoutType(), predicate: HKQuery.predicateForObjects(with: ids),
                                   limit: HKObjectQueryNoLimit, newestFirst: false)
        var refused: [String] = []
        for w in workouts {
            do { try await delete(w) } catch { refused.append(w.sourceRevision.source.name) }
        }
        return refused
    }

    // MARK: - Suppression

    /// Supprime la séance Foulée de Santé : échantillons marqués FouleeSessionID puis séance(s)
    /// portant ce SyncIdentifier. Une séance écrite par la Watch peut être refusée par HealthKit
    /// (seule l'app qui l'a écrite peut la supprimer) : le message le dit.
    @MainActor
    func deleteSession(id: String) async -> String {
        guard isAvailable else { return "Santé indisponible" }
        var deletedSamples = 0
        let byFoulee = HKQuery.predicateForObjects(withMetadataKey: FouleeMetadataKey.sessionID, allowedValues: [id])
        for (type, _) in Self.writeTypes where type != HKObjectType.workoutType() {
            deletedSamples += await deleteObjects(of: type, predicate: byFoulee)
        }
        let workouts = await query(HKObjectType.workoutType(),
                                   predicate: HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [id]),
                                   limit: HKObjectQueryNoLimit, newestFirst: false)
        var deletedWorkouts = 0
        var refused: [String] = []
        for w in workouts {
            do {
                try await delete(w)
                deletedWorkouts += 1
            } catch {
                refused.append(w.sourceRevision.source.name)
            }
        }
        var msg = "\(deletedWorkouts) séance(s) et \(deletedSamples) échantillon(s) supprimés de Santé"
        if !refused.isEmpty {
            msg += " ; à supprimer dans Santé (écrite par \(refused.joined(separator: ", ")))"
        }
        log.log(.health, msg)
        return msg
    }

    // MARK: - Requêtes

    private func existingWorkouts(syncIdentifier: String, start: Date, end: Date) async -> [ExistingHealthWorkout] {
        let overlapping = await query(HKObjectType.workoutType(),
                                      predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                                      limit: HKObjectQueryNoLimit, newestFirst: false)
        let own = await query(HKObjectType.workoutType(),
                              predicate: HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncIdentifier]),
                              limit: HKObjectQueryNoLimit, newestFirst: false)
        var seen = Set<UUID>()
        return (own + overlapping).compactMap { s -> ExistingHealthWorkout? in
            guard let w = s as? HKWorkout, seen.insert(w.uuid).inserted else { return nil }
            return ExistingHealthWorkout(uuid: w.uuid.uuidString,
                                         sourceName: w.sourceRevision.source.name,
                                         syncIdentifier: w.metadata?[HKMetadataKeySyncIdentifier] as? String,
                                         syncVersion: (w.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue,
                                         start: w.startDate, end: w.endDate)
        }
    }

    private func query(_ type: HKSampleType, predicate: NSPredicate?, limit: Int, newestFirst: Bool) async -> [HKSample] {
        await withCheckedContinuation { (c: CheckedContinuation<[HKSample], Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: !newestFirst)
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, _ in
                c.resume(returning: samples ?? [])
            }
            store.execute(q)
        }
    }

    private func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async -> Int {
        await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            store.deleteObjects(of: type, predicate: predicate) { _, count, _ in c.resume(returning: count) }
        }
    }

    private func delete(_ object: HKObject) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            store.delete(object) { ok, error in
                if let error { c.resume(throwing: error) } else if !ok { c.resume(throwing: HealthError.rejected) } else { c.resume() }
            }
        }
    }

    private func save(_ objects: [HKObject]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            store.save(objects) { ok, error in
                if let error { c.resume(throwing: error) } else if !ok { c.resume(throwing: HealthError.rejected) } else { c.resume() }
            }
        }
    }

    private func add(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            builder.add(samples) { ok, error in
                if let error { c.resume(throwing: error) } else if !ok { c.resume(throwing: HealthError.rejected) } else { c.resume() }
            }
        }
    }

    private func addEvents(_ events: [HKWorkoutEvent], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            builder.addWorkoutEvents(events) { ok, error in
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

    enum HealthError: LocalizedError {
        case rejected
        var errorDescription: String? { "Santé a refusé les données" }
    }
}
