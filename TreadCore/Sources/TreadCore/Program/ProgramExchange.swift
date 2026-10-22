import Foundation

/// Fichier d'échange JSON des programmes, versionné.
///
/// ```json
/// { "format": "foulee.programs", "formatVersion": 1, "exportedAt": "...", "programs": [ ... ] }
/// ```
public struct ProgramExchangeFile: Codable, Equatable {
    public static let formatIdentifier = "foulee.programs"
    public static let currentVersion = 1

    public var format: String
    public var formatVersion: Int
    public var exportedAt: Date
    public var programs: [WorkoutProgram]
}

public enum ProgramExchangeError: Error, Equatable, CustomStringConvertible {
    case notJSON(String)
    case wrongFormat(String)
    case unsupportedVersion(Int)
    case invalidProgram(name: String, issues: [String])
    case empty

    public var description: String {
        switch self {
        case let .notJSON(d): return "Fichier JSON illisible : \(d)"
        case let .wrongFormat(f): return "Ce fichier n'est pas un export de programmes (format « \(f) »)"
        case let .unsupportedVersion(v): return "Version de format \(v) non prise en charge (max \(ProgramExchangeFile.currentVersion))"
        case let .invalidProgram(name, issues): return "Programme « \(name) » invalide : " + issues.joined(separator: " ; ")
        case .empty: return "Le fichier ne contient aucun programme"
        }
    }
}

public enum ProgramExchange {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func export(_ programs: [WorkoutProgram], now: Date = Date()) throws -> Data {
        let file = ProgramExchangeFile(format: ProgramExchangeFile.formatIdentifier,
                                       formatVersion: ProgramExchangeFile.currentVersion,
                                       exportedAt: now, programs: programs)
        return try encoder().encode(file)
    }

    /// Importe et valide. Les programmes reçoivent de nouveaux identifiants
    /// pour ne jamais écraser un programme existant.
    public static func importPrograms(from data: Data, now: Date = Date()) throws -> [WorkoutProgram] {
        struct Header: Decodable { var format: String?; var formatVersion: Int? }
        let header: Header
        do { header = try decoder().decode(Header.self, from: data) } catch {
            throw ProgramExchangeError.notJSON("\(error)")
        }
        guard header.format == ProgramExchangeFile.formatIdentifier else {
            throw ProgramExchangeError.wrongFormat(header.format ?? "absent")
        }
        guard let v = header.formatVersion, v >= 1 else { throw ProgramExchangeError.unsupportedVersion(header.formatVersion ?? 0) }
        guard v <= ProgramExchangeFile.currentVersion else { throw ProgramExchangeError.unsupportedVersion(v) }
        let file: ProgramExchangeFile
        do { file = try decoder().decode(ProgramExchangeFile.self, from: data) } catch {
            throw ProgramExchangeError.notJSON("\(error)")
        }
        guard !file.programs.isEmpty else { throw ProgramExchangeError.empty }
        var out: [WorkoutProgram] = []
        for p in file.programs {
            let errors = ProgramValidator.validateStructure(p).filter { $0.severity == .error }
            if !errors.isEmpty {
                throw ProgramExchangeError.invalidProgram(name: p.name, issues: errors.map(\.message))
            }
            var copy = p.duplicated(name: p.name, now: now)
            copy.createdAt = p.createdAt
            out.append(copy)
        }
        return out
    }
}
