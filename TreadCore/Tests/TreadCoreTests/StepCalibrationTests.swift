import XCTest
@testable import TreadCore

final class StepCalibrationTests: XCTestCase {
    /// Séance de `minutes` à `speed` km/h ; pas de la montre (série) à `stepsPerMeter` pas/m.
    private func record(speed: Double = 5, minutes: Int = 20, stepsPerMeter: Double?, paused: ClosedRange<Int>? = nil,
                        source: MetricSource = .appleWatch) -> SessionRecord {
        var r = SessionRecord(startDate: Date(timeIntervalSince1970: 1_800_000_000), program: nil, treadmillName: nil,
                              profileID: nil, simulated: false)
        var d = 0.0
        for i in 0...(minutes * 60) {
            let isPaused = paused?.contains(i) ?? false
            r.samples.append(SessionSample(t: Double(i), active: Double(i), speed: speed, incline: nil, targetSpeed: speed,
                                           targetIncline: nil, hr: nil, hrSource: nil, zone: nil, distance: d,
                                           steps: stepsPerMeter.map { Int(d * $0) }, phase: nil, paused: isPaused))
            if !isPaused { d += speed / 3.6 }
        }
        r.distanceMeters = r.samples.last!.distance
        r.steps = stepsPerMeter.map { Int(r.distanceMeters * $0) }
        r.stepsSource = stepsPerMeter == nil ? .none : source
        return r
    }

    // MARK: - Apprentissage

    /// Foulée réelle 0,80 m à 5 km/h (modèle de base : 0,70 m) : appris, facteur ≈ 1,14.
    func testLearnsLongerWalkingStride() throws {
        var c = StepCalibration()
        let r = record(stepsPerMeter: 1 / 0.80)
        XCTAssertTrue(c.learn(from: r, measuredSteps: r.steps!))
        let walk = try XCTUnwrap(c.walk)
        XCTAssertEqual(walk.factor, 0.80 / 0.70, accuracy: 0.01)
        XCTAssertNil(c.run)
        XCTAssertEqual(c.learnedStepLength(speedKmh: 5) ?? 0, 0.80, accuracy: 0.01)
        XCTAssertFalse(c.learn(from: r, measuredSteps: r.steps!), "même séance : jamais deux fois")
    }

    /// Montre qui sous-compte (mains sur les poignées) : la séance n'est pas apprise.
    func testUndercountingSessionIsNotLearned() {
        var c = StepCalibration()
        let r = record(stepsPerMeter: 1 / 1.3)
        XCTAssertFalse(c.learn(from: r, measuredSteps: r.steps!))
        XCTAssertTrue(c.isEmpty)
    }

    /// La course s'apprend à part ; la marche reprend l'autre allure tant qu'elle n'est pas apprise.
    func testRunBandAndFallbackToOtherBand() throws {
        var c = StepCalibration()
        let run = record(speed: 9, stepsPerMeter: 1 / 1.05)
        XCTAssertTrue(c.learn(from: run, measuredSteps: run.steps!))
        XCTAssertNotNil(c.run)
        XCTAssertNil(c.walk)
        XCTAssertEqual(c.stepLength(speedKmh: 9, walkingStepLength: 0.7), 1.05, accuracy: 0.01)
        // Marche non apprise : facteur de la course plutôt que le réglage.
        XCTAssertEqual(c.stepLength(speedKmh: 5, walkingStepLength: 0.6), 0.70 * c.run!.factor, accuracy: 0.01)
    }

    /// Plusieurs séances : moyenne pondérée par la distance.
    func testWeightedAverage() throws {
        var c = StepCalibration()
        let a = record(minutes: 20, stepsPerMeter: 1 / 0.70)
        let b = record(minutes: 20, stepsPerMeter: 1 / 0.80)
        c.learn(from: a, measuredSteps: a.steps!)
        c.learn(from: b, measuredSteps: b.steps!)
        XCTAssertEqual(try XCTUnwrap(c.walk).factor, (1.0 + 0.80 / 0.70) / 2, accuracy: 0.01)
        XCTAssertEqual(c.walk?.sessions, 2)
    }

    // MARK: - Choix final des pas

    /// Montre à 55 % des pas attendus : remplacés par distance ÷ longueur de pas, compte montre gardé.
    func testUndercountReplacedByEstimate() throws {
        let r = record(stepsPerMeter: 0.55 / 0.70)
        let f = StepReconciliation.finalize(r, healthWatchSteps: nil, calibration: StepCalibration(), walkingStepLength: 0.7)
        XCTAssertEqual(f.stepsSource, .estimated)
        XCTAssertEqual(f.stepsReplacedUndercount, true)
        XCTAssertEqual(f.watchSteps, r.steps)
        XCTAssertEqual(Double(f.steps ?? 0), r.distanceMeters / 0.70, accuracy: 3)
        XCTAssertTrue(f.stepsSourceLabel.contains("sous-comptait"))
    }

    /// Santé complète un total en direct coupé par la liaison : le plus grand est retenu.
    func testHealthCompletesLiveTotal() {
        var r = record(stepsPerMeter: 1 / 0.70)
        let full = r.steps!
        r.steps = full / 3   // liaison coupée : seulement un tiers reçu en direct
        let f = StepReconciliation.finalize(r, healthWatchSteps: full, calibration: StepCalibration(), walkingStepLength: 0.7)
        XCTAssertEqual(f.steps, full)
        XCTAssertEqual(f.stepsSource, .appleWatch)
        XCTAssertEqual(f.watchStepsFromHealth, true)
        XCTAssertEqual(f.stepsSourceLabel, "Apple Watch (Santé)")
    }

    /// Aucun pas reçu en direct (estimation), mais Santé a ceux de la montre : ils remplacent l'estimation.
    func testHealthStepsReplaceLiveEstimate() {
        var r = record(stepsPerMeter: 1 / 0.70)
        let watch = r.steps!
        r.steps = 999
        r.stepsSource = .estimated
        let f = StepReconciliation.finalize(r, healthWatchSteps: watch, calibration: StepCalibration(), walkingStepLength: 0.7)
        XCTAssertEqual(f.stepsSource, .appleWatch)
        XCTAssertEqual(f.steps, watch)
    }

    /// Estimation en direct recalculée avec la longueur de pas apprise.
    func testLiveEstimateUsesCalibration() {
        var c = StepCalibration()
        let learnt = record(stepsPerMeter: 1 / 0.80)
        c.learn(from: learnt, measuredSteps: learnt.steps!)
        var r = record(stepsPerMeter: nil)
        r.steps = 1
        r.stepsSource = .estimated
        let f = StepReconciliation.finalize(r, healthWatchSteps: nil, calibration: c, walkingStepLength: 0.7)
        XCTAssertEqual(Double(f.steps ?? 0), r.distanceMeters / 0.80, accuracy: 3)
    }

    func testTreadmillStepsUntouched() {
        let r = record(stepsPerMeter: 0.3, source: .treadmill)
        XCTAssertEqual(StepReconciliation.finalize(r, healthWatchSteps: 5000, calibration: StepCalibration(), walkingStepLength: 0.7), r)
    }

    // MARK: - Pas relus dans Santé

    /// Hors pause seulement, au prorata du recouvrement.
    func testWatchStepsDuringActiveIntervals() {
        let r = record(minutes: 10, stepsPerMeter: nil, paused: 200...259)   // pause de 1 min à 200 s
        let iv = r.activeIntervals()
        XCTAssertEqual(iv.count, 2)
        let t0 = r.startDate
        let samples = [
            StepReconciliation.HealthStepSample(start: t0, end: t0 + 100, count: 100),            // entièrement actif
            StepReconciliation.HealthStepSample(start: t0 + 190, end: t0 + 270, count: 80),       // 9 s actives avant la pause (dernier échantillon 199 s), 10 après
            StepReconciliation.HealthStepSample(start: t0 + 1000, end: t0 + 1100, count: 500),    // après la séance
        ]
        XCTAssertEqual(StepReconciliation.watchSteps(samples, during: iv), 100 + 19, accuracy: 0.5)
    }

    /// Contrôle pas / distance avec la longueur de pas apprise : un grand pas n'est plus signalé.
    func testStepCheckUsesCalibration() {
        var c = StepCalibration()
        let learnt = record(stepsPerMeter: 1 / 0.92)
        c.learn(from: learnt, measuredSteps: learnt.steps!)   // ratio 0,76 : hors plage, non appris
        XCTAssertTrue(c.isEmpty)
        c.walk = .init(factor: 0.92 / 0.70, meters: 5000, sessions: 5)
        let r = record(stepsPerMeter: 1 / 0.92)
        XCTAssertEqual(r.stepCheck(walkingStepLength: 0.7, calibration: c)?.verdict, .plausible)
    }
}

/// Séance du 25/11 (RUN100) : distance par paliers de 10 m, pas de la montre à chaque échantillon.
final class StepCalibrationQuantizedDistanceTests: XCTestCase {
    func testPerBandLearningWithTenMeterDistanceSteps() throws {
        var r = SessionRecord(startDate: Date(timeIntervalSince1970: 1_800_000_000), program: nil, treadmillName: nil,
                              profileID: nil, simulated: false)
        var d = 0.0, steps = 0.0
        // 10 min de marche à 5 km/h (0,74 m/pas), puis 10 min à 9 km/h (0,90 m/pas).
        for i in 0...1200 {
            let speed: Double = i < 600 ? 5 : 9
            r.samples.append(SessionSample(t: Double(i), active: Double(i), speed: speed, incline: nil, targetSpeed: speed,
                                           targetIncline: nil, hr: nil, hrSource: nil, zone: nil, distance: (d / 10).rounded(.down) * 10,
                                           steps: Int(steps), phase: nil, paused: false))
            d += speed / 3.6
            steps += speed / 3.6 / (speed < 7 ? 0.74 : 0.90)
        }
        r.distanceMeters = r.samples.last!.distance
        r.steps = r.samples.last!.steps
        r.stepsSource = .appleWatch
        var c = StepCalibration()
        XCTAssertTrue(c.learn(from: r, measuredSteps: r.steps!))
        XCTAssertEqual(c.learnedStepLength(speedKmh: 5) ?? 0, 0.74, accuracy: 0.02)
        XCTAssertEqual(c.learnedStepLength(speedKmh: 9) ?? 0, 0.90, accuracy: 0.02)
    }
}

extension StepCalibrationQuantizedDistanceTests {
    /// Une calibration enregistrée avant le champ `version` est lue comme ancienne (réapprise).
    func testOldCalibrationHasNoVersion() throws {
        let old = #"{"walk":{"factor":1.4,"meters":800,"sessions":1},"learnedSessionIDs":[]}"#
        let c = try JSONDecoder().decode(StepCalibration.self, from: Data(old.utf8))
        XCTAssertNil(c.version)
        XCTAssertEqual(StepCalibration().version, StepCalibration.currentVersion)
    }
}
