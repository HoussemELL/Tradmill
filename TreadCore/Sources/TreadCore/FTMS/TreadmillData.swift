import Foundation

/// Caractéristique Treadmill Data (0x2ACD), FTMS v1.0 §4.9.
///
/// Champ Flags (uint16), puis champs optionnels dans l'ordre :
/// | bit | champ                                   | format / unité                         |
/// |-----|-----------------------------------------|----------------------------------------|
/// |  0  | More Data (logique INVERSE)             | si 0 : Instantaneous Speed uint16 0,01 km/h |
/// |  1  | Average Speed                           | uint16, 0,01 km/h                       |
/// |  2  | Total Distance                          | uint24, 1 m                             |
/// |  3  | Inclination + Ramp Angle Setting        | sint16 0,1 % + sint16 0,1 °             |
/// |  4  | Elevation Gain (positif + négatif)      | uint16 0,1 m + uint16 0,1 m             |
/// |  5  | Instantaneous Pace                      | uint8, 0,1 km/min                       |
/// |  6  | Average Pace                            | uint8, 0,1 km/min                       |
/// |  7  | Expended Energy (total, /h, /min)       | uint16 kcal + uint16 kcal + uint8 kcal  |
/// |  8  | Heart Rate                              | uint8, bpm                              |
/// |  9  | Metabolic Equivalent                    | uint8, 0,1                              |
/// | 10  | Elapsed Time                            | uint16, s                               |
/// | 11  | Remaining Time                          | uint16, s                               |
/// | 12  | Force on Belt + Power Output            | sint16 N + sint16 W                     |
/// | 13  | (réservé en FTMS 1.0) — extension Step Count uint24, voir ci-dessous |
///
/// Extension « Step Count » (bit 13, uint24) : absente de FTMS 1.0 (bits 13–15 réservés),
/// mais implémentée par la bibliothèque pyftms et utilisée par certains tapis.
/// Elle n'est décodée que si le bit est présent ; la valeur est marquée comme extension.
public struct TreadmillData: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let moreData = Flags(rawValue: 1 << 0)
        public static let averageSpeed = Flags(rawValue: 1 << 1)
        public static let totalDistance = Flags(rawValue: 1 << 2)
        public static let inclination = Flags(rawValue: 1 << 3)
        public static let elevationGain = Flags(rawValue: 1 << 4)
        public static let instantaneousPace = Flags(rawValue: 1 << 5)
        public static let averagePace = Flags(rawValue: 1 << 6)
        public static let expendedEnergy = Flags(rawValue: 1 << 7)
        public static let heartRate = Flags(rawValue: 1 << 8)
        public static let metabolicEquivalent = Flags(rawValue: 1 << 9)
        public static let elapsedTime = Flags(rawValue: 1 << 10)
        public static let remainingTime = Flags(rawValue: 1 << 11)
        public static let forceAndPower = Flags(rawValue: 1 << 12)
        /// Extension non standard (voir doc du type).
        public static let stepCountExtension = Flags(rawValue: 1 << 13)
        public static let reservedMask = Flags(rawValue: 0xC000)
    }

    public var flags: Flags = []
    public var instantaneousSpeedKmh: Double?
    public var averageSpeedKmh: Double?
    public var totalDistanceMeters: UInt32?
    public var inclinationPercent: Double?
    public var rampAngleDegrees: Double?
    public var positiveElevationGainMeters: Double?
    public var negativeElevationGainMeters: Double?
    public var instantaneousPaceKmPerMin: Double?
    public var averagePaceKmPerMin: Double?
    public var totalEnergyKcal: UInt16?
    public var energyPerHourKcal: UInt16?
    public var energyPerMinuteKcal: UInt8?
    public var heartRateBpm: UInt8?
    public var metabolicEquivalent: Double?
    public var elapsedTimeSeconds: UInt16?
    public var remainingTimeSeconds: UInt16?
    public var forceOnBeltNewtons: Int16?
    public var powerOutputWatts: Int16?
    public var stepCountExtension: UInt32?
    /// Octets restants non interprétés (signalés dans le diagnostic).
    public var trailingBytes: [UInt8] = []

    public init() {}

    /// Valeur « donnée non disponible » des champs signés inclinaison/angle (FTMS).
    static let sint16NotAvailable: Int16 = 0x7FFF

    /// Décodage strict : lève une erreur si le paquet est tronqué.
    public static func decode(_ bytes: [UInt8]) throws -> TreadmillData {
        let (data, error) = decodePartial(bytes)
        if let error { throw error }
        return data
    }

    /// Décodage tolérant : renvoie les champs complets lus avant la troncature,
    /// plus l'erreur éventuelle. Les champs incomplets ne sont jamais renvoyés.
    public static func decodePartial(_ bytes: [UInt8]) -> (TreadmillData, FTMSDecodeError?) {
        var out = TreadmillData()
        guard !bytes.isEmpty else { return (out, .empty) }
        var r = ByteReader(bytes)
        do {
            let flags = Flags(rawValue: try r.uint16("Flags"))
            out.flags = flags
            if !flags.contains(.moreData) {
                out.instantaneousSpeedKmh = Double(try r.uint16("Instantaneous Speed")) / 100
            }
            if flags.contains(.averageSpeed) {
                out.averageSpeedKmh = Double(try r.uint16("Average Speed")) / 100
            }
            if flags.contains(.totalDistance) {
                out.totalDistanceMeters = try r.uint24("Total Distance")
            }
            if flags.contains(.inclination) {
                let incl = try r.sint16("Inclination")
                let ramp = try r.sint16("Ramp Angle Setting")
                out.inclinationPercent = incl == sint16NotAvailable ? nil : Double(incl) / 10
                out.rampAngleDegrees = ramp == sint16NotAvailable ? nil : Double(ramp) / 10
            }
            if flags.contains(.elevationGain) {
                let pos = try r.uint16("Positive Elevation Gain")
                let neg = try r.uint16("Negative Elevation Gain")
                out.positiveElevationGainMeters = Double(pos) / 10
                out.negativeElevationGainMeters = Double(neg) / 10
            }
            if flags.contains(.instantaneousPace) {
                out.instantaneousPaceKmPerMin = Double(try r.uint8("Instantaneous Pace")) / 10
            }
            if flags.contains(.averagePace) {
                out.averagePaceKmPerMin = Double(try r.uint8("Average Pace")) / 10
            }
            if flags.contains(.expendedEnergy) {
                let total = try r.uint16("Total Energy")
                let perHour = try r.uint16("Energy Per Hour")
                let perMinute = try r.uint8("Energy Per Minute")
                out.totalEnergyKcal = total == 0xFFFF ? nil : total
                out.energyPerHourKcal = perHour == 0xFFFF ? nil : perHour
                out.energyPerMinuteKcal = perMinute == 0xFF ? nil : perMinute
            }
            if flags.contains(.heartRate) {
                let hr = try r.uint8("Heart Rate")
                out.heartRateBpm = hr == 0 ? nil : hr
            }
            if flags.contains(.metabolicEquivalent) {
                out.metabolicEquivalent = Double(try r.uint8("Metabolic Equivalent")) / 10
            }
            if flags.contains(.elapsedTime) {
                out.elapsedTimeSeconds = try r.uint16("Elapsed Time")
            }
            if flags.contains(.remainingTime) {
                out.remainingTimeSeconds = try r.uint16("Remaining Time")
            }
            if flags.contains(.forceAndPower) {
                let force = try r.sint16("Force on Belt")
                let power = try r.sint16("Power Output")
                out.forceOnBeltNewtons = force == sint16NotAvailable ? nil : force
                out.powerOutputWatts = power == sint16NotAvailable ? nil : power
            }
            if flags.contains(.stepCountExtension) {
                out.stepCountExtension = try r.uint24("Step Count (extension)")
            }
            out.trailingBytes = r.remainingBytes
            return (out, nil)
        } catch let e as FTMSDecodeError {
            return (out, e)
        } catch {
            return (out, .invalidValue(field: "?", detail: "\(error)"))
        }
    }

    /// Encodage selon les champs renseignés (utilisé par le simulateur et les tests).
    /// Le bit More Data est positionné si la vitesse instantanée est absente.
    public func encode() -> [UInt8] {
        var f: Flags = []
        if instantaneousSpeedKmh == nil { f.insert(.moreData) }
        if averageSpeedKmh != nil { f.insert(.averageSpeed) }
        if totalDistanceMeters != nil { f.insert(.totalDistance) }
        if inclinationPercent != nil || rampAngleDegrees != nil { f.insert(.inclination) }
        if positiveElevationGainMeters != nil || negativeElevationGainMeters != nil { f.insert(.elevationGain) }
        if instantaneousPaceKmPerMin != nil { f.insert(.instantaneousPace) }
        if averagePaceKmPerMin != nil { f.insert(.averagePace) }
        if totalEnergyKcal != nil || energyPerHourKcal != nil || energyPerMinuteKcal != nil { f.insert(.expendedEnergy) }
        if heartRateBpm != nil { f.insert(.heartRate) }
        if metabolicEquivalent != nil { f.insert(.metabolicEquivalent) }
        if elapsedTimeSeconds != nil { f.insert(.elapsedTime) }
        if remainingTimeSeconds != nil { f.insert(.remainingTime) }
        if forceOnBeltNewtons != nil || powerOutputWatts != nil { f.insert(.forceAndPower) }
        if stepCountExtension != nil { f.insert(.stepCountExtension) }

        var w = ByteWriter()
        w.uint16(f.rawValue)
        if let v = instantaneousSpeedKmh { w.uint16(clampedRound(v * 100, as: UInt16.self)) }
        if let v = averageSpeedKmh { w.uint16(clampedRound(v * 100, as: UInt16.self)) }
        if let v = totalDistanceMeters { w.uint24(min(v, 0xFFFFFF)) }
        if f.contains(.inclination) {
            w.sint16(inclinationPercent.map { clampedRound($0 * 10, as: Int16.self) } ?? Self.sint16NotAvailable)
            w.sint16(rampAngleDegrees.map { clampedRound($0 * 10, as: Int16.self) } ?? Self.sint16NotAvailable)
        }
        if f.contains(.elevationGain) {
            w.uint16(clampedRound((positiveElevationGainMeters ?? 0) * 10, as: UInt16.self))
            w.uint16(clampedRound((negativeElevationGainMeters ?? 0) * 10, as: UInt16.self))
        }
        if let v = instantaneousPaceKmPerMin { w.uint8(clampedRound(v * 10, as: UInt8.self)) }
        if let v = averagePaceKmPerMin { w.uint8(clampedRound(v * 10, as: UInt8.self)) }
        if f.contains(.expendedEnergy) {
            w.uint16(totalEnergyKcal ?? 0xFFFF)
            w.uint16(energyPerHourKcal ?? 0xFFFF)
            w.uint8(energyPerMinuteKcal ?? 0xFF)
        }
        if let v = heartRateBpm { w.uint8(v) }
        if let v = metabolicEquivalent { w.uint8(clampedRound(v * 10, as: UInt8.self)) }
        if let v = elapsedTimeSeconds { w.uint16(v) }
        if let v = remainingTimeSeconds { w.uint16(v) }
        if f.contains(.forceAndPower) {
            w.sint16(forceOnBeltNewtons ?? Self.sint16NotAvailable)
            w.sint16(powerOutputWatts ?? Self.sint16NotAvailable)
        }
        if let v = stepCountExtension { w.uint24(min(v, 0xFFFFFF)) }
        return w.bytes
    }
}
