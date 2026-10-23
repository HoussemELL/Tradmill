import Foundation

/// Réglages Apple Santé choisis par l'utilisateur.
public struct HealthSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

/// Valeur de métadonnée Santé (sans dépendre de HealthKit).
public enum MetadataValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)

    public var description: String {
        switch self {
        case let .string(s): return s
        case let .number(d): return String(format: "%g", d)
        case let .integer(i): return String(i)
        case let .bool(b): return b ? "true" : "false"
        }
    }
}

/// Clés de métadonnées propres à Foulée (texte simple, lisibles par Rythme).
public enum FouleeMetadataKey {
    public static let sessionID = "FouleeSessionID"
    public static let program = "FouleeProgram"
    public static let averageSpeed = "FouleeAverageSpeedKmh"
    public static let maxSpeed = "FouleeMaxSpeedKmh"
    public static let averageIncline = "FouleeAverageInclinePercent"
    public static let elevationGain = "FouleeElevationGainM"
    public static let energySource = "FouleeEnergySource"
    // Événements « segment » (phases d'un programme)
    public static let phaseName = "FouleePhaseName"
    public static let phaseIndex = "FouleePhaseIndex"
    public static let phaseTargetSpeed = "FouleeTargetSpeedKmh"
    public static let phaseTargetIncline = "FouleeTargetInclinePercent"
}

/// Métadonnées standard HealthKit, converties par l'app (HKMetadataKey…).
public struct StandardWorkoutMetadata: Codable, Equatable, Sendable {
    /// HKMetadataKeySyncIdentifier et HKMetadataKeyExternalUUID.
    public var syncIdentifier: String
    /// HKMetadataKeySyncVersion.
    public var syncVersion: Int
    /// HKMetadataKeyIndoorWorkout (toujours vrai : tapis).
    public var indoor: Bool
}

/// Ce que Foulée écrit (ou fait écrire par la Watch) dans Santé pour une séance.
///
/// Règles :
/// - un seul propriétaire : la Watch si un exercice Watch a tourné, sinon l'iPhone ;
/// - Watch propriétaire : l'iPhone n'écrit rien, il transmet seulement les métadonnées Foulée
///   au HKWorkoutBuilder de la Watch ;
/// - iPhone propriétaire : une séance HKWorkout (bande réelle, pauses, phases en segments)
///   et des échantillons par tranches d'au plus 1 minute, associés à la séance ;
/// - moins d'1 minute (hors pauses) ou séance simulée : rien n'est écrit ;
/// - rien de deviné : une donnée absente n'est jamais remplacée par 0.
public struct HealthWritePlan: Equatable, Sendable {
    public enum Owner: String, Codable, Equatable, Sendable { case none, phone, watch }

    public enum QuantityKind: String, Codable, CaseIterable, Sendable {
        case distanceWalkingRunning, stepCount, activeEnergyBurned, heartRate

        public var unitLabel: String {
            switch self {
            case .distanceWalkingRunning: return "m"
            case .stepCount: return "pas"
            case .activeEnergyBurned: return "kcal"
            case .heartRate: return "bpm"
            }
        }
    }

    public struct Interval: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var index: Int
        public var name: String
        public var start: Date
        public var end: Date
        public var targetSpeedKmh: Double
        public var targetInclinePercent: Double
    }

    public struct Quantity: Codable, Equatable, Sendable {
        public var kind: QuantityKind
        public var value: Double
        public var start: Date
        public var end: Date
        /// Associé à la séance (builder.add). Faux pour la FC des 2 minutes après l'arrêt,
        /// enregistrée à part (hors intervalle de la séance) mais marquée FouleeSessionID.
        public var associated: Bool
    }

    public var owner: Owner
    public var reason: String
    /// Watch propriétaire mais séance < 1 min : demander à la Watch de ne rien enregistrer.
    public var discardWatchWorkout = false
    public var activityType: HealthActivityType
    public var start: Date
    public var end: Date
    public var pauses: [Interval] = []
    public var segments: [Segment] = []
    public var quantities: [Quantity] = []
    public var standard: StandardWorkoutMetadata
    public var fouleeMetadata: [String: MetadataValue] = [:]
    /// Métadonnées posées sur chaque échantillon (permet de les retrouver et de les supprimer).
    public var sampleMetadata: [String: MetadataValue] = [:]
    public var energySource: String?
    /// Données non écrites et pourquoi (affiché à l'utilisateur).
    public var notWritten: [String] = []

    public var activeDuration: TimeInterval {
        end.timeIntervalSince(start) - pauses.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    public static let minimumActiveSeconds: TimeInterval = 60
    public static let runningThresholdKmh = 6.5
    public static let heartRateSpacing: TimeInterval = 5
    public static let recoveryWindow: TimeInterval = 120
    public static let chunk: TimeInterval = 60

    public struct Inputs: Equatable, Sendable {
        public var healthEnabled: Bool
        public var watchWorkoutUsed: Bool
        /// Poids le plus récent de Santé (kg), pour l'estimation ACSM.
        public var bodyMassKg: Double?

        public init(healthEnabled: Bool, watchWorkoutUsed: Bool, bodyMassKg: Double?) {
            self.healthEnabled = healthEnabled
            self.watchWorkoutUsed = watchWorkoutUsed
            self.bodyMassKg = bodyMassKg
        }
    }

    // MARK: - Construction

    public static func make(record r: SessionRecord, inputs: Inputs) -> HealthWritePlan {
        let (start, end) = window(r)
        let pauses = pauseIntervals(r, start: start, end: end)
        var plan = HealthWritePlan(owner: .none, reason: "", activityType: activityType(r), start: start, end: end,
                                   pauses: pauses,
                                   standard: StandardWorkoutMetadata(syncIdentifier: r.id.uuidString,
                                                                     syncVersion: max(r.revision ?? 1, 1), indoor: true))
        plan.fouleeMetadata = fouleeMetadata(r)
        plan.sampleMetadata = [FouleeMetadataKey.sessionID: .string(r.id.uuidString)]
        let tooShort = plan.activeDuration < minimumActiveSeconds

        if r.simulated {
            plan.reason = "séance simulée : rien n'est écrit dans Santé"
            return plan
        }
        if inputs.watchWorkoutUsed || r.healthStatus == .ownedByWatch {
            plan.owner = .watch
            plan.discardWatchWorkout = tooShort
            plan.reason = tooShort
                ? "exercice Watch de moins d'1 minute : la Watch ne l'enregistre pas"
                : "l'Apple Watch enregistre la séance ; Foulée ajoute ses métadonnées, l'iPhone n'écrit rien"
            return plan
        }
        if tooShort {
            plan.reason = "moins d'1 minute d'activité (hors pauses)"
            return plan
        }
        guard inputs.healthEnabled else {
            plan.reason = "Apple Santé désactivé dans Foulée"
            return plan
        }
        plan.owner = .phone
        plan.reason = "aucun exercice Apple Watch : l'iPhone enregistre la séance"
        plan.segments = segments(r, start: start, end: end)
        plan.quantities = quantities(r, start: start, end: end, bodyMass: inputs.bodyMassKg,
                                     energySource: &plan.energySource, notWritten: &plan.notWritten)
        if let e = plan.energySource { plan.fouleeMetadata[FouleeMetadataKey.energySource] = .string(e) }
        return plan
    }

    /// Métadonnées à poser sur la séance de la Watch quand elle est propriétaire.
    public static func watchMetadata(record r: SessionRecord) -> (StandardWorkoutMetadata, [String: MetadataValue]) {
        (StandardWorkoutMetadata(syncIdentifier: r.id.uuidString, syncVersion: max(r.revision ?? 1, 1), indoor: true),
         fouleeMetadata(r))
    }

    // MARK: - Règles

    static func window(_ r: SessionRecord) -> (Date, Date) {
        let firstActive = r.samples.first { !$0.paused }.map { r.date(at: $0.t) }
        let start = r.beltStartDate ?? firstActive ?? r.startDate
        var end = r.beltStopDate ?? r.endDate ?? r.samples.last.map { r.date(at: $0.t) } ?? start
        if end < start { end = start }
        return (start, end)
    }

    static func pauseIntervals(_ r: SessionRecord, start: Date, end: Date) -> [Interval] {
        var out: [Interval] = []
        var open: Date?
        for e in r.events {
            switch e.kind {
            case .pause:
                if open == nil { open = r.date(at: e.t) }
            case .resume:
                if let o = open {
                    out.append(Interval(start: o, end: r.date(at: e.t)))
                    open = nil
                }
            default:
                break
            }
        }
        if let o = open { out.append(Interval(start: o, end: end)) }
        return out.compactMap { iv in
            let s = max(iv.start, start), e = min(iv.end, end)
            return e > s ? Interval(start: s, end: e) : nil
        }
    }

    public static func isIntervalProgram(_ p: WorkoutProgram?) -> Bool {
        guard let p else { return false }
        let name = p.name.lowercased()
        if name.contains("hiit") || name.contains("interval") || name.contains("fractionn") { return true }
        return p.items.contains { item in
            guard case let .block(b) = item, b.repeatCount >= 2 else { return false }
            return b.phases.contains { $0.kind == .work } && b.phases.contains { $0.kind == .recovery }
        }
    }

    public static func activityType(_ r: SessionRecord) -> HealthActivityType {
        if let o = r.activityTypeOverride { return o }
        if isIntervalProgram(r.program) { return .hiit }
        var fast = 0.0, total = 0.0
        for (i, s) in r.samples.enumerated() where !s.paused {
            guard let v = s.speed, v > 0.1 else { continue }
            let dt = i + 1 < r.samples.count ? max(0, min(r.samples[i + 1].t - s.t, 5)) : 1
            total += dt
            if v >= runningThresholdKmh { fast += dt }
        }
        return total > 0 && fast / total > 0.5 ? .running : .walking
    }

    static func fouleeMetadata(_ r: SessionRecord) -> [String: MetadataValue] {
        var m: [String: MetadataValue] = [
            FouleeMetadataKey.sessionID: .string(r.id.uuidString),
            FouleeMetadataKey.program: .string(r.programName ?? "Séance libre"),
        ]
        func round(_ v: Double, _ digits: Double) -> Double { (v * digits).rounded() / digits }
        if let v = r.avgSpeed { m[FouleeMetadataKey.averageSpeed] = .number(round(v, 100)) }
        if let v = r.maxSpeed { m[FouleeMetadataKey.maxSpeed] = .number(round(v, 100)) }
        if let v = r.avgIncline { m[FouleeMetadataKey.averageIncline] = .number(round(v, 10)) }
        if let v = r.elevationGainMeters { m[FouleeMetadataKey.elevationGain] = .number(round(v, 10)) }
        return m
    }

    static func segments(_ r: SessionRecord, start: Date, end: Date) -> [Segment] {
        guard let spans = r.phaseSpans else { return [] }
        return spans.compactMap { sp in
            let s = max(r.date(at: sp.start), start)
            let e = min(sp.end.map { r.date(at: $0) } ?? end, end)
            guard e > s else { return nil }
            return Segment(index: sp.index, name: sp.name, start: s, end: e,
                           targetSpeedKmh: sp.targetSpeedKmh, targetInclinePercent: sp.targetInclinePercent)
        }
    }

    /// Valeur d'une série cumulative à une date (dernier échantillon connu ≤ date).
    static func cumulative(_ points: [(Date, Double)], at d: Date) -> Double? {
        var last: Double?
        for (date, v) in points {
            if date > d { break }
            last = v
        }
        return last
    }

    static func deltas(_ points: [(Date, Double)], kind: QuantityKind, start: Date, end: Date) -> [Quantity] {
        guard !points.isEmpty else { return [] }
        var out: [Quantity] = []
        var a = start
        while a < end {
            let b = min(a.addingTimeInterval(chunk), end)
            // Avant le premier échantillon, la série vaut sa première valeur connue (pas 0 inventé).
            let va = cumulative(points, at: a) ?? points[0].1
            let vb = cumulative(points, at: b) ?? va
            let delta = vb - va
            if delta > 0.0001 {
                out.append(Quantity(kind: kind, value: delta, start: a, end: b, associated: true))
            }
            a = b
        }
        return out
    }

    static func quantities(_ r: SessionRecord, start: Date, end: Date, bodyMass: Double?,
                           energySource: inout String?, notWritten: inout [String]) -> [Quantity] {
        var out: [Quantity] = []
        let dated = r.samples.map { (r.date(at: $0.t), $0) }

        // Distance mesurée par le tapis.
        if r.distanceSource == .treadmill {
            out += deltas(dated.map { ($0.0, $0.1.distance) }, kind: .distanceWalkingRunning, start: start, end: end)
        } else {
            notWritten.append("Distance : non mesurée par le tapis (aucune distance écrite)")
        }

        // Pas comptés par le tapis uniquement.
        if r.stepsSource == .treadmill {
            out += deltas(dated.compactMap { d, s in s.steps.map { (d, Double($0)) } }, kind: .stepCount, start: start, end: end)
        } else {
            notWritten.append("Pas : le tapis n'en fournit pas (aucun pas écrit)")
        }

        // Énergie active : ACSM avec le poids de Santé, sinon celle du tapis, jamais les deux.
        if let mass = bodyMass, mass > 0 {
            var buckets: [Quantity] = []
            var a = start
            while a < end {
                let b = min(a.addingTimeInterval(chunk), end)
                var kcal = 0.0
                for (i, (d, s)) in dated.enumerated() where !s.paused {
                    guard let v = s.speed, v > 0.1 else { continue }
                    let next = i + 1 < dated.count ? dated[i + 1].0 : d.addingTimeInterval(1)
                    let segStart = max(d, a), segEnd = min(min(next, d.addingTimeInterval(5)), b)
                    let dt = segEnd.timeIntervalSince(segStart)
                    if dt > 0 {
                        kcal += EnergyEstimator.activeKcalPerMinute(speedKmh: v, gradePercent: s.incline ?? 0, weightKg: mass) * dt / 60
                    }
                }
                if kcal > 0.0001 { buckets.append(Quantity(kind: .activeEnergyBurned, value: kcal, start: a, end: b, associated: true)) }
                a = b
            }
            if !buckets.isEmpty { energySource = "acsm" }
            out += buckets
        } else {
            let points = dated.compactMap { d, s in s.energy.map { (d, $0) } }
            let buckets = deltas(points, kind: .activeEnergyBurned, start: start, end: end)
            if buckets.isEmpty {
                notWritten.append("Énergie : ni poids dans Santé ni énergie fournie par le tapis")
            } else {
                energySource = "tapis"
                notWritten.append("Énergie : poids absent de Santé, énergie du tapis utilisée")
            }
            out += buckets
        }

        // FC de la ceinture/brassard (ou du tapis) : ~1 mesure / 5 s, heure réelle, + 2 min après l'arrêt.
        let readings = (r.heartRateReadings ?? []).filter { $0.source == .bleSensor || $0.source == .treadmill }
        if readings.isEmpty {
            notWritten.append("FC : aucune ceinture ou brassard pendant la séance")
        } else {
            let limit = end.addingTimeInterval(recoveryWindow)
            var lastKept: Date?
            for p in readings.sorted(by: { $0.t < $1.t }) {
                let d = r.date(at: p.t)
                guard d >= start, d <= limit else { continue }
                if let l = lastKept, d.timeIntervalSince(l) < heartRateSpacing - 0.5 { continue }
                lastKept = d
                out.append(Quantity(kind: .heartRate, value: Double(p.bpm), start: d, end: d, associated: d <= end))
            }
        }
        return out
    }
}

/// Séance déjà présente dans Santé, pour la décision anti-doublon.
public struct ExistingHealthWorkout: Equatable, Sendable {
    public var uuid: String
    public var sourceName: String
    /// HKMetadataKeySyncIdentifier de la séance (nil si absent).
    public var syncIdentifier: String?
    public var syncVersion: Int?
    public var start: Date
    public var end: Date

    public init(uuid: String, sourceName: String, syncIdentifier: String?, syncVersion: Int?, start: Date, end: Date) {
        self.uuid = uuid
        self.sourceName = sourceName
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.start = start
        self.end = end
    }
}

public enum HealthWriteDecision: Equatable, Sendable {
    /// Écrire ; supprimer d'abord ces séances Foulée (ancienne version) et leurs échantillons.
    case write(replacing: [String])
    /// La même séance (même identifiant, version ≥) est déjà dans Santé.
    case alreadySaved(uuid: String)
    /// Une autre séance couvre déjà plus de 50 % du créneau.
    case overlapping(by: String)

    public static let overlapThreshold = 0.5

    public static func decide(plan: HealthWritePlan, existing: [ExistingHealthWorkout]) -> HealthWriteDecision {
        let id = plan.standard.syncIdentifier
        let own = existing.filter { $0.syncIdentifier == id }
        if let same = own.first(where: { ($0.syncVersion ?? 0) >= plan.standard.syncVersion }) {
            return .alreadySaved(uuid: same.uuid)
        }
        let duration = plan.end.timeIntervalSince(plan.start)
        if duration > 0 {
            for w in existing where w.syncIdentifier != id {
                let overlap = min(w.end, plan.end).timeIntervalSince(max(w.start, plan.start))
                if overlap / duration > overlapThreshold { return .overlapping(by: w.sourceName) }
            }
        }
        return .write(replacing: own.map(\.uuid))
    }
}

/// Résumé de ce qui a été écrit, conservé avec la séance et exportable.
public struct HealthWriteReport: Codable, Equatable, Sendable {
    public struct QuantitySummary: Codable, Equatable, Sendable {
        public var kind: HealthWritePlan.QuantityKind
        public var count: Int
        public var total: Double
        public var associatedCount: Int
        public var maxChunkSeconds: Double
    }

    public var owner: HealthWritePlan.Owner
    public var reason: String
    public var outcome: String
    public var writtenAt: Date
    public var workoutUUID: String?
    public var activityType: HealthActivityType
    public var start: Date
    public var end: Date
    public var activeDurationSeconds: Double
    public var pauses: [HealthWritePlan.Interval]
    public var segments: [HealthWritePlan.Segment]
    public var quantities: [QuantitySummary]
    public var standard: StandardWorkoutMetadata
    public var fouleeMetadata: [String: MetadataValue]
    public var notWritten: [String]
    public var replacedWorkouts: [String]

    public init(plan: HealthWritePlan, outcome: String, workoutUUID: String?, replaced: [String] = [], writtenAt: Date = Date()) {
        owner = plan.owner
        reason = plan.reason
        self.outcome = outcome
        self.writtenAt = writtenAt
        self.workoutUUID = workoutUUID
        activityType = plan.activityType
        start = plan.start
        end = plan.end
        activeDurationSeconds = plan.activeDuration
        pauses = plan.pauses
        segments = plan.segments
        quantities = HealthWritePlan.QuantityKind.allCases.compactMap { k in
            let q = plan.quantities.filter { $0.kind == k }
            guard !q.isEmpty else { return nil }
            let total = k == .heartRate ? q.map(\.value).reduce(0, +) / Double(q.count) : q.map(\.value).reduce(0, +)
            return QuantitySummary(kind: k, count: q.count, total: total,
                                   associatedCount: q.filter(\.associated).count,
                                   maxChunkSeconds: q.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0)
        }
        standard = plan.standard
        fouleeMetadata = plan.fouleeMetadata
        notWritten = plan.notWritten
        replacedWorkouts = replaced
    }

    /// Texte lisible (écran et export).
    public var text: String {
        let iso = ISO8601DateFormatter()
        var lines = ["Propriétaire : \(owner.rawValue) — \(reason)", "Résultat : \(outcome)"]
        if let u = workoutUUID { lines.append("HKWorkout : \(u)") }
        lines.append("Type : \(activityType.label) · intérieur")
        lines.append("Début (bande) : \(iso.string(from: start)) · fin : \(iso.string(from: end))")
        lines.append(String(format: "Durée hors pauses : %.0f s · pauses : %d", activeDurationSeconds, pauses.count))
        lines.append("SyncIdentifier = ExternalUUID = \(standard.syncIdentifier) · SyncVersion = \(standard.syncVersion)")
        for (k, v) in fouleeMetadata.sorted(by: { $0.key < $1.key }) { lines.append("\(k) = \(v)") }
        for s in segments {
            lines.append(String(format: "Segment %d « %@ » %.0f s · %.1f km/h · %.0f %%", s.index + 1, s.name,
                                s.end.timeIntervalSince(s.start), s.targetSpeedKmh, s.targetInclinePercent))
        }
        for q in quantities {
            let total = q.kind == .heartRate ? String(format: "moyenne %.0f", q.total) : String(format: "total %.1f", q.total)
            lines.append("\(q.kind.rawValue) : \(q.count) échantillons (\(q.associatedCount) associés), \(total) \(q.kind.unitLabel), tranche max \(Int(q.maxChunkSeconds)) s")
        }
        for n in notWritten { lines.append("Non écrit — \(n)") }
        if !replacedWorkouts.isEmpty { lines.append("Remplace : " + replacedWorkouts.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
