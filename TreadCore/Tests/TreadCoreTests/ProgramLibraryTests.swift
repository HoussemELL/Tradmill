import XCTest
@testable import TreadCore

/// Programmes prédéfinis, rampes, transitions progressives, pilote FC, analyses et état Watch.
final class ProgramLibraryTests: XCTestCase {
    private let caps = TreadmillProfile.urtm047.fallbackCapabilities

    private func speeds(_ p: WorkoutProgram) -> [Double] { p.schedule.map(\.phase.speedKmh) }
    private func durations(_ p: WorkoutProgram) -> [Int] { p.schedule.map { $0.phase.durationSeconds / 60 } }

    func testSevenTemplatesWithExactSegments() {
        let t = WorkoutProgram.templates
        XCTAssertEqual(t.map(\.name), ["Cardio Baseline", "Zone 2 Endurance", "Interval Run 9/11", "HIIT Run 11",
                                       "Incline Walk", "Post-Meal Walk", "Zone 2 Auto"])
        XCTAssertEqual(t.map { $0.totalDurationSeconds / 60 }, [30, 35, 30, 35, 30, 15, 35])
        for p in t {
            XCTAssertTrue(ProgramValidator.validate(p, against: caps).isEmpty, "\(p.name) : \(ProgramValidator.validate(p, against: caps))")
            XCTAssertNotNil(p.templateID)
        }
        XCTAssertEqual(Set(t.map(\.protocolSignature)).count, 7)

        let base = WorkoutProgram.cardioBaseline
        XCTAssertTrue(base.isLocked)
        XCTAssertEqual(durations(base), [5, 20, 5])
        XCTAssertEqual(speeds(base), [4.0, 6.0, 3.8])
        XCTAssertEqual(base.schedule.map(\.phase.inclinePercent), [0, 0, 0])

        let z2 = WorkoutProgram.zone2Endurance
        XCTAssertEqual(durations(z2), [5, 5, 20, 5])
        XCTAssertEqual(speeds(z2), [4.0, 5.5, 6.0, 3.8])
        XCTAssertEqual(z2.schedule.map(\.phase.inclinePercent), [0, 0, 1, 0])
        XCTAssertFalse(z2.hasAutoSpeed, "aucune accélération automatique selon la FC")

        let run = WorkoutProgram.intervalRun911
        XCTAssertEqual(durations(run), [3, 3, 2] + Array(repeating: 1, count: 12) + [2, 3, 5])
        XCTAssertEqual(speeds(run), [4, 5, 6] + Array([9.0, 5.0].repeated(6)) + [11, 4, 3.8])
        XCTAssertTrue(run.schedule.allSatisfy { $0.phase.inclinePercent == 0 })

        let hiit = WorkoutProgram.hiitRun11
        XCTAssertEqual(durations(hiit), [4, 4, 2] + Array([2, 3].repeated(4)) + [5])
        XCTAssertEqual(speeds(hiit), [4, 5.5, 7] + Array([11.0, 4.5].repeated(4)) + [3.8])

        let incline = WorkoutProgram.inclineWalk
        XCTAssertEqual(durations(incline), [5, 5, 15, 5])
        XCTAssertEqual(speeds(incline), [4, 5.5, 5.5, 3.8])
        XCTAssertEqual(incline.schedule.map(\.phase.inclinePercent), [0, 1, 2, 0])

        let meal = WorkoutProgram.postMealWalk
        XCTAssertEqual(durations(meal), [2, 10, 3])
        XCTAssertEqual(speeds(meal), [3.5, 4.5, 3.5])

        let auto = WorkoutProgram.zone2Auto
        XCTAssertEqual(durations(auto), [5, 25, 5])
        XCTAssertTrue(auto.hasAutoSpeed)
        XCTAssertEqual(auto.schedule[0].phase.endSpeedKmh, 5.5)
        XCTAssertEqual(auto.schedule[2].phase.speedKmh, 4.0)
        XCTAssertEqual(auto.schedule[2].phase.endSpeedKmh, 3.5)
        let a = try! XCTUnwrap(auto.schedule[1].phase.autoSpeed)
        XCTAssertEqual(a.targetZone, 2)
        XCTAssertEqual(a.minKmh, 4)
        XCTAssertEqual(a.maxKmh, 7)
        XCTAssertEqual(a.stepKmh, 0.2)
        XCTAssertEqual(a.increaseInterval, 60)
        XCTAssertEqual(auto.schedule[1].phase.speedKmh, 5.8)
        XCTAssertEqual(auto.maxSpeedKmh, 7)
    }

    func testSignatureIgnoresNamesButNotSettings() {
        let base = WorkoutProgram.cardioBaseline
        var renamed = base.duplicated(name: "Mon test")
        XCTAssertEqual(renamed.protocolSignature, base.protocolSignature)
        XCTAssertFalse(renamed.isLocked, "une copie est modifiable")
        XCTAssertNil(renamed.templateID)
        if case var .phase(p) = renamed.items[1] {
            p.speedKmh = 6.1
            renamed.items[1] = .phase(p)
        }
        XCTAssertNotEqual(renamed.protocolSignature, base.protocolSignature)
        XCTAssertEqual(WorkoutProgram.cardioBaseline.protocolSignature, base.protocolSignature, "empreinte stable")
    }

    func testProgramsRoundTripAndOldFormatStillDecodes() throws {
        let data = try ProgramExchange.export(WorkoutProgram.templates)
        let back = try ProgramExchange.importPrograms(from: data)
        XCTAssertEqual(back.map(\.protocolSignature), WorkoutProgram.templates.map(\.protocolSignature))
        XCTAssertEqual(back.last?.schedule[1].phase.autoSpeed, AutoSpeedSettings())
        let old = #"{"id":"6F1C2B1E-0000-0000-0000-000000000001","name":"A","durationSeconds":60,"speedKmh":4,"inclinePercent":0,"kind":"steady"}"#
        let p = try CoreJSON.decode(ProgramPhase.self, from: Data(old.utf8))
        XCTAssertNil(p.autoSpeed)
        XCTAssertNil(p.endSpeedKmh)
    }

    func testValidationOfRampsAndAutoPhases() {
        var p = WorkoutProgram.zone2Auto
        if case var .phase(ph) = p.items[1] {
            ph.speedKmh = 7.5
            p.items[1] = .phase(ph)
        }
        XCTAssertTrue(ProgramValidator.validateStructure(p).contains { $0.message.contains("hors des limites automatiques") })
        var q = WorkoutProgram.zone2Auto
        if case var .phase(ph) = q.items[0] {
            ph.endSpeedKmh = 13
            q.items[0] = .phase(ph)
        }
        XCTAssertTrue(ProgramValidator.validate(q, against: caps).contains { $0.message.contains("Vitesse de fin") })
    }

    func testOldSessionSettingsStillDecode() throws {
        let json = #"{"zones":{"maxHR":190},"stepEstimationEnabled":true,"strideLengthMeters":0.7,"zoneAlertsEnabled":false,"zoneAlertDwell":20,"zoneAlertCooldown":90,"freeRunStartSpeed":3,"stopTreadmillAtProgramEnd":true}"#
        let s = try CoreJSON.decode(SessionSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.zones.maxHR, 190)
        XCTAssertTrue(s.stepEstimationEnabled)
        XCTAssertTrue(s.smoothTransitions)
        XCTAssertEqual(s.maxSpeedStepKmh, 1.0)
    }

    // MARK: - Rampes et transitions

    func testRampFollowsTreadmillIncrements() {
        let p = WorkoutProgram.zone2Auto.schedule[0].phase
        XCTAssertEqual(p.plannedSpeed(at: 0), 4.0, accuracy: 0.001)
        XCTAssertEqual(p.plannedSpeed(at: 150), 4.75, accuracy: 0.001)
        XCTAssertEqual(p.plannedSpeed(at: 300), 5.5, accuracy: 0.001)
        XCTAssertEqual(p.plannedSpeed(at: 999), 5.5, accuracy: 0.001)
    }

    /// Requested speeds observed during a run (distinct consecutive values).
    private func requestedTrace(_ s: SessionHarness, seconds: Double, hr: (Double) -> Int?) -> [Double] {
        var trace: [Double] = []
        let end = s.h.now + seconds
        var nextHR = s.h.now
        while s.h.now < end {
            s.h.now += 0.1
            s.h.link.advance()
            if s.h.now >= nextHR, let bpm = hr(s.h.controller.telemetry.speedKmh ?? 0) {
                s.hr.ingest(HeartRateReading(bpm: bpm, receivedAt: s.h.now, source: .bleSensor))
                nextHR = s.h.now + 1
            }
            s.session.tick()
            if let r = s.h.controller.speed.requested, trace.last.map({ abs($0 - r) > 0.001 }) ?? true { trace.append(r) }
        }
        return trace
    }

    func testSmoothTransitionsStepUpAndDown() {
        let p = WorkoutProgram(name: "Saut", items: [
            .phase(.init(name: "Lent", durationSeconds: 60, speedKmh: 5)),
            .phase(.init(name: "Rapide", durationSeconds: 60, speedKmh: 9)),
            .phase(.init(name: "Lent", durationSeconds: 60, speedKmh: 5)),
        ])
        let s = SessionHarness(program: p)
        XCTAssertNoThrow(try s.session.start().get())
        let trace = requestedTrace(s, seconds: 170) { _ in 120 }
        let afterStart = Array(trace.drop { $0 < 5 - 0.001 })
        XCTAssertEqual(afterStart.prefix(9), [5, 6, 7, 8, 9, 8, 7, 6, 5], "paliers de 1 km/h : \(trace)")
        XCTAssertEqual(s.h.controller.telemetry.speedKmh ?? 0, 5, accuracy: 0.05)
    }

    func testSmoothTransitionsCanBeDisabled() {
        var settings = SessionSettings()
        settings.smoothTransitions = false
        let p = WorkoutProgram(name: "Saut", items: [
            .phase(.init(name: "Lent", durationSeconds: 60, speedKmh: 5)),
            .phase(.init(name: "Rapide", durationSeconds: 60, speedKmh: 9)),
        ])
        let s = SessionHarness(program: p, settings: settings)
        XCTAssertNoThrow(try s.session.start().get())
        let trace = requestedTrace(s, seconds: 100) { _ in 120 }
        XCTAssertTrue(trace.contains(9))
        XCTAssertFalse(trace.contains(7), "\(trace)")
    }

    // MARK: - Filtre de FC

    func testHeartRateFilterNeedsAFilledWindowAndSmoothsSpikes() {
        var f = HeartRateFilter(window: 18)
        f.add(.init(bpm: 120, receivedAt: 0, source: .bleSensor))
        f.add(.init(bpm: 120, receivedAt: 1, source: .bleSensor))
        XCTAssertNil(f.value(at: 1), "trop peu de mesures")
        for t in 2...18 { f.add(.init(bpm: t == 10 ? 180 : 120, receivedAt: Double(t), source: .bleSensor)) }
        let v = try! XCTUnwrap(f.value(at: 18))
        XCTAssertLessThan(v, 125, "un pic isolé ne fait pas réagir")
        f.add(.init(bpm: 90, receivedAt: 19, source: .appleWatch))
        XCTAssertNil(f.value(at: 19), "changement de source : filtre vidé")
        XCTAssertNil(HeartRateFilter(window: 18).value(at: 0))
    }

    // MARK: - Pilote FC (logique pure)

    private let zone2 = ZoneRange(zone: 2, lower: 120, upper: 140)

    private func pilot(start: Double = 5.8, settings: AutoSpeedSettings = AutoSpeedSettings()) -> ZoneAutopilot {
        ZoneAutopilot(settings: settings, startKmh: start, capabilities: caps, now: 0)
    }

    func testAutopilotIncreasesAtMostEveryMinuteWhenBelowZone() {
        let a = pilot()
        var changes: [AutoAdjustment] = []
        for t in stride(from: 1.0, through: 200, by: 1) {
            if let c = a.update(now: t, sessionTime: t, filteredBPM: 110, heartRateLive: true, zone: zone2, controllable: true) {
                changes.append(c)
            }
        }
        XCTAssertEqual(changes.map(\.t), [60, 120, 180])
        XCTAssertEqual(changes.map(\.toKmh), [6.0, 6.2, 6.4])
        XCTAssertTrue(changes.allSatisfy { $0.kind == .increase })
    }

    func testAutopilotHoldsInZoneAndNudgesFromTheBottom() {
        let a = pilot()
        for t in stride(from: 1.0, through: 400, by: 1) {
            XCTAssertNil(a.update(now: t, sessionTime: t, filteredBPM: 130, heartRateLive: true, zone: zone2, controllable: true))
        }
        XCTAssertEqual(a.targetKmh, 5.8)
        XCTAssertEqual(a.trend, .inZone)
        // Quart bas de la zone : accélération deux fois plus rare (120 s).
        let b = pilot()
        var at: [Double] = []
        for t in stride(from: 1.0, through: 250, by: 1) {
            if let c = b.update(now: t, sessionTime: t, filteredBPM: 122, heartRateLive: true, zone: zone2, controllable: true) { at.append(c.t) }
        }
        XCTAssertEqual(at, [120, 240])
        var noNudge = AutoSpeedSettings()
        noNudge.nudgeTowardMiddle = false
        let c = pilot(settings: noNudge)
        for t in stride(from: 1.0, through: 250, by: 1) {
            XCTAssertNil(c.update(now: t, sessionTime: t, filteredBPM: 122, heartRateLive: true, zone: zone2, controllable: true))
        }
    }

    func testAutopilotSlowsDownFasterWhenSustainedHigh() {
        let a = pilot(start: 6.6)
        var changes: [AutoAdjustment] = []
        for t in stride(from: 1.0, through: 70, by: 1) {
            if let c = a.update(now: t, sessionTime: t, filteredBPM: 138, heartRateLive: true, zone: zone2, controllable: true) { changes.append(c) }
        }
        // Au-dessus de 137 (140 − 3) : −0,2 après 20 s maintenus, puis toutes les ≈ 20 s.
        XCTAssertEqual(changes.map(\.t), [21, 42, 63])
        XCTAssertEqual(changes.map(\.toKmh), [6.4, 6.2, 6.0])
        let b = pilot(start: 6.6)
        var far: AutoAdjustment?
        for t in stride(from: 1.0, through: 25, by: 1) {
            far = far ?? b.update(now: t, sessionTime: t, filteredBPM: 150, heartRateLive: true, zone: zone2, controllable: true)
        }
        XCTAssertEqual(far?.toKmh, 6.2, "FC > limite + 5 : deux paliers")
        // Une mesure isolée haute (déjà filtrée) qui ne dure pas ne fait pas ralentir.
        let c = pilot(start: 6.6)
        for t in stride(from: 1.0, through: 15, by: 1) {
            XCTAssertNil(c.update(now: t, sessionTime: t, filteredBPM: 139, heartRateLive: true, zone: zone2, controllable: true))
        }
        XCTAssertNil(c.update(now: 16, sessionTime: 16, filteredBPM: 130, heartRateLive: true, zone: zone2, controllable: true))
        XCTAssertEqual(c.targetKmh, 6.6)
    }

    func testAutopilotRespectsBoundsAndTreadmillLimits() {
        var s = AutoSpeedSettings()
        s.maxKmh = 15
        let a = ZoneAutopilot(settings: s, startKmh: 11.8, capabilities: caps, now: 0)
        for t in stride(from: 1.0, through: 600, by: 1) {
            _ = a.update(now: t, sessionTime: t, filteredBPM: 100, heartRateLive: true, zone: zone2, controllable: true)
        }
        XCTAssertEqual(a.targetKmh, 12, "limite du tapis")
        let b = pilot(start: 4.2)
        for t in stride(from: 1.0, through: 600, by: 1) {
            _ = b.update(now: t, sessionTime: t, filteredBPM: 170, heartRateLive: true, zone: zone2, controllable: true)
        }
        XCTAssertEqual(b.targetKmh, 4.0, "limite automatique basse")
    }

    func testAutopilotHeartRateLossDisablesIncreasesAndFallsBackProgressively() {
        let a = pilot(start: 6.4)
        var changes: [AutoAdjustment] = []
        for t in stride(from: 1.0, through: 60, by: 1) {
            if let c = a.update(now: t, sessionTime: t, filteredBPM: nil, heartRateLive: false, zone: zone2, controllable: true) { changes.append(c) }
        }
        XCTAssertEqual(a.mode, .heartRateLost)
        XCTAssertTrue(changes.allSatisfy { $0.kind == .safety && $0.toKmh < $0.fromKmh })
        XCTAssertEqual(changes.map(\.toKmh), [6.2, 6.0, 5.8, 5.6, 5.4, 5.2, 5.0, 4.8, 4.6, 4.5])
        XCTAssertEqual(zip(changes.dropFirst(), changes).map { $0.t - $1.t }.min(), 5, "progressif : un palier toutes les 5 s")
        // FC revenue, sous la zone : pas d'accélération avant 60 s.
        var up: [AutoAdjustment] = []
        for t in stride(from: 61.0, through: 150, by: 1) {
            if let c = a.update(now: t, sessionTime: t, filteredBPM: 110, heartRateLive: true, zone: zone2, controllable: true) { up.append(c) }
        }
        XCTAssertEqual(up.map(\.t), [121])
    }

    func testAutopilotYieldsToManualAndSuspendsWhenNotControllable() {
        let a = pilot()
        a.takeManualControl()
        for t in stride(from: 1.0, through: 200, by: 1) {
            XCTAssertNil(a.update(now: t, sessionTime: t, filteredBPM: 100, heartRateLive: true, zone: zone2, controllable: true))
        }
        a.resumeAutomatic(fromKmh: 5.0, at: 200)
        XCTAssertEqual(a.targetKmh, 5.0, "repart de la vitesse actuelle")
        XCTAssertNil(a.update(now: 201, sessionTime: 201, filteredBPM: nil, heartRateLive: false, zone: zone2, controllable: false))
        XCTAssertEqual(a.mode, .suspended)
    }

    // MARK: - Séance Zone 2 Auto complète (tapis simulé)

    /// FC simulée qui suit la vitesse mesurée : 5,8 km/h → 113 bpm, 6,6 → 126 bpm.
    private func heart(_ speed: Double) -> Int { Int((20 + 16 * speed).rounded()) }

    func testZone2AutoSessionRegulatesTowardZone2() {
        let s = SessionHarness(program: .zone2Auto)
        XCTAssertNoThrow(try s.session.start().get())
        var maxDuringWarmup = 0.0
        _ = requestedTrace(s, seconds: 15) { self.heart($0) }
        XCTAssertEqual(s.session.status, .running)
        let warm = requestedTrace(s, seconds: 285) { self.heart($0) }
        maxDuringWarmup = warm.max() ?? 0
        XCTAssertEqual(maxDuringWarmup, 5.5, accuracy: 0.001)
        XCTAssertGreaterThan(warm.count, 10, "rampe par incréments de 0,1 : \(warm)")
        XCTAssertTrue(zip(warm.dropFirst(), warm).allSatisfy { abs($0 - $1) <= 0.1 + 0.001 }, "\(warm)")
        let auto = requestedTrace(s, seconds: 25 * 60) { self.heart($0) }
        let r = s.session.record
        let adj = r.autoAdjustments ?? []
        XCTAssertGreaterThanOrEqual(adj.count, 3)
        XCTAssertTrue(adj.allSatisfy { $0.kind == .increase || $0.kind == .decrease })
        XCTAssertTrue(zip(adj.dropFirst(), adj).allSatisfy { $0.t - $1.t >= 59.9 || $0.kind == .decrease }, "\(adj.map(\.t))")
        XCTAssertLessThanOrEqual(auto.max() ?? 0, 7.0)
        // Régime établi : la FC finit dans la zone 2 (120–140).
        XCTAssertTrue((120..<140).contains(heart(s.h.controller.telemetry.speedKmh ?? 0)) || s.session.currentPhase?.phase.kind == .cooldown)
        _ = requestedTrace(s, seconds: 6 * 60) { self.heart($0) }
        XCTAssertEqual(s.session.status, .finished)
        XCTAssertNil(s.session.autopilot, "phase pilotée terminée")
        let fin = try! XCTUnwrap(s.finished)
        let focus = SessionAnalysis.zoneFocus(fin, zone: 2)
        XCTAssertGreaterThan(focus.autoPhaseFraction ?? 0, 0.5, "plus de la moitié de la phase pilotée en zone 2")
        XCTAssertNotNil(focus.speedInZone)
        XCTAssertEqual(focus.adjustments, adj.count)
        XCTAssertEqual(fin.phaseSpans?.filter { $0.auto == true }.count, 1)
    }

    func testZone2AutoHeartRateLossFallsBackAndManualTakesPriority() {
        let s = SessionHarness(program: .zone2Auto)
        XCTAssertNoThrow(try s.session.start().get())
        _ = requestedTrace(s, seconds: 5 * 60 + 15) { self.heart($0) }
        XCTAssertTrue(s.session.isAutoPhase)
        _ = requestedTrace(s, seconds: 4 * 60) { _ in 110 }  // sous la zone : accélérations
        let before = s.h.controller.speed.requested ?? 0
        XCTAssertGreaterThan(before, 5.8)
        var alerts: [String] = []
        s.session.onAlert = { alerts.append($0) }
        let lost = requestedTrace(s, seconds: 90) { _ in nil }  // plus de FC
        XCTAssertEqual(s.session.autopilot?.mode, .heartRateLost)
        XCTAssertTrue(zip(lost.dropFirst(), lost).allSatisfy { $0 <= $1 + 0.001 }, "jamais d'accélération sans FC : \(lost)")
        XCTAssertEqual(s.h.controller.speed.requested ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(s.session.record.events.contains { $0.kind == .autoSafety })
        // Reprise en main manuelle : prioritaire, le pilote se retire.
        XCTAssertNoThrow(try s.session.setManualSpeed(5.0).get())
        XCTAssertEqual(s.session.autopilot?.mode, .manual)
        _ = requestedTrace(s, seconds: 120) { _ in 100 }
        XCTAssertEqual(s.h.controller.speed.requested ?? 0, 5.0, accuracy: 0.001)
        s.session.resumeAutopilot()
        XCTAssertNotEqual(s.session.autopilot?.mode, .manual)
        XCTAssertEqual(s.session.effectiveTargets.speed, 5.0, accuracy: 0.001)
        XCTAssertEqual(s.session.record.manualChanges, 1)
    }

    func testFixedProgramsNeverAccelerateFromHeartRate() {
        let s = SessionHarness(program: .zone2Endurance)
        XCTAssertNoThrow(try s.session.start().get())
        let trace = requestedTrace(s, seconds: 16 * 60) { _ in 95 }  // FC très basse
        XCTAssertNil(s.session.autopilot)
        XCTAssertTrue(trace.allSatisfy { [1.0, 4.0, 5.0, 5.5, 6.0].contains($0) }, "\(trace)")
        XCTAssertNil(s.session.record.autoAdjustments)
    }

    // MARK: - Analyses et comparaisons

    private func runBaseline(hr: Int, manual: Bool = false) -> SessionRecord {
        let s = SessionHarness(program: .cardioBaseline)
        XCTAssertNoThrow(try s.session.start().get())
        s.run(15, hrBPM: 100)
        s.run(5 * 60, hrBPM: 100)
        if manual { _ = s.session.adjustSpeed(by: 0.1) }
        s.run(20 * 60, hrBPM: hr)
        s.run(5 * 60 + 10, hrBPM: hr - 20)
        s.run(150, hrBPM: hr - 40)
        var r = try! XCTUnwrap(s.finalized)
        r.simulated = false
        return r
    }

    func testIntervalStatsAndBaselineComparison() {
        let r1 = runBaseline(hr: 130)
        let stats = SessionAnalysis.phaseStats(r1)
        XCTAssertEqual(stats.map(\.name), ["Échauffement", "Allure de référence", "Retour au calme"])
        XCTAssertEqual(stats[1].avgHR ?? 0, 130, accuracy: 1)
        XCTAssertEqual(stats[1].maxHR, 130)
        XCTAssertEqual(stats[1].duration, 1200, accuracy: 2)
        XCTAssertEqual(stats[1].recoveryDrop60, 20, "6 → 3,8 km/h : FC −20 en 60 s")
        XCTAssertEqual(SessionAnalysis.postStopRecovery(r1)?.drop60, 20)

        let e1 = try! XCTUnwrap(ProgressAnalysis.entry(for: r1))
        XCTAssertTrue(e1.comparable, "\(e1.notComparableReasons)")
        XCTAssertEqual(e1.referenceHR, 130)
        let r2 = runBaseline(hr: 126)
        let r3 = runBaseline(hr: 120, manual: true)
        let groups = ProgressAnalysis.groups([r1, r2, r3])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].entries.count, 3)
        XCTAssertEqual(groups[0].comparableEntries.count, 2, "la séance modifiée à la main n'est pas comparable")
        XCTAssertTrue(groups[0].entries.last { !$0.comparable }?.notComparableReasons.contains("consignes modifiées pendant la séance") ?? false)
        XCTAssertTrue(groups[0].trend?.contains("progression") ?? false, groups[0].trend ?? "")
    }

    // MARK: - État envoyé à la Watch

    func testWatchZoneMathMatchesPhone() {
        let z = HeartZoneSettings(maxHR: 190, restingHR: 60)
        for bpm in stride(from: 40, through: 200, by: 1) {
            XCTAssertEqual(WatchLiveStatus.zone(for: bpm, bounds: z.bounds), z.zone(for: bpm), "\(bpm)")
        }
        let pct = HeartZoneSettings(maxHR: 200, method: .percentOfMax)
        XCTAssertEqual(WatchLiveStatus.zone(for: 90, bounds: pct.bounds), 0)
        XCTAssertEqual(WatchLiveStatus.range(of: 2, bounds: z.bounds)?.lower, z.bounds[1])
        XCTAssertEqual(WatchLiveStatus.progress(of: z.bounds[1], in: 2, bounds: z.bounds), 0)
        XCTAssertEqual(WatchLiveStatus.progress(of: z.bounds[2], in: 2, bounds: z.bounds), 1)
    }

    func testLiveStatusSnapshotAndCoding() throws {
        let s = SessionHarness(program: .zone2Auto)
        XCTAssertNoThrow(try s.session.start().get())
        s.run(6 * 60, hrBPM: 125)
        let st = WatchLiveStatus.make(session: s.session, now: s.h.now, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(st.state, .running)
        XCTAssertEqual(st.programName, "Zone 2 Auto")
        XCTAssertEqual(st.phaseName, "Zone 2 pilotée")
        XCTAssertEqual(st.phaseIndex, 1)
        XCTAssertEqual(st.phaseCount, 3)
        XCTAssertEqual(st.targetZone, 2)
        XCTAssertNotNil(st.autopilotStatus)
        XCTAssertEqual(st.phaseRemaining ?? 0, 1500 - (s.session.activeTime - 300), accuracy: 0.5)
        XCTAssertEqual(st.zoneBounds.count, 6)
        XCTAssertEqual(st.phoneHeartRate, 125)
        let msg = WatchMessage.liveStatus(st)
        XCTAssertEqual(try WatchMessage.decode(msg.encoded()), msg)
        XCTAssertEqual(try WatchMessage.decode(WatchMessage.remoteCommand(.stop).encoded()), .remoteCommand(.stop))
    }
}

private extension Array {
    func repeated(_ n: Int) -> [Element] { (0..<n).flatMap { _ in self } }
}
