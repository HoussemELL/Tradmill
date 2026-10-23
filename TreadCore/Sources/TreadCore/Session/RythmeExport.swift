import Foundation

/// Export structuré d'une séance pour Rythme (format documenté dans docs/RYTHME.md).
///
/// Règle : une **consigne** (vitesse ou inclinaison demandée par le programme, le pilote FC ou
/// l'utilisateur) n'est jamais présentée comme une **mesure** (télémétrie du tapis). Les champs
/// s'appellent `target…` pour les consignes et `measured…` pour les mesures ; une mesure absente
/// (télémétrie périmée, pause, coupure) vaut `null`, jamais 0.
public struct RythmeSessionExport: Codable, Equatable, Sendable {
    public static let format = "foulee.rythme.session"
    public static let formatVersion = 1

    public struct Session: Codable, Equatable, Sendable {
        public var id: UUID
        public var startDate: Date
        public var endDate: Date?
        /// Mouvement réel de la bande (premier mouvement observé, arrêt observé).
        public var beltStartDate: Date?
        public var beltStopDate: Date?
        public var activeSeconds: Double
        public var pausedSeconds: Double
        public var simulated: Bool
        public var interrupted: Bool
        public var treadmillName: String?
        public var treadmillProfile: String?
    }

    public struct Program: Codable, Equatable, Sendable {
        public var id: UUID
        public var templateID: String?
        public var name: String
        public var level: Int?
        public var protocolVersion: Int?
        /// Empreinte du déroulé : deux séances de même empreinte ont suivi le même protocole.
        public var protocolSignature: String?
        public var advanced: Bool
        public var plannedSeconds: Int
    }

    public struct PlannedSegment: Codable, Equatable, Sendable {
        public var index: Int
        public var name: String
        public var kind: String
        public var plannedStartSeconds: Int
        public var durationSeconds: Int
        public var targetSpeedKmh: Double
        /// Phase progressive : vitesse de fin.
        public var targetEndSpeedKmh: Double?
        public var targetInclinePercent: Double
        public var targetZone: Int?
        /// Phase pilotée par la FC : plage automatique [min, max] km/h.
        public var autoSpeedRangeKmh: [Double]?
        public var repetition: String?
    }

    public struct ExecutedSegment: Codable, Equatable, Sendable {
        public var index: Int
        public var name: String
        public var kind: String
        /// Secondes depuis `session.startDate`.
        public var start: Double
        public var end: Double
        public var targetSpeedKmh: Double
        public var targetInclinePercent: Double
        public var autoSpeed: Bool
        public var measuredAvgSpeedKmh: Double?
        public var measuredMaxSpeedKmh: Double?
        public var avgHR: Int?
        public var maxHR: Int?
        /// FC en fin de segment et baisse 60 s après (quand le segment suivant est plus lent ou à l'arrêt).
        public var hrAtEnd: Int?
        public var hrDrop60: Int?
        public var targetZone: Int?
        public var secondsInTargetZone: Double?
    }

    public struct Sample: Codable, Equatable, Sendable {
        public var t: Double
        public var activeSeconds: Double
        public var measuredSpeedKmh: Double?
        public var measuredInclinePercent: Double?
        public var targetSpeedKmh: Double?
        public var targetInclinePercent: Double?
        public var hr: Int?
        public var zone: Int?
        public var distanceMeters: Double
        public var paused: Bool
    }

    public struct HeartRate: Codable, Equatable, Sendable {
        public var t: Double
        public var date: Date
        public var bpm: Int
        public var source: String
    }

    public struct Zones: Codable, Equatable, Sendable {
        public var method: String
        public var maxHR: Int
        public var restingHR: Int?
        /// Six bornes : début Z1 (0 = sans plancher), début Z2…Z5, FC max.
        public var bounds: [Int]
        /// Secondes par zone (index 0 = sous Z1, 1…5).
        public var secondsPerZone: [Double]
        /// Règle de calcul de `secondsPerZone` (docs/ZONES.md), et origine de FC max / repos.
        public var rule: String?
        public var maxHRSource: String?
        public var restingHRSource: String?
    }

    public struct Interruptions: Codable, Equatable, Sendable {
        public var pauses: Int
        public var connectionLosses: Int
        public var machineStops: Int
        public var manualChanges: Int
        public var skippedPhases: Int
        public var recoveredAfterCrash: Bool
    }

    public struct Recovery: Codable, Equatable, Sendable {
        public var hrAtStop: Int
        public var hrAfter60: Int?
        public var hrAfter120: Int?
    }

    public struct Event: Codable, Equatable, Sendable {
        public var t: Double
        public var kind: String
        public var detail: String
    }

    public var format = RythmeSessionExport.format
    public var formatVersion = RythmeSessionExport.formatVersion
    public var exportedAt: Date
    public var session: Session
    public var program: Program?
    public var plannedSegments: [PlannedSegment]
    public var executedSegments: [ExecutedSegment]
    public var samples: [Sample]
    public var heartRate: [HeartRate]
    public var zones: Zones?
    public var autoAdjustments: [AutoAdjustment]
    public var interruptions: Interruptions
    public var recovery: Recovery?
    /// Échelle CR10 de Borg (0–10), saisie par l'utilisateur ; nil si non renseigné.
    public var perceivedExertion: Int?
    public var distanceMeters: Double
    public var steps: Int?
    public var avgHR: Int?
    public var maxHR: Int?
    public var events: [Event]

    public init(record r: SessionRecord, exportedAt: Date = Date()) {
        self.exportedAt = exportedAt
        session = Session(id: r.id, startDate: r.startDate, endDate: r.endDate, beltStartDate: r.beltStartDate,
                          beltStopDate: r.beltStopDate, activeSeconds: r.activeSeconds, pausedSeconds: r.pausedSeconds,
                          simulated: r.simulated, interrupted: r.interrupted, treadmillName: r.treadmillName,
                          treadmillProfile: r.profileID)
        if let p = r.program {
            program = Program(id: p.id, templateID: r.templateID ?? p.templateID, name: r.title, level: r.programLevel ?? p.level,
                              protocolVersion: r.protocolVersion ?? p.protocolVersion,
                              protocolSignature: r.programSignature ?? p.protocolSignature, advanced: p.isAdvanced,
                              plannedSeconds: p.totalDurationSeconds)
            plannedSegments = p.schedule.map { sp in
                PlannedSegment(index: sp.index, name: sp.displayName, kind: sp.phase.kind.rawValue, plannedStartSeconds: sp.start,
                               durationSeconds: sp.phase.durationSeconds, targetSpeedKmh: sp.phase.speedKmh,
                               targetEndSpeedKmh: sp.phase.isRamp ? sp.phase.endSpeedKmh : nil,
                               targetInclinePercent: sp.phase.inclinePercent,
                               targetZone: sp.phase.autoSpeed?.targetZone ?? sp.phase.targetZone,
                               autoSpeedRangeKmh: sp.phase.autoSpeed.map { [$0.minKmh, $0.maxKmh] },
                               repetition: sp.repetition.map { "\($0.blockName) \($0.iteration)/\($0.count)" })
            }
        } else {
            program = nil
            plannedSegments = []
        }
        let spans = r.phaseSpans ?? []
        executedSegments = SessionAnalysis.phaseStats(r).map { st in
            let span = spans.first { $0.index == st.index && abs($0.start - st.start) < 0.001 }
            return ExecutedSegment(index: st.index, name: st.name, kind: st.kind.rawValue, start: st.start, end: st.end,
                                   targetSpeedKmh: st.targetSpeedKmh, targetInclinePercent: span?.targetInclinePercent ?? 0,
                                   autoSpeed: st.auto, measuredAvgSpeedKmh: st.avgSpeed, measuredMaxSpeedKmh: st.maxSpeed,
                                   avgHR: st.avgHR, maxHR: st.maxHR, hrAtEnd: st.hrAtEnd, hrDrop60: st.recoveryDrop60,
                                   targetZone: st.targetZone, secondsInTargetZone: st.secondsInTargetZone)
        }
        samples = r.samples.map {
            Sample(t: $0.t, activeSeconds: $0.active, measuredSpeedKmh: $0.speed, measuredInclinePercent: $0.incline,
                   targetSpeedKmh: $0.targetSpeed, targetInclinePercent: $0.targetIncline, hr: $0.hr, zone: $0.zone,
                   distanceMeters: $0.distance, paused: $0.paused)
        }
        heartRate = (r.heartRateReadings ?? []).map {
            HeartRate(t: $0.t, date: r.date(at: $0.t), bpm: $0.bpm, source: $0.source.rawValue)
        }
        zones = r.zoneSettings.map {
            Zones(method: $0.effectiveMethod.rawValue, maxHR: $0.maxHR, restingHR: $0.restingHR, bounds: $0.bounds,
                  secondsPerZone: r.zoneSeconds, rule: SessionAnalysis.zoneRuleID,
                  maxHRSource: $0.maxHRIsUserValue ? "saisie dans Foulée" : $0.maxHRSource,
                  restingHRSource: $0.restingHRIsUserValue ? "saisie dans Foulée" : $0.restingHRSource)
        }
        autoAdjustments = r.autoAdjustments ?? []
        interruptions = Interruptions(pauses: r.events.filter { $0.kind == .pause }.count,
                                      connectionLosses: r.events.filter { $0.kind == .connectionLost }.count,
                                      machineStops: r.events.filter { $0.kind == .machineStopped }.count,
                                      manualChanges: r.manualChanges ?? 0, skippedPhases: r.skippedPhases ?? 0,
                                      recoveredAfterCrash: r.interrupted)
        recovery = SessionAnalysis.postStopRecovery(r).map {
            Recovery(hrAtStop: $0.hrAtStop, hrAfter60: $0.hrAfter60, hrAfter120: $0.hrAfter120)
        }
        perceivedExertion = r.perceivedExertion
        distanceMeters = r.distanceMeters
        steps = r.steps
        avgHR = r.avgHR
        maxHR = r.maxHR
        events = r.events.map { Event(t: $0.t, kind: $0.kind.rawValue, detail: $0.detail) }
    }

    /// JSON trié et lisible, dates ISO 8601.
    public static func json(_ records: [SessionRecord], exportedAt: Date = Date()) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        if records.count == 1 { return try e.encode(RythmeSessionExport(record: records[0], exportedAt: exportedAt)) }
        return try e.encode(records.map { RythmeSessionExport(record: $0, exportedAt: exportedAt) })
    }
}
