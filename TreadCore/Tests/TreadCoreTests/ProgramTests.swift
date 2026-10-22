import XCTest
@testable import TreadCore

final class ProgramTests: XCTestCase {
    func intervals() -> WorkoutProgram {
        WorkoutProgram(name: "Test", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 60, speedKmh: 4)),
            .block(.init(name: "Bloc", repeatCount: 3, phases: [
                .init(name: "Vite", kind: .work, durationSeconds: 30, speedKmh: 8, inclinePercent: 2),
                .init(name: "Lent", kind: .recovery, durationSeconds: 20, speedKmh: 5),
            ])),
            .phase(.init(name: "Calme", kind: .cooldown, durationSeconds: 40, speedKmh: 3.5)),
        ])
    }

    func testScheduleExpandsRepeatsAndTotals() {
        let p = intervals()
        XCTAssertEqual(p.totalDurationSeconds, 60 + 3 * 50 + 40)
        let s = p.schedule
        XCTAssertEqual(s.count, 1 + 6 + 1)
        XCTAssertEqual(s[1].start, 60)
        XCTAssertEqual(s[1].repetition?.iteration, 1)
        XCTAssertEqual(s[6].displayName, "Lent · 3/3")
        XCTAssertEqual(s.last?.end, 250)
    }

    func testEngineProgressionPauseResume() {
        let e = ProgramEngine(schedule: intervals().schedule)
        var events = e.start(at: 100)
        XCTAssertEqual(events, [.phaseStarted(index: 0, skipped: [])])
        events = e.update(at: 159)
        XCTAssertEqual(events, [])
        events = e.update(at: 160)
        XCTAssertEqual(events, [.phaseStarted(index: 1, skipped: [])])
        e.pause(at: 170)
        // Pendant la pause, la progression ne bouge pas.
        XCTAssertEqual(e.position(at: 500).phaseElapsed, 10, accuracy: 0.001)
        XCTAssertEqual(e.update(at: 500), [])
        events = e.resume(at: 600)
        XCTAssertEqual(events, [])
        XCTAssertEqual(e.position(at: 610).phaseElapsed, 20, accuracy: 0.001)
        XCTAssertEqual(e.activeElapsed(at: 610), 80, accuracy: 0.001)
        events = e.update(at: 620)
        XCTAssertEqual(events, [.phaseStarted(index: 2, skipped: [])])
    }

    func testEngineReportsSkippedPhasesAfterSuspension() {
        let e = ProgramEngine(schedule: intervals().schedule)
        e.start(at: 0)
        // App suspendue : réveil à 175 s, au milieu de la phase 5 (160–190 s).
        let events = e.update(at: 175)
        XCTAssertEqual(events, [.phaseStarted(index: 5, skipped: [1, 2, 3, 4])])
        XCTAssertEqual(e.update(at: 176), [])
    }

    func testEngineFinishesOnceAndClampsActiveTime() {
        let e = ProgramEngine(schedule: intervals().schedule)
        e.start(at: 0)
        _ = e.update(at: 100)
        let events = e.update(at: 300)
        XCTAssertEqual(events.last, .finished)
        XCTAssertEqual(e.activeElapsed(at: 400), 250, accuracy: 0.001)
        XCTAssertEqual(e.update(at: 500), [])
    }

    func testSkipToNextPhase() {
        let e = ProgramEngine(schedule: intervals().schedule)
        e.start(at: 0)
        _ = e.update(at: 10)
        let events = e.skipToNextPhase(at: 10)
        XCTAssertEqual(events, [.phaseStarted(index: 1, skipped: [])])
        XCTAssertEqual(e.position(at: 10).phaseElapsed, 0, accuracy: 0.001)
        // Le temps actif réel n'est pas modifié par le saut.
        XCTAssertEqual(e.activeElapsed(at: 10), 10, accuracy: 0.001)
    }

    func testFreeRunEngine() {
        let e = ProgramEngine(schedule: [])
        XCTAssertEqual(e.start(at: 0), [])
        XCTAssertEqual(e.activeElapsed(at: 42), 42, accuracy: 0.001)
        XCTAssertEqual(e.skipToNextPhase(at: 42), [])
    }

    func testEngineSnapshotRestoresPaused() {
        let e = ProgramEngine(schedule: intervals().schedule)
        e.start(at: 0)
        _ = e.update(at: 70)
        let snap = e.snapshot(at: 70)
        let r = ProgramEngine(schedule: intervals().schedule)
        r.restore(snap)
        XCTAssertEqual(r.state, .paused)
        XCTAssertEqual(r.activeElapsed(at: 1000), 70, accuracy: 0.001)
    }

    func testValidationAgainstCapabilities() {
        var p = intervals()
        let caps = TreadmillProfile.urtm047.fallbackCapabilities
        XCTAssertTrue(ProgramValidator.validate(p, against: caps).isEmpty)
        p.items.append(.phase(.init(name: "Trop vite", durationSeconds: 60, speedKmh: 13)))
        p.items.append(.phase(.init(name: "Pente", durationSeconds: 60, speedKmh: 5, inclinePercent: 12)))
        p.items.append(.phase(.init(name: "Demi-pas", durationSeconds: 60, speedKmh: 5.05)))
        p.items.append(.phase(.init(name: "Pente décimale", durationSeconds: 60, speedKmh: 5, inclinePercent: 2.5)))
        let issues = ProgramValidator.validate(p, against: caps)
        XCTAssertEqual(Set(issues.compactMap(\.phaseName)), ["Trop vite", "Pente", "Demi-pas", "Pente décimale"])
        XCTAssertTrue(issues.allSatisfy { $0.severity == .error })
        // Rien n'a été modifié silencieusement.
        XCTAssertEqual(p.schedule.last?.phase.inclinePercent, 2.5)
    }

    func testInclineOnTreadmillWithoutInclination() {
        let caps = TreadmillProfile.genericFTMS.fallbackCapabilities
        let p = WorkoutProgram(name: "x", items: [.phase(.init(name: "Pente", durationSeconds: 60, speedKmh: 5, inclinePercent: 3))])
        XCTAssertEqual(ProgramValidator.validate(p, against: caps).first?.message, "Ce tapis ne permet pas de régler l'inclinaison")
    }

    func testStructureValidation() {
        let p = WorkoutProgram(name: " ", items: [
            .phase(.init(name: "a", durationSeconds: 0, speedKmh: 5)),
            .block(.init(name: "b", repeatCount: 0, phases: [])),
        ])
        let msgs = ProgramValidator.validateStructure(p).map(\.message)
        XCTAssertTrue(msgs.contains("Le programme n'a pas de nom"))
        XCTAssertTrue(msgs.contains("Durée invalide (0 s)"))
        XCTAssertTrue(msgs.contains("Bloc vide"))
        XCTAssertTrue(msgs.contains("Nombre de répétitions invalide (0)"))
    }

    func testJSONRoundTripWithNewIDs() throws {
        let p = intervals()
        let data = try ProgramExchange.export([p])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"formatVersion\" : 1"))
        XCTAssertTrue(text.contains("\"type\" : \"block\""))
        let imported = try ProgramExchange.importPrograms(from: data)
        XCTAssertEqual(imported.count, 1)
        XCTAssertNotEqual(imported[0].id, p.id)
        XCTAssertEqual(imported[0].name, p.name)
        XCTAssertEqual(imported[0].schedule.map(\.phase.speedKmh), p.schedule.map(\.phase.speedKmh))
        XCTAssertEqual(imported[0].totalDurationSeconds, p.totalDurationSeconds)
    }

    func testImportRejectsBadFiles() {
        XCTAssertThrowsError(try ProgramExchange.importPrograms(from: Data("pas du json".utf8)))
        XCTAssertThrowsError(try ProgramExchange.importPrograms(from: Data(#"{"format":"autre","formatVersion":1}"#.utf8))) {
            XCTAssertEqual($0 as? ProgramExchangeError, .wrongFormat("autre"))
        }
        XCTAssertThrowsError(try ProgramExchange.importPrograms(from: Data(#"{"format":"foulee.programs","formatVersion":9,"programs":[]}"#.utf8))) {
            XCTAssertEqual($0 as? ProgramExchangeError, .unsupportedVersion(9))
        }
        let bad = WorkoutProgram(name: "Mauvais", items: [.phase(.init(name: "x", durationSeconds: -5, speedKmh: 5))])
        let data = try! ProgramExchange.export([bad])
        XCTAssertThrowsError(try ProgramExchange.importPrograms(from: data)) {
            guard case .invalidProgram(name: "Mauvais", _) = $0 as? ProgramExchangeError else { return XCTFail() }
        }
    }

    func testDuplicateHasFreshIDs() {
        let p = intervals()
        let d = p.duplicated()
        XCTAssertNotEqual(d.id, p.id)
        XCTAssertTrue(Set(d.schedule.map(\.phase.id)).isDisjoint(with: Set(p.schedule.map(\.phase.id))))
        XCTAssertEqual(d.name, "Test (copie)")
    }

    func testTemplatesAreValidForURTM047() {
        for t in WorkoutProgram.templates {
            XCTAssertTrue(ProgramValidator.validate(t, against: TreadmillProfile.urtm047.fallbackCapabilities).isEmpty, t.name)
        }
    }
}

final class HeartAndMetricsTests: XCTestCase {
    func testPercentOfMaxZones() {
        let z = HeartZoneSettings(maxHR: 200)
        XCTAssertEqual(z.bounds, [100, 120, 140, 160, 180, 200])
        XCTAssertEqual(z.zone(for: 99), 0)
        XCTAssertEqual(z.zone(for: 100), 1)
        XCTAssertEqual(z.zone(for: 139), 2)
        XCTAssertEqual(z.zone(for: 140), 3)
        XCTAssertEqual(z.zone(for: 185), 5)
        XCTAssertEqual(z.zone(for: 210), 5)
        XCTAssertNil(z.validationError())
    }

    func testHeartRateReserveZones() {
        let z = HeartZoneSettings(maxHR: 200, restingHR: 60, method: .heartRateReserve)
        XCTAssertEqual(z.bounds, [130, 144, 158, 172, 186, 200])
        XCTAssertEqual(z.zone(for: 150), 2)
        XCTAssertTrue(z.methodDescription.contains("Réserve"))
        // Sans FC de repos : retombe sur % FC max, et le dit.
        let noRest = HeartZoneSettings(maxHR: 200, restingHR: nil, method: .heartRateReserve)
        XCTAssertEqual(noRest.effectiveMethod, .percentOfMax)
        XCTAssertTrue(noRest.methodDescription.contains("indisponible"))
    }

    func testCustomZonesValidation() {
        var z = HeartZoneSettings(method: .customBPM, customBounds: [90, 110, 130, 150, 170, 190])
        XCTAssertEqual(z.zone(for: 135), 3)
        z.customBounds = [90, 110, 105, 150, 170, 190]
        XCTAssertNotNil(z.validationError())
    }

    func testZoneTimeIgnoresGapsAndPauses() {
        var acc = ZoneTimeAccumulator(maxGap: 5)
        acc.add(zone: 2, at: 0)
        acc.add(zone: 2, at: 1)
        acc.add(zone: 3, at: 2)
        acc.add(zone: 3, at: 30)  // trou de 28 s : non compté
        acc.add(zone: 3, at: 31)
        acc.interrupt()
        acc.add(zone: 4, at: 100)
        acc.add(zone: 4, at: 101)
        XCTAssertEqual(acc.seconds[2], 2)
        XCTAssertEqual(acc.seconds[3], 1)
        XCTAssertEqual(acc.seconds[4], 1)
        XCTAssertEqual(acc.total, 4)
    }

    func testZoneAlertDebounce() {
        var d = ZoneAlertDebouncer(dwell: 20, cooldown: 60)
        XCTAssertNil(d.evaluate(currentZone: 4, targetZone: 2, at: 0))
        XCTAssertNil(d.evaluate(currentZone: 4, targetZone: 2, at: 10))
        // Oscillation : retour dans la zone ⇒ compteur remis à zéro.
        XCTAssertNil(d.evaluate(currentZone: 2, targetZone: 2, at: 15))
        XCTAssertNil(d.evaluate(currentZone: 4, targetZone: 2, at: 16))
        XCTAssertNil(d.evaluate(currentZone: 4, targetZone: 2, at: 30))
        XCTAssertEqual(d.evaluate(currentZone: 4, targetZone: 2, at: 36), .above(target: 2, current: 4))
        // Délai minimal entre alertes.
        XCTAssertNil(d.evaluate(currentZone: 4, targetZone: 2, at: 60))
        XCTAssertEqual(d.evaluate(currentZone: 4, targetZone: 2, at: 97), .above(target: 2, current: 4))
        XCTAssertNil(d.evaluate(currentZone: 1, targetZone: nil, at: 200))
    }

    func testHeartRateStaleness() {
        let m = HeartRateMonitor(preference: .bleSensor)
        m.ingest(HeartRateReading(bpm: 130, receivedAt: 10, source: .bleSensor))
        XCTAssertEqual(m.status(now: 12), .live(bpm: 130, source: .bleSensor, age: 2))
        XCTAssertEqual(m.status(now: 16), .stale(lastBPM: 130, source: .bleSensor, age: 6))
        XCTAssertNil(m.status(now: 16).liveBPM)
    }

    func testHeartRateNoMixingBetweenSources() {
        let m = HeartRateMonitor(preference: .automatic)
        m.ingest(HeartRateReading(bpm: 120, receivedAt: 0, source: .appleWatch))
        XCTAssertEqual(m.activeSource, .appleWatch)
        // La ceinture arrive : en automatique, on reste sur la Watch tant qu'elle est vivante.
        m.ingest(HeartRateReading(bpm: 150, receivedAt: 1, source: .bleSensor))
        XCTAssertEqual(m.status(now: 2).liveBPM, 120)
        // Watch silencieuse > 15 s : bascule vers la ceinture (une seule source).
        m.ingest(HeartRateReading(bpm: 151, receivedAt: 20, source: .bleSensor))
        XCTAssertEqual(m.activeSource, .bleSensor)
        XCTAssertEqual(m.status(now: 20).liveBPM, 151)
        // Source explicite : l'autre est ignorée même si plus récente.
        let explicit = HeartRateMonitor(preference: .appleWatch)
        explicit.ingest(HeartRateReading(bpm: 150, receivedAt: 0, source: .bleSensor))
        XCTAssertEqual(explicit.status(now: 0), .unavailable)
    }

    func testCumulativeCounterResetWrapAndJump() {
        var c = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 5)
        c.ingest(1000, at: 0)        // référence
        c.ingest(1010, at: 2)
        XCTAssertEqual(c.sessionTotal, 10)
        XCTAssertEqual(c.ingest(3, at: 3), .reset(from: 1010, to: 3))   // Stop/Start du tapis
        XCTAssertEqual(c.sessionTotal, 13)
        XCTAssertEqual(c.ingest(10_000, at: 4), .implausibleJump(from: 3, to: 10_000))
        XCTAssertEqual(c.sessionTotal, 13)
        c.ingest(10_004, at: 5)
        XCTAssertEqual(c.sessionTotal, 17)

        var w = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 5)
        w.ingest((1 << 24) - 2, at: 0)
        XCTAssertEqual(w.ingest(3, at: 1), .wrapped(from: (1 << 24) - 2, to: 3))
        XCTAssertEqual(w.sessionTotal, 5)
    }

    func testCounterAfterReconnection() {
        var c = CumulativeCounter(modulus: 1 << 24, maxRatePerSecond: 5)
        c.ingest(500, at: 0)
        c.ingest(510, at: 2)
        c.markDiscontinuity()
        // Reconnexion 60 s plus tard, le tapis a continué de compter.
        c.ingest(700, at: 62)
        XCTAssertEqual(c.sessionTotal, 200)
    }

    func testStepTrackerSourcePriorityAndNoSum() {
        var s = StepTracker(estimationEnabled: true)
        XCTAssertNil(s.value)
        s.ingestTreadmill(raw: 100, at: 0)
        s.ingestTreadmill(raw: 110, at: 2)
        s.ingestWatch(total: 500, at: 3)
        s.ingestDistance(deltaMeters: 70, sessionElapsed: 60)
        XCTAssertEqual(s.source, .treadmill)
        XCTAssertEqual(s.value, 10)

        var w = StepTracker(estimationEnabled: false)
        w.ingestWatch(total: 3, at: 0)
        w.ingestWatch(total: 13, at: 2)
        XCTAssertEqual(w.source, .appleWatch)
        XCTAssertEqual(w.value, 13)

        var e = StepTracker(estimationEnabled: true, strideLengthMeters: 0.7)
        e.ingestDistance(deltaMeters: 7, sessionElapsed: 5)   // délai de grâce
        XCTAssertEqual(e.source, .none)
        e.ingestDistance(deltaMeters: 7, sessionElapsed: 30)
        XCTAssertEqual(e.source, .estimated)
        XCTAssertEqual(e.value, 20)

        var none = StepTracker(estimationEnabled: false)
        none.ingestDistance(deltaMeters: 100, sessionElapsed: 100)
        XCTAssertNil(none.value)
    }

    func testEnergyEstimator() {
        let walk = EnergyEstimator.kcalPerMinute(speedKmh: 5, gradePercent: 0, weightKg: 70)
        XCTAssertEqual(walk, (0.1 * 83.333 + 3.5) * 70 / 1000 * 5, accuracy: 0.01)
        XCTAssertGreaterThan(EnergyEstimator.kcalPerMinute(speedKmh: 5, gradePercent: 5, weightKg: 70), walk)
        XCTAssertEqual(EnergyEstimator.kcalPerMinute(speedKmh: 5, gradePercent: 0, weightKg: 0), 0)
    }
}
