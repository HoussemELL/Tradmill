import Foundation

/// Journal horodaté des échanges BLE, commandes, réponses et télémétrie.
/// Exportable en texte ou JSON depuis l'écran Diagnostic.
public final class DiagnosticLog {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case ble = "BLE"
        case tx = "TX"
        case rx = "RX"
        case response = "REP"
        case status = "STATUT"
        case telemetry = "DATA"
        case command = "CMD"
        case session = "SEANCE"
        case heart = "FC"
        case health = "SANTE"
        case watch = "WATCH"
        case warning = "ALERTE"
        case error = "ERREUR"
        case info = "INFO"
    }

    public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public var id: Int
        public var date: Date
        public var category: Category
        public var message: String
        public var hex: String?
    }

    public private(set) var entries: [Entry] = []
    public var capacity: Int
    /// Journaliser chaque paquet de télémétrie brut (volumineux mais utile au diagnostic).
    public var includeRawTelemetry = true
    public var clock: () -> Date
    public var onAppend: ((Entry) -> Void)?
    private var nextID = 0

    public init(capacity: Int = 30_000, clock: @escaping () -> Date = Date.init) {
        self.capacity = capacity
        self.clock = clock
    }

    public func log(_ category: Category, _ message: String, bytes: [UInt8]? = nil) {
        if category == .telemetry && !includeRawTelemetry { return }
        let entry = Entry(id: nextID, date: clock(), category: category, message: message, hex: bytes?.hexString)
        nextID += 1
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        onAppend?(entry)
    }

    public func clear() {
        entries.removeAll()
        log(.info, "Journal effacé")
    }

    public static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func format(_ e: Entry) -> String {
        var line = "\(timestampFormatter.string(from: e.date)) [\(e.category.rawValue)] \(e.message)"
        if let hex = e.hex { line += " | \(hex)" }
        return line
    }

    public func exportText(header: String = "") -> String {
        var out = header.isEmpty ? "" : header + "\n"
        out += entries.map(Self.format).joined(separator: "\n")
        return out + "\n"
    }

    public func exportJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(entries)
    }
}
