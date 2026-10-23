import XCTest
@testable import TreadCore

final class FTMSDecodingTests: XCTestCase {

    func testTreadmillDataSpeedOnly() throws {
        // Flags 0x0000 : seule la vitesse instantanée (bit 0 = 0 ⇒ présente). 7,00 km/h = 700 = 0x02BC
        let d = try TreadmillData.decode([0x00, 0x00, 0xBC, 0x02])
        XCTAssertEqual(d.instantaneousSpeedKmh, 7.0)
        XCTAssertNil(d.totalDistanceMeters)
        XCTAssertTrue(d.trailingBytes.isEmpty)
    }

    func testMoreDataBitMeansNoInstantaneousSpeed() throws {
        // Flags 0x0005 : More Data (bit0=1) + Total Distance (bit2). Distance 1234 m = 0x0004D2
        let d = try TreadmillData.decode([0x05, 0x00, 0xD2, 0x04, 0x00])
        XCTAssertNil(d.instantaneousSpeedKmh)
        XCTAssertEqual(d.totalDistanceMeters, 1234)
    }

    func testTypicalTreadmillPacket() throws {
        // Flags = distance(2) | inclinaison(3) | énergie(7) | temps écoulé(10) = 0x048C
        var b: [UInt8] = [0x8C, 0x04]
        b += [0x2C, 0x01]             // vitesse 3,00 km/h
        b += [0x64, 0x00, 0x00]       // distance 100 m
        b += [0x1E, 0x00, 0xFF, 0x7F] // inclinaison 3,0 %, angle non disponible
        b += [0x0A, 0x00, 0xFF, 0xFF, 0xFF] // 10 kcal, /h et /min non disponibles
        b += [0x3C, 0x00]             // 60 s
        let d = try TreadmillData.decode(b)
        XCTAssertEqual(d.instantaneousSpeedKmh, 3.0)
        XCTAssertEqual(d.totalDistanceMeters, 100)
        XCTAssertEqual(d.inclinationPercent, 3.0)
        XCTAssertNil(d.rampAngleDegrees)
        XCTAssertEqual(d.totalEnergyKcal, 10)
        XCTAssertNil(d.energyPerHourKcal)
        XCTAssertNil(d.energyPerMinuteKcal)
        XCTAssertEqual(d.elapsedTimeSeconds, 60)
    }

    func testNegativeInclination() throws {
        // -2,5 % = -25 = 0xFFE7
        let d = try TreadmillData.decode([0x08, 0x00, 0x00, 0x00, 0xE7, 0xFF, 0x00, 0x00])
        XCTAssertEqual(d.inclinationPercent, -2.5)
        XCTAssertEqual(d.rampAngleDegrees, 0)
    }

    func testAllOptionalFieldsRoundTrip() throws {
        var d = TreadmillData()
        d.instantaneousSpeedKmh = 6.45
        d.averageSpeedKmh = 5.5
        d.totalDistanceMeters = 0x123456
        d.inclinationPercent = 4
        d.rampAngleDegrees = 2.3
        d.positiveElevationGainMeters = 12.3
        d.negativeElevationGainMeters = 0
        d.instantaneousPaceKmPerMin = 0.1
        d.averagePaceKmPerMin = 0.2
        d.totalEnergyKcal = 150
        d.energyPerHourKcal = 400
        d.energyPerMinuteKcal = 7
        d.heartRateBpm = 132
        d.metabolicEquivalent = 5.4
        d.elapsedTimeSeconds = 1800
        d.remainingTimeSeconds = 600
        d.forceOnBeltNewtons = -12
        d.powerOutputWatts = 210
        d.stepCountExtension = 4321
        let bytes = d.encode()
        var decoded = try TreadmillData.decode(bytes)
        XCTAssertEqual(decoded.flags.rawValue, 0x3FFE)
        decoded.flags = []
        var expected = d
        expected.flags = []
        XCTAssertEqual(decoded, expected)
    }

    func testTruncatedPacketReportsFieldAndKeepsCompletePrefix() {
        // Flags annoncent distance + inclinaison, mais l'inclinaison est tronquée.
        let bytes: [UInt8] = [0x0C, 0x00, 0x2C, 0x01, 0x64, 0x00, 0x00, 0x1E]
        XCTAssertThrowsError(try TreadmillData.decode(bytes)) { error in
            guard case let FTMSDecodeError.truncated(field, needed, available) = error else {
                return XCTFail("mauvaise erreur \(error)")
            }
            XCTAssertEqual(field, "Inclination")
            XCTAssertEqual(needed, 2)
            XCTAssertEqual(available, 1)
        }
        let (partial, err) = TreadmillData.decodePartial(bytes)
        XCTAssertNotNil(err)
        XCTAssertEqual(partial.instantaneousSpeedKmh, 3.0)
        XCTAssertEqual(partial.totalDistanceMeters, 100)
        XCTAssertNil(partial.inclinationPercent)
    }

    func testEmptyAndOneBytePackets() {
        XCTAssertThrowsError(try TreadmillData.decode([]))
        XCTAssertThrowsError(try TreadmillData.decode([0x00]))
        XCTAssertThrowsError(try TreadmillData.decode([0x00, 0x00, 0x10]))
    }

    func testTrailingBytesAreReported() throws {
        let d = try TreadmillData.decode([0x00, 0x00, 0x10, 0x00, 0xAA, 0xBB])
        XCTAssertEqual(d.instantaneousSpeedKmh, 0.16)
        XCTAssertEqual(d.trailingBytes, [0xAA, 0xBB])
    }

    func testRanges() throws {
        // 1,00–12,00 km/h pas 0,10 ; 0–9 % pas 1 %
        let s = try SpeedRange.decode([0x64, 0x00, 0xB0, 0x04, 0x0A, 0x00])
        XCTAssertEqual(s, SpeedRange(minKmh: 1, maxKmh: 12, incrementKmh: 0.1))
        let i = try InclinationRange.decode([0x00, 0x00, 0x5A, 0x00, 0x0A, 0x00])
        XCTAssertEqual(i, InclinationRange(minPercent: 0, maxPercent: 9, incrementPercent: 1))
        let neg = try InclinationRange.decode(InclinationRange(minPercent: -3, maxPercent: 15, incrementPercent: 0.5).encode())
        XCTAssertEqual(neg.minPercent, -3)
        XCTAssertThrowsError(try SpeedRange.decode([0x64, 0x00]))
        XCTAssertThrowsError(try SpeedRange.decode([0xB0, 0x04, 0x64, 0x00, 0x0A, 0x00]))
    }

    func testFeatureDecode() throws {
        // Machine : distance(2) + inclinaison(3) + énergie(9) ; cibles : vitesse(0) + inclinaison(1)
        let f = try FitnessMachineFeature.decode([0x0C, 0x02, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00])
        XCTAssertTrue(f.machine.contains(.totalDistance))
        XCTAssertTrue(f.machine.contains(.inclination))
        XCTAssertTrue(f.machine.contains(.expendedEnergy))
        XCTAssertFalse(f.machine.contains(.stepCount))
        XCTAssertTrue(f.targetSettings.contains(.speed))
        XCTAssertTrue(f.targetSettings.contains(.inclination))
        XCTAssertThrowsError(try FitnessMachineFeature.decode([0x0C, 0x02, 0x00, 0x00]))
    }

    func testControlPointEncoding() {
        XCTAssertEqual(ControlCommand.requestControl.encode(), [0x00])
        XCTAssertEqual(ControlCommand.setTargetSpeed(kmh: 7.0).encode(), [0x02, 0xBC, 0x02])
        XCTAssertEqual(ControlCommand.setTargetSpeed(kmh: 1.5).encode(), [0x02, 0x96, 0x00])
        XCTAssertEqual(ControlCommand.setTargetInclination(percent: 3).encode(), [0x03, 0x1E, 0x00])
        XCTAssertEqual(ControlCommand.setTargetInclination(percent: -1.5).encode(), [0x03, 0xF1, 0xFF])
        XCTAssertEqual(ControlCommand.startOrResume.encode(), [0x07])
        XCTAssertEqual(ControlCommand.stop.encode(), [0x08, 0x01])
        XCTAssertEqual(ControlCommand.pause.encode(), [0x08, 0x02])
        // Arrondi correct : 6.95 * 100 = 694.999…
        XCTAssertEqual(ControlCommand.setTargetSpeed(kmh: 6.95).encode(), [0x02, 0xB7, 0x02])
    }

    func testControlPointResponse() throws {
        let r = try ControlPointResponse.decode([0x80, 0x02, 0x01])
        XCTAssertEqual(r.requestOpCode, 0x02)
        XCTAssertEqual(r.result, .success)
        let n = try ControlPointResponse.decode([0x80, 0x07, 0x05])
        XCTAssertEqual(n.result, .controlNotPermitted)
        XCTAssertEqual(try ControlPointResponse.decode([0x80, 0x00, 0x09]).result, .unknown(0x09))
        XCTAssertThrowsError(try ControlPointResponse.decode([0x05, 0x02, 0x01]))
        XCTAssertThrowsError(try ControlPointResponse.decode([0x80, 0x02]))
    }

    func testMachineStatus() throws {
        XCTAssertEqual(try MachineStatus.decode([0x05, 0xBC, 0x02]), .targetSpeedChanged(kmh: 7))
        XCTAssertEqual(try MachineStatus.decode([0x06, 0x1E, 0x00]), .targetInclinationChanged(percent: 3))
        XCTAssertEqual(try MachineStatus.decode([0x02, 0x01]), .stoppedOrPausedByUser(paused: false))
        XCTAssertEqual(try MachineStatus.decode([0x02, 0x02]), .stoppedOrPausedByUser(paused: true))
        XCTAssertEqual(try MachineStatus.decode([0x03]), .stoppedBySafetyKey)
        XCTAssertEqual(try MachineStatus.decode([0xFF]), .controlPermissionLost)
        XCTAssertEqual(try MachineStatus.decode([0x0C, 0x01]), .other(opCode: 0x0C, parameters: [0x01]))
        XCTAssertThrowsError(try MachineStatus.decode([0x05, 0xBC]))
    }

    func testHeartRateMeasurement() throws {
        XCTAssertEqual(try HeartRateMeasurement.decode([0x00, 0x48]).bpm, 72)
        let m16 = try HeartRateMeasurement.decode([0x01, 0x2C, 0x01])
        XCTAssertEqual(m16.bpm, 300)
        XCTAssertFalse(m16.isUsable)
        let contact = try HeartRateMeasurement.decode([0x16, 0x8C, 0x00, 0x04])
        XCTAssertEqual(contact.bpm, 140)
        XCTAssertEqual(contact.contact, .detected)
        XCTAssertEqual(contact.rrIntervalsSeconds, [1.0])
        let noContact = try HeartRateMeasurement.decode([0x04, 0x50])
        XCTAssertEqual(noContact.contact, .notDetected)
        XCTAssertFalse(noContact.isUsable)
        let energy = try HeartRateMeasurement.decode([0x08, 0x50, 0x10, 0x00])
        XCTAssertEqual(energy.energyExpendedKJ, 16)
        XCTAssertThrowsError(try HeartRateMeasurement.decode([0x01, 0x50]))
    }

    func testCapabilitiesSnapping() {
        let caps = TreadmillProfile.urtm047.fallbackCapabilities
        XCTAssertEqual(caps.snapSpeed(7.04), 7.0)
        XCTAssertEqual(caps.snapSpeed(0.2), 1.0)
        XCTAssertEqual(caps.snapSpeed(15), 12.0)
        XCTAssertEqual(caps.snapInclination(3.4), 3)
        XCTAssertEqual(caps.snapInclination(12), 9)
        XCTAssertTrue(TreadmillCapabilities.isOnIncrement(7.1, min: 1, step: 0.1))
        XCTAssertFalse(TreadmillCapabilities.isOnIncrement(7.05, min: 1, step: 0.1))
    }

    func testProfileMatching() {
        XCTAssertEqual(TreadmillProfile.match(deviceName: "URTM047").id, "urevo-urtm047")
        XCTAssertEqual(TreadmillProfile.match(deviceName: "urtm047-AB12").id, "urevo-urtm047")
        XCTAssertEqual(TreadmillProfile.match(deviceName: "KS-ST-A1P").id, "generic-ftms")
        XCTAssertEqual(TreadmillProfile.match(deviceName: nil).id, "generic-ftms")
        let p = TreadmillProfile.urtm047
        XCTAssertEqual(p.initialSpeed(target: 7, capabilities: p.fallbackCapabilities), 1.0)
        XCTAssertEqual(p.initialSpeed(target: 1.2, capabilities: p.fallbackCapabilities), 1.0)
    }
}
