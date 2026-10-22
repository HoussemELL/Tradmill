import Foundation

/// Heart Rate Measurement (0x2A37), Heart Rate Service 0x180D.
///
/// Flags (uint8) :
/// - bit 0 : format FC (0 = uint8, 1 = uint16)
/// - bits 1-2 : contact capteur (bit 2 = fonction supportée, bit 1 = contact détecté)
/// - bit 3 : Energy Expended présent (uint16, kJ)
/// - bit 4 : RR-Interval(s) présent(s) (uint16, 1/1024 s chacun)
public struct HeartRateMeasurement: Equatable, Sendable {
    public enum SensorContact: Equatable, Sendable {
        case notSupported, notDetected, detected
    }

    public var bpm: Int
    public var contact: SensorContact
    public var energyExpendedKJ: Int?
    public var rrIntervalsSeconds: [Double]

    public init(bpm: Int, contact: SensorContact = .notSupported, energyExpendedKJ: Int? = nil, rrIntervalsSeconds: [Double] = []) {
        self.bpm = bpm
        self.contact = contact
        self.energyExpendedKJ = energyExpendedKJ
        self.rrIntervalsSeconds = rrIntervalsSeconds
    }

    public static func decode(_ bytes: [UInt8]) throws -> HeartRateMeasurement {
        var r = ByteReader(bytes)
        let flags = try r.uint8("Flags")
        let bpm: Int = (flags & 0x01) != 0 ? Int(try r.uint16("Heart Rate (uint16)")) : Int(try r.uint8("Heart Rate (uint8)"))
        let contact: SensorContact
        if flags & 0x04 == 0 {
            contact = .notSupported
        } else {
            contact = (flags & 0x02) != 0 ? .detected : .notDetected
        }
        var energy: Int?
        if flags & 0x08 != 0 { energy = Int(try r.uint16("Energy Expended")) }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while r.remaining >= 2 {
                rr.append(Double(try r.uint16("RR-Interval")) / 1024)
            }
        }
        return HeartRateMeasurement(bpm: bpm, contact: contact, energyExpendedKJ: energy, rrIntervalsSeconds: rr)
    }

    public func encode(use16Bit: Bool = false) -> [UInt8] {
        var flags: UInt8 = use16Bit ? 0x01 : 0
        switch contact {
        case .notSupported: break
        case .notDetected: flags |= 0x04
        case .detected: flags |= 0x06
        }
        if energyExpendedKJ != nil { flags |= 0x08 }
        if !rrIntervalsSeconds.isEmpty { flags |= 0x10 }
        var w = ByteWriter()
        w.uint8(flags)
        if use16Bit { w.uint16(UInt16(clamping: bpm)) } else { w.uint8(UInt8(clamping: bpm)) }
        if let e = energyExpendedKJ { w.uint16(UInt16(clamping: e)) }
        for rr in rrIntervalsSeconds { w.uint16(clampedRound(rr * 1024, as: UInt16.self)) }
        return w.bytes
    }

    /// Une mesure est exploitable si la FC est plausible et que le capteur
    /// ne signale pas explicitement l'absence de contact.
    public var isUsable: Bool {
        bpm >= 25 && bpm <= 250 && contact != .notDetected
    }
}
