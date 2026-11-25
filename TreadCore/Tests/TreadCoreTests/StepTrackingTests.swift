import XCTest
@testable import TreadCore

/// Pas sur le Domyos RUN100 (aucun pas fourni par le tapis : la montre compte).
final class StepTrackingTests: XCTestCase {
    // MARK: - Messages de la montre

    /// Retard Bluetooth puis rafale : datés à leur mesure, aucun pas n'est perdu
    /// (avant : 990 comptés sur 1 020).
    func testWatchBurstAfterDelayLosesNoSteps() {
        var s = StepTracker(estimationEnabled: false)
        var t = 0.0, total = 0.0
        for _ in 0..<60 { total += 15; s.ingestWatch(total: total, at: t, receivedAt: t); t += 5 }
        let delayedAt = t + 30
        for _ in 0..<7 { total += 15; s.ingestWatch(total: total, at: t, receivedAt: delayedAt); t += 5 }
        XCTAssertEqual(s.value, Int(total))
        XCTAssertEqual(s.anomalies, 0)
    }

    /// Total complété après coup sous la même heure de mesure : les réceptions espacées suffisent.
    func testWatchTotalUpdatedUnderSameSampleDate() {
        var s = StepTracker(estimationEnabled: false)
        s.ingestWatch(total: 100, at: 10, receivedAt: 10)
        s.ingestWatch(total: 130, at: 10, receivedAt: 20)
        XCTAssertEqual(s.value, 130)
        XCTAssertEqual(s.anomalies, 0)
    }

    /// Message plus ancien reçu après un plus récent : ignoré, pas de baisse ni de double compte.
    func testOutOfOrderWatchMessageIgnored() {
        var s = StepTracker(estimationEnabled: false)
        s.ingestWatch(total: 100, at: 10)
        s.ingestWatch(total: 130, at: 20)
        s.ingestWatch(total: 115, at: 15)
        s.ingestWatch(total: 145, at: 25)
        XCTAssertEqual(s.value, 145)
    }

    /// Un vrai saut impossible (pas d'un autre appareil ajoutés en bloc) reste ignoré.
    func testImpossibleWatchJumpStillIgnored() {
        var s = StepTracker(estimationEnabled: false)
        s.ingestWatch(total: 100, at: 10, receivedAt: 10)
        s.ingestWatch(total: 2100, at: 12, receivedAt: 12)
        XCTAssertEqual(s.value, 100)
        XCTAssertEqual(s.anomalies, 1)
    }

    /// Dans la séance : l'ancienneté de la mesure transmise par la montre date le total.
    func testSessionUsesWatchSampleAge() {
        let h = SessionHarness(program: nil)
        var total = 0.0
        for _ in 0..<20 { total += 15; h.session.ingestWatchSteps(total: total, sampleAge: 0); h.h.now += 5 }
        // 25 s sans message, puis 3 mesures reçues ensemble.
        h.h.now += 25
        for age in [10.0, 5, 0] { total += 15; h.session.ingestWatchSteps(total: total, sampleAge: age) }
        XCTAssertEqual(h.session.steps.value, Int(total))
        XCTAssertEqual(h.session.steps.anomalies, 0)
    }

    // MARK: - Choix de la source

    /// Tapis qui envoie le champ de pas figé à 0 : la montre compte quand même.
    func testFrozenZeroTreadmillDoesNotMaskWatch() {
        var s = StepTracker(estimationEnabled: false)
        for i in 0..<300 {
            s.ingestTreadmill(raw: 0, at: Double(i))
            s.ingestWatch(total: Double(i * 3), at: Double(i) + 0.5)
        }
        XCTAssertEqual(s.source, .appleWatch)
        XCTAssertEqual(s.value, 897)
    }

    /// Compteur du tapis qui avance après la montre, dans les 2 premières minutes : le tapis
    /// (prioritaire) prend la main avec son propre total, sans addition.
    func testTreadmillTakesOverEarly() {
        var s = StepTracker(estimationEnabled: false)
        s.ingestWatch(total: 30, at: 10)
        XCTAssertEqual(s.source, .appleWatch)
        s.ingestTreadmill(raw: 500, at: 30)
        s.ingestTreadmill(raw: 512, at: 34)
        XCTAssertEqual(s.source, .treadmill)
        XCTAssertEqual(s.value, 12)
    }

    /// Passé 2 minutes, la source ne change plus.
    func testNoTakeoverAfterWindow() {
        var s = StepTracker(estimationEnabled: false)
        s.ingestWatch(total: 30, at: 10)
        s.ingestTreadmill(raw: 500, at: 200)
        s.ingestTreadmill(raw: 512, at: 204)
        XCTAssertEqual(s.source, .appleWatch)
        XCTAssertEqual(s.value, 30)
    }

    /// Estimation activée et montre relancée à 40 s : la montre remplace l'estimation
    /// (avant : l'estimation restait la source de toute la séance).
    func testLateWatchReplacesEstimation() {
        var s = StepTracker(estimationEnabled: true)
        for i in 0..<40 { s.ingestDistance(deltaMeters: 2.4, speedKmh: 8.6, at: Double(i)) }
        XCTAssertEqual(s.source, .estimated)
        s.ingestWatch(total: 120, at: 40)
        s.ingestWatch(total: 135, at: 45)
        XCTAssertEqual(s.source, .appleWatch)
        XCTAssertEqual(s.value, 135)
    }

    // MARK: - Estimation selon la vitesse

    func testStepModel() {
        XCTAssertEqual(StepModel.stepLength(speedKmh: 5, walkingStepLength: 0.7), 0.70, accuracy: 0.001)
        XCTAssertEqual(StepModel.stepLength(speedKmh: 9, walkingStepLength: 0.7), 0.98, accuracy: 0.01)
        XCTAssertEqual(StepModel.stepLength(speedKmh: 12, walkingStepLength: 0.7), 1.24, accuracy: 0.01)
        XCTAssertEqual(StepModel.stepLength(speedKmh: 9, walkingStepLength: 0.8),
                       StepModel.stepLength(speedKmh: 9, walkingStepLength: 0.7) * 0.8 / 0.7, accuracy: 0.001)
        var last = 0.0
        for v in stride(from: 2.0, through: 14, by: 0.5) {
            let l = StepModel.stepLength(speedKmh: v, walkingStepLength: 0.7)
            XCTAssertGreaterThan(l, 0.3)
            XCTAssertLessThan(l, 1.5)
            if v < 7 || v > 7 { XCTAssertGreaterThan(l, last * 0.9, "\(v) km/h") }
            last = l
        }
    }

    /// 1 km à 9 km/h : ≈ 1 025 pas estimés (avant, longueur fixe 0,70 m : 1 428).
    func testEstimationFollowsSpeed() {
        var s = StepTracker(estimationEnabled: true)
        for i in 0..<400 { s.ingestDistance(deltaMeters: 2.5, speedKmh: 9, at: Double(i)) }
        XCTAssertEqual(s.source, .estimated)
        XCTAssertEqual(Double(s.value ?? 0), 1025, accuracy: 5)
    }

    // MARK: - Cohérence pas / distance

    private func record(steps: Int, source: MetricSource, speed: Double = 8.5, minutes: Int = 30) -> SessionRecord {
        var r = SessionRecord(startDate: Date(timeIntervalSince1970: 0), program: nil, treadmillName: nil, profileID: nil, simulated: false)
        var d = 0.0
        for i in 0...(minutes * 60) {
            r.samples.append(SessionSample(t: Double(i), active: Double(i), speed: speed, incline: nil, targetSpeed: speed,
                                           targetIncline: nil, hr: nil, hrSource: nil, zone: nil, distance: d,
                                           steps: nil, phase: nil, paused: false))
            d += speed / 3.6
        }
        r.distanceMeters = r.samples.last!.distance
        r.steps = steps
        r.stepsSource = source
        return r
    }

    func testStepCheckPlausibleRun() throws {
        // 30 min à 8,5 km/h : ≈ 4 250 m, ≈ 4 575 pas attendus (≈ 153 pas/min).
        let c = try XCTUnwrap(record(steps: 4600, source: .appleWatch).stepCheck(walkingStepLength: 0.7))
        XCTAssertEqual(c.verdict, .plausible)
        XCTAssertNil(c.warning)
        XCTAssertEqual(Double(c.expectedSteps), 4575, accuracy: 10)
    }

    func testStepCheckFlagsUndercountingWatch() throws {
        let c = try XCTUnwrap(record(steps: 2500, source: .appleWatch).stepCheck(walkingStepLength: 0.7))
        XCTAssertEqual(c.verdict, .tooFew)
        XCTAssertTrue(c.warning?.contains("poignées") == true)
        XCTAssertEqual(c.stepLengthMeters, 4250.0 / 2500, accuracy: 0.01)
    }

    func testStepCheckFlagsTooMany() throws {
        let c = try XCTUnwrap(record(steps: 7500, source: .appleWatch).stepCheck(walkingStepLength: 0.7))
        XCTAssertEqual(c.verdict, .tooMany)
    }

    func testStepCheckSkipsEstimatedAndShortSessions() {
        XCTAssertNil(record(steps: 2500, source: .estimated).stepCheck(walkingStepLength: 0.7))
        XCTAssertNil(record(steps: 100, source: .appleWatch, minutes: 2).stepCheck(walkingStepLength: 0.7))
    }
}
