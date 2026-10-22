import Foundation

/// Erreur de décodage d'un paquet GATT. Le nom du champ aide le diagnostic.
public enum FTMSDecodeError: Error, Equatable, CustomStringConvertible {
    case empty
    case truncated(field: String, needed: Int, available: Int)
    case invalidValue(field: String, detail: String)

    public var description: String {
        switch self {
        case .empty:
            return "paquet vide"
        case let .truncated(field, needed, available):
            return "paquet tronqué au champ « \(field) » (\(needed) octet(s) attendu(s), \(available) disponible(s))"
        case let .invalidValue(field, detail):
            return "valeur invalide pour « \(field) » : \(detail)"
        }
    }
}

/// Lecteur little-endian (ordre des octets GATT) avec vérification de longueur.
public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ data: Data) { self.bytes = [UInt8](data) }

    public var remaining: Int { bytes.count - offset }
    public var remainingBytes: [UInt8] { Array(bytes[offset...]) }

    private mutating func take(_ count: Int, field: String) throws -> ArraySlice<UInt8> {
        guard remaining >= count else {
            throw FTMSDecodeError.truncated(field: field, needed: count, available: max(remaining, 0))
        }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    public mutating func uint8(_ field: String) throws -> UInt8 {
        try take(1, field: field).first!
    }

    public mutating func uint16(_ field: String) throws -> UInt16 {
        let s = try take(2, field: field)
        return UInt16(s[s.startIndex]) | (UInt16(s[s.startIndex + 1]) << 8)
    }

    public mutating func sint16(_ field: String) throws -> Int16 {
        Int16(bitPattern: try uint16(field))
    }

    public mutating func uint24(_ field: String) throws -> UInt32 {
        let s = try take(3, field: field)
        return UInt32(s[s.startIndex])
            | (UInt32(s[s.startIndex + 1]) << 8)
            | (UInt32(s[s.startIndex + 2]) << 16)
    }

    public mutating func uint32(_ field: String) throws -> UInt32 {
        let s = try take(4, field: field)
        return UInt32(s[s.startIndex])
            | (UInt32(s[s.startIndex + 1]) << 8)
            | (UInt32(s[s.startIndex + 2]) << 16)
            | (UInt32(s[s.startIndex + 3]) << 24)
    }
}

/// Écrivain little-endian, utilisé pour les commandes et le simulateur.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func uint8(_ v: UInt8) { bytes.append(v) }
    public mutating func uint16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    public mutating func sint16(_ v: Int16) { uint16(UInt16(bitPattern: v)) }
    public mutating func uint24(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF)); bytes.append(UInt8((v >> 16) & 0xFF))
    }
    public mutating func uint32(_ v: UInt32) {
        uint16(UInt16(v & 0xFFFF)); uint16(UInt16(v >> 16))
    }
}

public extension Array where Element == UInt8 {
    /// Représentation hexadécimale « 01 A2 FF » pour les journaux.
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

public extension Data {
    var hexString: String { [UInt8](self).hexString }
}

/// Arrondi d'un `Double` vers l'entier le plus proche avec saturation.
@inlinable
func clampedRound<T: FixedWidthInteger>(_ value: Double, as: T.Type) -> T {
    let r = value.rounded()
    if r >= Double(T.max) { return T.max }
    if r <= Double(T.min) { return T.min }
    return T(r)
}
