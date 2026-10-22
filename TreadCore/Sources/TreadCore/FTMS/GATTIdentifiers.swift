import Foundation

/// UUID 16 bits des services et caractéristiques utilisés (Bluetooth SIG Assigned Numbers).
/// Chaînes au format accepté par `CBUUID(string:)`.
public enum GATTID {
    // Fitness Machine Service (FTMS v1.0)
    public static let fitnessMachineService = "1826"
    public static let fitnessMachineFeature = "2ACC"
    public static let treadmillData = "2ACD"
    public static let trainingStatus = "2AD3"
    public static let supportedSpeedRange = "2AD4"
    public static let supportedInclinationRange = "2AD5"
    public static let fitnessMachineControlPoint = "2AD9"
    public static let fitnessMachineStatus = "2ADA"

    // Heart Rate Service
    public static let heartRateService = "180D"
    public static let heartRateMeasurement = "2A37"

    // Device Information Service
    public static let deviceInformationService = "180A"
    public static let manufacturerName = "2A29"
    public static let modelNumber = "2A24"
    public static let serialNumber = "2A25"
    public static let hardwareRevision = "2A27"
    public static let firmwareRevision = "2A26"
    public static let softwareRevision = "2A28"

    public static func name(for uuid: String) -> String {
        switch uuid.uppercased() {
        case fitnessMachineService: return "Fitness Machine Service"
        case fitnessMachineFeature: return "Fitness Machine Feature"
        case treadmillData: return "Treadmill Data"
        case trainingStatus: return "Training Status"
        case supportedSpeedRange: return "Supported Speed Range"
        case supportedInclinationRange: return "Supported Inclination Range"
        case fitnessMachineControlPoint: return "Fitness Machine Control Point"
        case fitnessMachineStatus: return "Fitness Machine Status"
        case heartRateService: return "Heart Rate Service"
        case heartRateMeasurement: return "Heart Rate Measurement"
        case deviceInformationService: return "Device Information"
        case manufacturerName: return "Manufacturer Name"
        case modelNumber: return "Model Number"
        case serialNumber: return "Serial Number"
        case hardwareRevision: return "Hardware Revision"
        case firmwareRevision: return "Firmware Revision"
        case softwareRevision: return "Software Revision"
        default: return uuid
        }
    }
}
