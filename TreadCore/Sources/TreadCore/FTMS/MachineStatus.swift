import Foundation

/// Fitness Machine Status (0x2ADA), FTMS v1.0 §4.17 (notifications).
public enum MachineStatus: Equatable, Sendable, CustomStringConvertible {
    case reset
    /// 0x02 : arrêté (0x01) ou mis en pause (0x02) par l'utilisateur sur le tapis.
    case stoppedOrPausedByUser(paused: Bool)
    case stoppedBySafetyKey
    case startedOrResumedByUser
    case targetSpeedChanged(kmh: Double)
    case targetInclinationChanged(percent: Double)
    case controlPermissionLost
    case other(opCode: UInt8, parameters: [UInt8])

    public static func decode(_ bytes: [UInt8]) throws -> MachineStatus {
        var r = ByteReader(bytes)
        let op = try r.uint8("Status Op Code")
        switch op {
        case 0x01: return .reset
        case 0x02:
            let p = try r.uint8("Control Information")
            return .stoppedOrPausedByUser(paused: p == 0x02)
        case 0x03: return .stoppedBySafetyKey
        case 0x04: return .startedOrResumedByUser
        case 0x05: return .targetSpeedChanged(kmh: Double(try r.uint16("New Target Speed")) / 100)
        case 0x06: return .targetInclinationChanged(percent: Double(try r.sint16("New Target Inclination")) / 10)
        case 0xFF: return .controlPermissionLost
        default: return .other(opCode: op, parameters: r.remainingBytes)
        }
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .reset: w.uint8(0x01)
        case let .stoppedOrPausedByUser(paused): w.uint8(0x02); w.uint8(paused ? 0x02 : 0x01)
        case .stoppedBySafetyKey: w.uint8(0x03)
        case .startedOrResumedByUser: w.uint8(0x04)
        case let .targetSpeedChanged(kmh): w.uint8(0x05); w.uint16(clampedRound(kmh * 100, as: UInt16.self))
        case let .targetInclinationChanged(p): w.uint8(0x06); w.sint16(clampedRound(p * 10, as: Int16.self))
        case .controlPermissionLost: w.uint8(0xFF)
        case let .other(op, params): w.uint8(op); params.forEach { w.uint8($0) }
        }
        return w.bytes
    }

    public var description: String {
        switch self {
        case .reset: return "Réinitialisé"
        case let .stoppedOrPausedByUser(paused): return paused ? "Mis en pause sur le tapis" : "Arrêté sur le tapis"
        case .stoppedBySafetyKey: return "Arrêté par la clé de sécurité"
        case .startedOrResumedByUser: return "Démarré/repris"
        case let .targetSpeedChanged(kmh): return String(format: "Consigne vitesse du tapis : %.2f km/h", kmh)
        case let .targetInclinationChanged(p): return String(format: "Consigne inclinaison du tapis : %.1f %%", p)
        case .controlPermissionLost: return "Contrôle perdu"
        case let .other(op, params): return String(format: "Statut 0x%02X ", op) + params.hexString
        }
    }
}

/// Training Status (0x2AD3) : flags uint8, statut uint8, chaîne optionnelle.
public struct TrainingStatus: Equatable, Sendable {
    public var status: UInt8
    public var text: String?

    public static func decode(_ bytes: [UInt8]) throws -> TrainingStatus {
        var r = ByteReader(bytes)
        let flags = try r.uint8("Flags")
        let status = try r.uint8("Training Status")
        var text: String?
        if flags & 0x01 != 0, r.remaining > 0 {
            text = String(decoding: r.remainingBytes, as: UTF8.self)
        }
        return TrainingStatus(status: status, text: text)
    }

    public var label: String {
        switch status {
        case 0x00: return "Autre"
        case 0x01: return "Inactif"
        case 0x02: return "Échauffement"
        case 0x03: return "Intervalle faible intensité"
        case 0x04: return "Intervalle haute intensité"
        case 0x05: return "Récupération"
        case 0x06: return "Isométrique"
        case 0x07: return "Contrôle FC"
        case 0x08: return "Test"
        case 0x09: return "Vitesse trop basse"
        case 0x0A: return "Vitesse trop haute"
        case 0x0B: return "Retour au calme"
        case 0x0C: return "Contrôle puissance"
        case 0x0D: return "Mode manuel"
        case 0x0E: return "Avant séance"
        case 0x0F: return "Après séance"
        default: return String(format: "Statut 0x%02X", status)
        }
    }
}
