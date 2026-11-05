import Foundation

/// Exercice autonome de la montre (sans tapis ni iPhone) lu dans Santé, à ajouter à
/// l'historique Foulée de l'iPhone.
public struct ImportedWatchWorkout: Equatable, Sendable {
    /// Identifiant de la séance Santé : devient celui de la séance Foulée (import idempotent).
    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    /// Durée active (pauses exclues).
    public var activeSeconds: Double
    public var distanceMeters: Double?
    public var steps: Int?
    public var activeKcal: Double?
    /// FC mesurées par la montre (date, bpm).
    public var heartRates: [(date: Date, bpm: Int)]
    /// Distance cumulée mesurée par la montre au fil de l'exercice (date, m depuis le début).
    public var distances: [(date: Date, meters: Double)]

    public init(id: UUID, title: String, start: Date, end: Date, activeSeconds: Double, distanceMeters: Double?,
                steps: Int?, activeKcal: Double?, heartRates: [(date: Date, bpm: Int)], distances: [(date: Date, meters: Double)]) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.activeSeconds = activeSeconds
        self.distanceMeters = distanceMeters
        self.steps = steps
        self.activeKcal = activeKcal
        self.heartRates = heartRates
        self.distances = distances
    }

    public static func == (a: ImportedWatchWorkout, b: ImportedWatchWorkout) -> Bool {
        a.id == b.id && a.title == b.title && a.start == b.start && a.end == b.end && a.activeSeconds == b.activeSeconds
            && a.distanceMeters == b.distanceMeters && a.steps == b.steps && a.activeKcal == b.activeKcal
            && a.heartRates.map(\.bpm) == b.heartRates.map(\.bpm) && a.distances.map(\.meters) == b.distances.map(\.meters)
    }

    /// Nom lisible : « Course extérieure », « Marche en salle »…
    public static func title(running: Bool, walking: Bool, indoor: Bool) -> String {
        let base = running ? "Course" : (walking ? "Marche" : "Exercice")
        return base + (indoor ? " en salle" : " extérieure")
    }

    /// Séance Foulée correspondante : une mesure par FC reçue (distance et vitesse déduites de la
    /// distance de la montre), zones calculées avec `zones`. Rien n'est inventé : sans distance,
    /// pas de vitesse.
    public func record(zones: HeartZoneSettings) -> SessionRecord {
        var r = SessionRecord(id: id, startDate: start, program: nil, treadmillName: nil, profileID: nil, simulated: false)
        r.programName = title
        r.watchStandalone = true
        r.endDate = end
        r.beltStartDate = start
        r.beltStopDate = end
        r.activeSeconds = activeSeconds
        r.pausedSeconds = max(0, end.timeIntervalSince(start) - activeSeconds)
        r.distanceMeters = distanceMeters ?? distances.last?.meters ?? 0
        r.distanceSource = distanceMeters != nil || !distances.isEmpty ? .appleWatch : .none
        r.steps = steps
        r.stepsSource = steps != nil ? .appleWatch : .none
        r.calories.healthKitActiveKcal = activeKcal
        r.healthStatus = .alreadyRecorded(by: "l'Apple Watch (exercice Foulée)")
        r.zoneSettings = zones
        r.revision = 1

        let hr = heartRates.filter { $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
        r.heartRateReadings = hr.map { HeartRatePoint(t: $0.date.timeIntervalSince(start), bpm: $0.bpm, source: .appleWatch) }
        let dist = distances.sorted { $0.date < $1.date }
        func distance(at d: Date) -> Double? {
            guard let first = dist.first, d >= first.date else { return dist.isEmpty ? nil : 0 }
            return dist.last { $0.date <= d }?.meters
        }
        r.samples = hr.map { p in
            let t = p.date.timeIntervalSince(start)
            var speed: Double?
            if let d1 = distance(at: p.date), let d0 = distance(at: p.date.addingTimeInterval(-30)), d1 > d0 {
                speed = (d1 - d0) / 30 * 3.6
            }
            return SessionSample(t: t, active: min(t, activeSeconds), speed: speed, incline: nil, targetSpeed: nil,
                                 targetIncline: nil, hr: p.bpm, hrSource: .appleWatch, zone: zones.zone(for: p.bpm),
                                 distance: distance(at: p.date) ?? 0, steps: nil, phase: nil, paused: false)
        }
        r.recomputeAggregates()
        r.zoneSeconds = SessionAnalysis.zoneSeconds(r, zones: zones)
        return r
    }
}
