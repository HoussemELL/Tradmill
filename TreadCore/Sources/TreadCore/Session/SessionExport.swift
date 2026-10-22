import Foundation

public enum SessionExport {
    public static func json(_ records: [SessionRecord]) throws -> Data {
        struct File: Encodable {
            let format = "foulee.sessions"
            let formatVersion = SessionRecord.formatVersion
            let sessions: [SessionRecord]
        }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(File(sessions: records))
    }

    public static func decodeRecord(_ data: Data) throws -> SessionRecord {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SessionRecord.self, from: data)
    }

    public static func encodeRecord(_ r: SessionRecord) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try e.encode(r)
    }

    /// CSV des échantillons (séparateur virgule, point décimal, horodatage ISO 8601).
    public static func csv(_ r: SessionRecord) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["timestamp,t_s,active_s,speed_kmh,incline_pct,target_speed_kmh,target_incline_pct,hr_bpm,hr_source,zone,distance_m,steps,phase,paused"]
        func f(_ v: Double?, _ digits: Int = 2) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        for s in r.samples {
            let ts = iso.string(from: r.startDate.addingTimeInterval(s.t))
            var cols: [String] = [ts, f(s.t, 1), f(s.active, 1), f(s.speed), f(s.incline, 1)]
            cols.append(f(s.targetSpeed))
            cols.append(f(s.targetIncline, 1))
            cols.append(s.hr.map { String($0) } ?? "")
            cols.append(s.hrSource?.rawValue ?? "")
            cols.append(s.zone.map { String($0) } ?? "")
            cols.append(f(s.distance, 1))
            cols.append(s.steps.map { String($0) } ?? "")
            cols.append(s.phase.map { String($0) } ?? "")
            cols.append(s.paused ? "1" : "0")
            lines.append(cols.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Nom de fichier sûr pour l'export.
    public static func fileName(for r: SessionRecord, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return "seance_\(f.string(from: r.startDate)).\(ext)"
    }
}

/// Point de sauvegarde de la séance en cours (fichier JSON atomique).
public final class CheckpointStore {
    public let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("seance-en-cours.json")
    }

    public func save(_ cp: WorkoutSession.Checkpoint) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let data = try e.encode(cp)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func load() -> WorkoutSession.Checkpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(WorkoutSession.Checkpoint.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
