import Foundation

/// Op codes du Fitness Machine Control Point (0x2AD9), FTMS v1.0 §4.16.
public enum ControlOpCode: UInt8, Sendable, Codable {
    case requestControl = 0x00
    case reset = 0x01
    case setTargetSpeed = 0x02
    case setTargetInclination = 0x03
    case setTargetResistance = 0x04
    case setTargetPower = 0x05
    case setTargetHeartRate = 0x06
    case startOrResume = 0x07
    case stopOrPause = 0x08
    case responseCode = 0x80

    public var label: String {
        switch self {
        case .requestControl: return "Request Control"
        case .reset: return "Reset"
        case .setTargetSpeed: return "Set Target Speed"
        case .setTargetInclination: return "Set Target Inclination"
        case .setTargetResistance: return "Set Target Resistance"
        case .setTargetPower: return "Set Target Power"
        case .setTargetHeartRate: return "Set Target Heart Rate"
        case .startOrResume: return "Start or Resume"
        case .stopOrPause: return "Stop or Pause"
        case .responseCode: return "Response Code"
        }
    }

    public static func label(forRaw raw: UInt8) -> String {
        ControlOpCode(rawValue: raw)?.label ?? String(format: "Op 0x%02X", raw)
    }
}

/// Codes résultat (FTMS §4.16.2.22, table 4.24).
public enum ControlResultCode: Equatable, Sendable, Codable, CustomStringConvertible {
    case success
    case opCodeNotSupported
    case invalidParameter
    case operationFailed
    case controlNotPermitted
    case unknown(UInt8)

    public init(raw: UInt8) {
        switch raw {
        case 0x01: self = .success
        case 0x02: self = .opCodeNotSupported
        case 0x03: self = .invalidParameter
        case 0x04: self = .operationFailed
        case 0x05: self = .controlNotPermitted
        default: self = .unknown(raw)
        }
    }

    public var raw: UInt8 {
        switch self {
        case .success: return 0x01
        case .opCodeNotSupported: return 0x02
        case .invalidParameter: return 0x03
        case .operationFailed: return 0x04
        case .controlNotPermitted: return 0x05
        case let .unknown(r): return r
        }
    }

    public var description: String {
        switch self {
        case .success: return "succès"
        case .opCodeNotSupported: return "commande non supportée"
        case .invalidParameter: return "paramètre invalide"
        case .operationFailed: return "opération échouée"
        case .controlNotPermitted: return "contrôle non autorisé"
        case let .unknown(r): return String(format: "code inconnu 0x%02X", r)
        }
    }
}

/// Commande de haut niveau vers le Control Point.
public enum ControlCommand: Equatable, Sendable, CustomStringConvertible {
    case requestControl
    case reset
    case setTargetSpeed(kmh: Double)
    case setTargetInclination(percent: Double)
    case startOrResume
    case stop
    case pause

    public var opCode: ControlOpCode {
        switch self {
        case .requestControl: return .requestControl
        case .reset: return .reset
        case .setTargetSpeed: return .setTargetSpeed
        case .setTargetInclination: return .setTargetInclination
        case .startOrResume: return .startOrResume
        case .stop, .pause: return .stopOrPause
        }
    }

    /// Paramètre Stop or Pause : 0x01 = Stop, 0x02 = Pause.
    public static let stopParameter: UInt8 = 0x01
    public static let pauseParameter: UInt8 = 0x02

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.uint8(opCode.rawValue)
        switch self {
        case let .setTargetSpeed(kmh):
            // uint16, résolution 0,01 km/h
            w.uint16(clampedRound(kmh * 100, as: UInt16.self))
        case let .setTargetInclination(percent):
            // sint16, résolution 0,1 %
            w.sint16(clampedRound(percent * 10, as: Int16.self))
        case .stop:
            w.uint8(Self.stopParameter)
        case .pause:
            w.uint8(Self.pauseParameter)
        case .requestControl, .reset, .startOrResume:
            break
        }
        return w.bytes
    }

    public var description: String {
        switch self {
        case .requestControl: return "Request Control"
        case .reset: return "Reset"
        case let .setTargetSpeed(kmh): return String(format: "Set Target Speed %.2f km/h", kmh)
        case let .setTargetInclination(p): return String(format: "Set Target Inclination %.1f %%", p)
        case .startOrResume: return "Start/Resume"
        case .stop: return "Stop"
        case .pause: return "Pause"
        }
    }

    /// Décodage d'une écriture Control Point (utilisé par le simulateur).
    public static func decode(_ bytes: [UInt8]) throws -> ControlCommand {
        var r = ByteReader(bytes)
        let op = try r.uint8("Op Code")
        switch op {
        case ControlOpCode.requestControl.rawValue: return .requestControl
        case ControlOpCode.reset.rawValue: return .reset
        case ControlOpCode.setTargetSpeed.rawValue:
            return .setTargetSpeed(kmh: Double(try r.uint16("Target Speed")) / 100)
        case ControlOpCode.setTargetInclination.rawValue:
            return .setTargetInclination(percent: Double(try r.sint16("Target Inclination")) / 10)
        case ControlOpCode.startOrResume.rawValue: return .startOrResume
        case ControlOpCode.stopOrPause.rawValue:
            let p = try r.uint8("Stop/Pause parameter")
            switch p {
            case stopParameter: return .stop
            case pauseParameter: return .pause
            default: throw FTMSDecodeError.invalidValue(field: "Stop/Pause parameter", detail: String(format: "0x%02X", p))
            }
        default:
            throw FTMSDecodeError.invalidValue(field: "Op Code", detail: String(format: "0x%02X non géré", op))
        }
    }
}

/// Indication de réponse du Control Point : 0x80, op code de la requête, code résultat, [paramètres].
public struct ControlPointResponse: Equatable, Sendable {
    public var requestOpCode: UInt8
    public var result: ControlResultCode
    public var parameters: [UInt8]

    public init(requestOpCode: UInt8, result: ControlResultCode, parameters: [UInt8] = []) {
        self.requestOpCode = requestOpCode
        self.result = result
        self.parameters = parameters
    }

    public static func decode(_ bytes: [UInt8]) throws -> ControlPointResponse {
        var r = ByteReader(bytes)
        let code = try r.uint8("Response Op Code")
        guard code == ControlOpCode.responseCode.rawValue else {
            throw FTMSDecodeError.invalidValue(field: "Response Op Code", detail: String(format: "0x%02X au lieu de 0x80", code))
        }
        let req = try r.uint8("Request Op Code")
        let res = try r.uint8("Result Code")
        return ControlPointResponse(requestOpCode: req, result: ControlResultCode(raw: res), parameters: r.remainingBytes)
    }

    public func encode() -> [UInt8] {
        [ControlOpCode.responseCode.rawValue, requestOpCode, result.raw] + parameters
    }
}
