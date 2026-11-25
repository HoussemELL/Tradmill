import XCTest
@testable import TreadCore

/// Journal du 25/11 sur le Domyos RUN100 : distance par paliers de 10 m, liaison montre.
final class RUN100DistanceTests: XCTestCase {
    /// Paquets 4 fois par seconde, distance +10 m toutes les 12 s (3 km/h) : chaque palier
    /// était rejeté comme un saut (10 > 4,5 × 1 + 5). Il doit être compté.
    func testTenMeterStepsEveryTwelveSecondsAreCounted() {
        var c = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 4.5)
        var t = 0.0, raw: UInt64 = 0
        var anomalies = 0
        for i in 0..<(4 * 180) {            // 3 min
            if i > 0, i % 48 == 0 { raw += 10 }  // +10 m toutes les 12 s
            if c.ingest(raw, at: t) != nil { anomalies += 1 }
            t += 0.25
        }
        XCTAssertEqual(anomalies, 0)
        XCTAssertEqual(c.sessionTotal, 140)
    }

    /// 5 km/h : +10 m toutes les 7 s.
    func testTenMeterStepsAtFiveKmh() {
        var c = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 4.5)
        var t = 0.0, raw: UInt64 = 0
        for i in 0..<(4 * 70) {
            if i > 0, i % 28 == 0 { raw += 10 }
            XCTAssertNil(c.ingest(raw, at: t))
            t += 0.25
        }
        XCTAssertEqual(c.sessionTotal, 90)
    }

    /// Un vrai saut reste rejeté, même après une valeur restée longtemps identique.
    func testRealJumpStillRejected() {
        var c = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 4.5)
        c.ingest(100, at: 0)
        for i in 1...40 { c.ingest(100, at: Double(i) * 0.25) }   // 10 s sans changement
        XCTAssertEqual(c.ingest(5000, at: 10.25), .implausibleJump(from: 100, to: 5000))
        XCTAssertEqual(c.sessionTotal, 0)
    }

    /// Séance RUN100 : la distance du tapis est retenue (plus « figée, intégrée depuis la vitesse »).
    func testSessionUsesQuantizedTreadmillDistance() {
        var settings = SessionSettings()
        settings.weightKg = 70
        let t = SimulatedTreadmill(quirks: SimulatedTreadmill.Quirks(),
                                   speedRange: SpeedRange(minKmh: 1, maxKmh: 14, incrementKmh: 0.1), inclinationRange: nil)
        let s = SessionHarness(program: nil, settings: settings, profile: .domyosRun100, treadmill: t)
        _ = s.session.start()
        // Distance du tapis arrondie à 10 m, comme le RUN100.
        s.h.controller.onTelemetry = { [unowned s] d, now in
            var q = d
            if let m = d.totalDistanceMeters { q.totalDistanceMeters = m / 10 * 10 }
            s.session.handleTelemetry(q, at: now)
        }
        s.run(120)
        XCTAssertEqual(s.session.distanceSource, .treadmill)
        XCTAssertGreaterThan(s.session.distanceMeters, 60)
    }
}

final class WatchLinkPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 25/11 : miroir reçu à l'ouverture de Foulée, aucun message d'exercice ensuite → périmé.
    func testMirrorWithoutWorkoutMessagesIsStale() {
        XCTAssertTrue(WatchLinkPolicy.isMirrorLive(attachedAt: t0, lastWorkoutMessageAt: nil, now: t0 + 3))
        XCTAssertFalse(WatchLinkPolicy.isMirrorLive(attachedAt: t0, lastWorkoutMessageAt: nil, now: t0 + 7))
        // Message antérieur au miroir (séance précédente) : ne compte pas.
        XCTAssertFalse(WatchLinkPolicy.isMirrorLive(attachedAt: t0, lastWorkoutMessageAt: t0 - 60, now: t0 + 7))
    }

    func testMirrorWithRecentMessagesIsLive() {
        XCTAssertTrue(WatchLinkPolicy.isMirrorLive(attachedAt: t0, lastWorkoutMessageAt: t0 + 100, now: t0 + 110))
        XCTAssertFalse(WatchLinkPolicy.isMirrorLive(attachedAt: t0, lastWorkoutMessageAt: t0 + 100, now: t0 + 125))
    }

    func testConnectivityBackup() {
        // Trop tôt, ou pas de FC sur la montre : rien.
        XCTAssertFalse(WatchLinkPolicy.needsConnectivityBackup(workoutElapsed: 10, watchHasHeartRate: true, phoneWatchHeartRateAge: nil))
        XCTAssertFalse(WatchLinkPolicy.needsConnectivityBackup(workoutElapsed: 60, watchHasHeartRate: false, phoneWatchHeartRateAge: nil))
        // L'iPhone n'a jamais reçu la FC, ou plus depuis 15 s : envoi doublé.
        XCTAssertTrue(WatchLinkPolicy.needsConnectivityBackup(workoutElapsed: 25, watchHasHeartRate: true, phoneWatchHeartRateAge: nil))
        XCTAssertTrue(WatchLinkPolicy.needsConnectivityBackup(workoutElapsed: 300, watchHasHeartRate: true, phoneWatchHeartRateAge: 40))
        XCTAssertFalse(WatchLinkPolicy.needsConnectivityBackup(workoutElapsed: 300, watchHasHeartRate: true, phoneWatchHeartRateAge: 3))
    }

    func testWatchLogMessageRoundTrip() throws {
        let m = WatchMessage.watchLog("miroir perdu")
        XCTAssertEqual(try WatchMessage.decode(m.encoded()), m)
    }

    /// L'iPhone indique à la montre l'ancienneté de la dernière FC reçue pendant la séance.
    func testLiveStatusCarriesWatchHeartRateAge() throws {
        let s = SessionHarness(program: nil)
        _ = s.session.start()
        s.run(30)
        XCTAssertNil(WatchLiveStatus.make(session: s.session, now: s.h.now, date: Date()).watchHeartRateAge)
        s.hr.ingest(HeartRateReading(bpm: 120, receivedAt: s.h.now - 2, source: .appleWatch))
        let age = try XCTUnwrap(WatchLiveStatus.make(session: s.session, now: s.h.now, date: Date()).watchHeartRateAge)
        XCTAssertEqual(age, 2, accuracy: 0.01)
        // Ancien état en direct (sans le champ) toujours lisible.
        let st = WatchLiveStatus.make(session: s.session, now: s.h.now, date: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(st)) as? [String: Any])
        json.removeValue(forKey: "watchHeartRateAge")
        let old = try JSONDecoder().decode(WatchLiveStatus.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.watchHeartRateAge)
    }
}
