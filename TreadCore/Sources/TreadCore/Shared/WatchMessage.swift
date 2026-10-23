import Foundation

/// Messages échangés entre l'Apple Watch et l'iPhone, via le mirroring HealthKit
/// (`sendToRemoteWorkoutSession`) ou, à défaut, WatchConnectivity.
public enum WatchMessage: Codable, Equatable, Sendable {
    /// Watch → iPhone : FC mesurée, avec la date de l'échantillon HealthKit.
    case heartRate(bpm: Double, sampleDate: Date)
    /// Watch → iPhone : pas cumulés depuis le début de l'exercice Watch.
    case steps(total: Double, sampleDate: Date)
    /// Watch → iPhone : énergie active cumulée (kcal) de l'exercice Watch.
    case activeEnergy(kcal: Double, sampleDate: Date)
    /// Watch → iPhone : état de la session d'exercice.
    case workoutState(WatchWorkoutState, startDate: Date?)
    /// iPhone → Watch : identifiant de la séance (clé d'idempotence Santé).
    case linkSession(id: UUID, title: String)
    /// iPhone → Watch : commande.
    case command(WatchCommand)
    /// iPhone → Watch : métadonnées à poser sur la séance de la Watch (propriétaire de
    /// l'enregistrement Santé) : identifiant de synchronisation et informations Foulée.
    case workoutMetadata(standard: StandardWorkoutMetadata, foulee: [String: MetadataValue])
    /// iPhone → Watch (≈ 1 Hz) : état du tapis et du programme, zones et temps par zone.
    case liveStatus(WatchLiveStatus)
    /// Watch → iPhone : commande du tapis demandée depuis la montre (ancienne forme, sans séance).
    case remoteCommand(WatchRemoteCommand)
    /// iPhone → Watch : programmes, état du tapis, séance en cours.
    case context(WatchPhoneContext)
    /// Watch → iPhone : demande de contexte (ouverture de l'app Watch).
    case requestContext
    /// Watch → iPhone : démarrer un programme (ou une séance libre) sur le tapis.
    case startRequest(WatchStartRequest)
    /// iPhone → Watch : résultat de la demande de démarrage.
    case startResult(WatchStartResult)
    /// Watch → iPhone : pause, reprise, arrêt liés à une séance et horodatés.
    case control(WatchControl)

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> WatchMessage {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(WatchMessage.self, from: data)
    }

    /// Clé utilisée dans les dictionnaires WatchConnectivity.
    public static let wcKey = "foulee.msg"
}

public enum WatchWorkoutState: String, Codable, Sendable {
    case notStarted, running, paused, ended, failed
}

public enum WatchCommand: String, Codable, Sendable {
    case pause, resume, end, discard
}

/// Commandes du tapis depuis la Watch, exécutées par l'iPhone (qui pilote le tapis en FTMS).
public enum WatchRemoteCommand: String, Codable, Sendable {
    case pause, resume, stop, resumeAutopilot
}

/// État de la séance envoyé à la Watch. La Watch affiche sa propre FC (capteur local) et calcule
/// sa zone avec `zoneBounds` ; le reste vient de l'iPhone.
public struct WatchLiveStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case ready, starting, running, paused, finished }

    public var state: State
    public var stateLabel: String
    public var programName: String?
    public var activeSeconds: Double
    /// Vitesse et inclinaison mesurées (nil si la télémétrie est périmée).
    public var speedKmh: Double?
    public var inclinePercent: Double?
    public var targetSpeedKmh: Double
    public var targetInclinePercent: Double
    public var phaseName: String?
    public var phaseIndex: Int?
    public var phaseCount: Int
    public var phaseRemaining: Double?
    public var programRemaining: Double?
    public var nextPhaseName: String?
    /// Six bornes : début Z1 (0 = sans plancher), début Z2…Z5, FC max.
    public var zoneBounds: [Int]
    /// Secondes passées dans chaque zone (index 0 = sous Z1, 1…5).
    public var zoneSeconds: [Double]
    public var targetZone: Int?
    /// FC utilisée par l'iPhone (sa source peut être une ceinture) et zone correspondante.
    public var phoneHeartRate: Int?
    public var phoneHeartRateSource: String?
    public var phoneZone: Int?
    /// Pilotage FC : état lisible, et vrai si l'utilisateur peut le réactiver.
    public var autopilotStatus: String?
    public var autopilotManual: Bool
    public var sentAt: Date
    /// Séance de l'iPhone (les commandes de la montre s'y rapportent).
    public var sessionID: UUID?
    /// Tapis : connexion perdue (état réel inconnu).
    public var treadmillLinkLost: Bool?
    /// Dernière alerte (perte de FC, écart…) à signaler sur la montre.
    public var alert: String?

    public init(state: State, stateLabel: String, programName: String?, activeSeconds: Double, speedKmh: Double?,
                inclinePercent: Double?, targetSpeedKmh: Double, targetInclinePercent: Double, phaseName: String?,
                phaseIndex: Int?, phaseCount: Int, phaseRemaining: Double?, programRemaining: Double?,
                nextPhaseName: String?, zoneBounds: [Int], zoneSeconds: [Double], targetZone: Int?,
                phoneHeartRate: Int?, phoneHeartRateSource: String?, phoneZone: Int?, autopilotStatus: String?,
                autopilotManual: Bool, sentAt: Date, sessionID: UUID? = nil, treadmillLinkLost: Bool? = nil, alert: String? = nil) {
        self.state = state
        self.stateLabel = stateLabel
        self.programName = programName
        self.activeSeconds = activeSeconds
        self.speedKmh = speedKmh
        self.inclinePercent = inclinePercent
        self.targetSpeedKmh = targetSpeedKmh
        self.targetInclinePercent = targetInclinePercent
        self.phaseName = phaseName
        self.phaseIndex = phaseIndex
        self.phaseCount = phaseCount
        self.phaseRemaining = phaseRemaining
        self.programRemaining = programRemaining
        self.nextPhaseName = nextPhaseName
        self.zoneBounds = zoneBounds
        self.zoneSeconds = zoneSeconds
        self.targetZone = targetZone
        self.phoneHeartRate = phoneHeartRate
        self.phoneHeartRateSource = phoneHeartRateSource
        self.phoneZone = phoneZone
        self.autopilotStatus = autopilotStatus
        self.autopilotManual = autopilotManual
        self.sentAt = sentAt
        self.sessionID = sessionID
        self.treadmillLinkLost = treadmillLinkLost
        self.alert = alert
    }

    /// Zone (1…5) d'une FC avec les bornes reçues (même règle que `HeartZoneSettings.zone(for:)` :
    /// sous Z2 = Z1 si la zone 1 n'a pas de plancher, sinon 0).
    public static func zone(for bpm: Int, bounds b: [Int]) -> Int? {
        guard b.count == 6 else { return nil }
        for z in (2...5).reversed() where bpm >= b[z - 1] { return z }
        return b[0] == 0 || bpm >= b[0] ? 1 : 0
    }

    /// Bornes [basse, haute] d'une zone et position (0…1) d'une FC dans cette zone.
    public static func range(of zone: Int, bounds b: [Int]) -> (lower: Int, upper: Int)? {
        guard b.count == 6, (1...5).contains(zone) else { return nil }
        return (b[zone - 1], b[zone])
    }

    public static func progress(of bpm: Int, in zone: Int, bounds b: [Int]) -> Double? {
        guard let r = range(of: zone, bounds: b) else { return nil }
        let lower = zone == 1 && r.lower == 0 ? max(0, r.upper - 30) : r.lower
        guard r.upper > lower else { return nil }
        return min(max(Double(bpm - lower) / Double(r.upper - lower), 0), 1)
    }
}

public extension WatchLiveStatus {
    /// Instantané de la séance pour la Watch.
    static func make(session s: WorkoutSession, now: TimeInterval, date: Date) -> WatchLiveStatus {
        let state: State
        let label: String
        switch s.status {
        case .ready: state = .ready; label = "Prêt"
        case .starting: state = .starting; label = "Démarrage"
        case .resuming: state = .starting; label = "Reprise"
        case .running: state = .running; label = "En cours"
        case let .paused(reason): state = .paused; label = reason.label
        case .finished: state = .finished; label = "Terminée"
        }
        let tel = s.controller.telemetry
        let fresh = tel.isFresh(now: now)
        let pos = s.position
        let hr = s.heartRate.status(now: now)
        let t = s.effectiveTargets
        let a = s.isAutoPhase ? s.autopilot : nil
        return WatchLiveStatus(
            state: state, stateLabel: label, programName: s.program?.name, activeSeconds: s.activeTime,
            speedKmh: fresh ? tel.speedKmh : nil, inclinePercent: fresh ? tel.inclinePercent : nil,
            targetSpeedKmh: t.speed, targetInclinePercent: t.incline,
            phaseName: s.isFreeRun ? nil : s.currentPhase?.displayName,
            phaseIndex: s.isFreeRun ? nil : s.engine.currentIndex, phaseCount: s.engine.schedule.count,
            phaseRemaining: s.isFreeRun || pos.phaseIndex == nil ? nil : pos.phaseRemaining,
            programRemaining: s.isFreeRun ? nil : pos.programRemaining,
            nextPhaseName: s.nextPhase?.displayName,
            zoneBounds: s.settings.zones.bounds, zoneSeconds: s.zoneTime.seconds,
            targetZone: a?.settings.targetZone ?? s.currentPhase?.phase.targetZone,
            phoneHeartRate: hr.liveBPM, phoneHeartRateSource: hr.liveBPM != nil ? s.heartRate.activeSource?.shortLabel : nil,
            phoneZone: s.currentZone, autopilotStatus: a?.status, autopilotManual: a?.mode == .manual, sentAt: date,
            sessionID: s.record.id, treadmillLinkLost: s.controller.state == .linkLost || s.status == .paused(.connectionLost),
            alert: s.lastAlert)
    }
}
