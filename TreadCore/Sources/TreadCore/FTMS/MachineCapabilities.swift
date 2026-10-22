import Foundation

/// Fitness Machine Feature (0x2ACC) : deux champs uint32.
public struct FitnessMachineFeature: Equatable, Sendable, Codable {
    public struct Machine: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let averageSpeed = Machine(rawValue: 1 << 0)
        public static let cadence = Machine(rawValue: 1 << 1)
        public static let totalDistance = Machine(rawValue: 1 << 2)
        public static let inclination = Machine(rawValue: 1 << 3)
        public static let elevationGain = Machine(rawValue: 1 << 4)
        public static let pace = Machine(rawValue: 1 << 5)
        public static let stepCount = Machine(rawValue: 1 << 6)
        public static let resistanceLevel = Machine(rawValue: 1 << 7)
        public static let strideCount = Machine(rawValue: 1 << 8)
        public static let expendedEnergy = Machine(rawValue: 1 << 9)
        public static let heartRate = Machine(rawValue: 1 << 10)
        public static let metabolicEquivalent = Machine(rawValue: 1 << 11)
        public static let elapsedTime = Machine(rawValue: 1 << 12)
        public static let remainingTime = Machine(rawValue: 1 << 13)
        public static let powerMeasurement = Machine(rawValue: 1 << 14)
        public static let forceOnBeltAndPower = Machine(rawValue: 1 << 15)
        public static let userDataRetention = Machine(rawValue: 1 << 16)

        public static let names: [(Machine, String)] = [
            (.averageSpeed, "Vitesse moyenne"), (.cadence, "Cadence"), (.totalDistance, "Distance totale"),
            (.inclination, "Inclinaison"), (.elevationGain, "Dénivelé"), (.pace, "Allure"),
            (.stepCount, "Nombre de pas"), (.resistanceLevel, "Résistance"), (.strideCount, "Foulées"),
            (.expendedEnergy, "Énergie dépensée"), (.heartRate, "Fréquence cardiaque"),
            (.metabolicEquivalent, "MET"), (.elapsedTime, "Temps écoulé"), (.remainingTime, "Temps restant"),
            (.powerMeasurement, "Puissance"), (.forceOnBeltAndPower, "Force tapis/puissance"),
            (.userDataRetention, "Données utilisateur"),
        ]
    }

    public struct TargetSetting: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let speed = TargetSetting(rawValue: 1 << 0)
        public static let inclination = TargetSetting(rawValue: 1 << 1)
        public static let resistance = TargetSetting(rawValue: 1 << 2)
        public static let power = TargetSetting(rawValue: 1 << 3)
        public static let heartRate = TargetSetting(rawValue: 1 << 4)
        public static let expendedEnergy = TargetSetting(rawValue: 1 << 5)
        public static let stepNumber = TargetSetting(rawValue: 1 << 6)
        public static let strideNumber = TargetSetting(rawValue: 1 << 7)
        public static let distance = TargetSetting(rawValue: 1 << 8)
        public static let trainingTime = TargetSetting(rawValue: 1 << 9)

        public static let names: [(TargetSetting, String)] = [
            (.speed, "Vitesse"), (.inclination, "Inclinaison"), (.resistance, "Résistance"),
            (.power, "Puissance"), (.heartRate, "FC cible"), (.expendedEnergy, "Énergie cible"),
            (.stepNumber, "Pas cibles"), (.strideNumber, "Foulées cibles"), (.distance, "Distance cible"),
            (.trainingTime, "Durée cible"),
        ]
    }

    public var machine: Machine
    public var targetSettings: TargetSetting

    public init(machine: Machine, targetSettings: TargetSetting) {
        self.machine = machine
        self.targetSettings = targetSettings
    }

    public static func decode(_ bytes: [UInt8]) throws -> FitnessMachineFeature {
        var r = ByteReader(bytes)
        let m = try r.uint32("Fitness Machine Features")
        let t = try r.uint32("Target Setting Features")
        return FitnessMachineFeature(machine: Machine(rawValue: m), targetSettings: TargetSetting(rawValue: t))
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.uint32(machine.rawValue)
        w.uint32(targetSettings.rawValue)
        return w.bytes
    }

    public var machineDescription: String {
        Machine.names.filter { machine.contains($0.0) }.map(\.1).joined(separator: ", ")
    }

    public var targetDescription: String {
        TargetSetting.names.filter { targetSettings.contains($0.0) }.map(\.1).joined(separator: ", ")
    }
}

/// Supported Speed Range (0x2AD4) : uint16 min, uint16 max, uint16 incrément, en 0,01 km/h.
public struct SpeedRange: Equatable, Sendable, Codable {
    public var minKmh: Double
    public var maxKmh: Double
    public var incrementKmh: Double

    public init(minKmh: Double, maxKmh: Double, incrementKmh: Double) {
        self.minKmh = minKmh
        self.maxKmh = maxKmh
        self.incrementKmh = incrementKmh
    }

    public static func decode(_ bytes: [UInt8]) throws -> SpeedRange {
        var r = ByteReader(bytes)
        let mn = Double(try r.uint16("Minimum Speed")) / 100
        let mx = Double(try r.uint16("Maximum Speed")) / 100
        let inc = Double(try r.uint16("Minimum Increment")) / 100
        guard mx >= mn else { throw FTMSDecodeError.invalidValue(field: "Supported Speed Range", detail: "max < min") }
        return SpeedRange(minKmh: mn, maxKmh: mx, incrementKmh: inc)
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.uint16(clampedRound(minKmh * 100, as: UInt16.self))
        w.uint16(clampedRound(maxKmh * 100, as: UInt16.self))
        w.uint16(clampedRound(incrementKmh * 100, as: UInt16.self))
        return w.bytes
    }
}

/// Supported Inclination Range (0x2AD5) : sint16 min, sint16 max, uint16 incrément, en 0,1 %.
public struct InclinationRange: Equatable, Sendable, Codable {
    public var minPercent: Double
    public var maxPercent: Double
    public var incrementPercent: Double

    public init(minPercent: Double, maxPercent: Double, incrementPercent: Double) {
        self.minPercent = minPercent
        self.maxPercent = maxPercent
        self.incrementPercent = incrementPercent
    }

    public static func decode(_ bytes: [UInt8]) throws -> InclinationRange {
        var r = ByteReader(bytes)
        let mn = Double(try r.sint16("Minimum Inclination")) / 10
        let mx = Double(try r.sint16("Maximum Inclination")) / 10
        let inc = Double(try r.uint16("Minimum Increment")) / 10
        guard mx >= mn else { throw FTMSDecodeError.invalidValue(field: "Supported Inclination Range", detail: "max < min") }
        return InclinationRange(minPercent: mn, maxPercent: mx, incrementPercent: inc)
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.sint16(clampedRound(minPercent * 10, as: Int16.self))
        w.sint16(clampedRound(maxPercent * 10, as: Int16.self))
        w.uint16(clampedRound(incrementPercent * 10, as: UInt16.self))
        return w.bytes
    }
}

/// Capacités effectives d'un tapis, lues sur l'appareil ou fournies par un profil.
public struct TreadmillCapabilities: Equatable, Sendable, Codable {
    public var speed: SpeedRange
    public var inclination: InclinationRange?
    public var feature: FitnessMachineFeature?
    /// Vrai si les plages viennent réellement du tapis (et non d'une valeur par défaut).
    public var speedRangeFromDevice: Bool
    public var inclinationRangeFromDevice: Bool

    public init(speed: SpeedRange, inclination: InclinationRange?, feature: FitnessMachineFeature?,
                speedRangeFromDevice: Bool, inclinationRangeFromDevice: Bool) {
        self.speed = speed
        self.inclination = inclination
        self.feature = feature
        self.speedRangeFromDevice = speedRangeFromDevice
        self.inclinationRangeFromDevice = inclinationRangeFromDevice
    }

    public var supportsSpeedControl: Bool { feature?.targetSettings.contains(.speed) ?? true }
    public var supportsInclinationControl: Bool {
        guard inclination != nil else { return false }
        return feature?.targetSettings.contains(.inclination) ?? true
    }

    /// Valeur la plus proche respectant la plage et l'incrément.
    public func snapSpeed(_ kmh: Double) -> Double {
        Self.snap(kmh, min: speed.minKmh, max: speed.maxKmh, step: speed.incrementKmh)
    }

    public func snapInclination(_ pct: Double) -> Double {
        guard let r = inclination else { return 0 }
        return Self.snap(pct, min: r.minPercent, max: r.maxPercent, step: r.incrementPercent)
    }

    static func snap(_ v: Double, min mn: Double, max mx: Double, step: Double) -> Double {
        let clamped = Swift.min(Swift.max(v, mn), mx)
        guard step > 0 else { return clamped }
        let steps = ((clamped - mn) / step).rounded()
        let snapped = mn + steps * step
        // Arrondi décimal pour éviter 6.999999
        let result = (Swift.min(snapped, mx) * 100).rounded() / 100
        return result
    }

    public static func isOnIncrement(_ v: Double, min mn: Double, step: Double) -> Bool {
        guard step > 0 else { return true }
        let k = (v - mn) / step
        return abs(k - k.rounded()) < 0.001
    }
}
