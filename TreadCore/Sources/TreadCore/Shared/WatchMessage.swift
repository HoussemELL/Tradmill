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
