import XCTest
@testable import TreadCore

final class SessionHarness {
    let h: ControllerHarness
    let hr = HeartRateMonitor(preference: .automatic)
    var session: WorkoutSession!
    var finished: SessionRecord?

    init(program: WorkoutProgram?, quirks: SimulatedTreadmill.Quirks = .urtm047Like, settings: SessionSettings = SessionSettings()) {
        h = ControllerHarness(profile: .urtm047, quirks: quirks)
        session = WorkoutSession(program: program, controller: h.controller, heartRate: hr, settings: settings,
                                 treadmillName: "URTM047", simulated: true, log: h.log,
                                 clock: { [unowned h] in h.now }, wallClock: { Date(timeIntervalSince1970: 1_700_000_000) })
        h.controller.onTelemetry = { [unowned self] d, t in self.session.handleTelemetry(d, at: t) }
        h.controller.onEvent = { [unowned self] e in self.h.events.append(e); self.session.handle(controllerEvent: e) }
        session.onFinished = { [unowned self] in self.finished = $0 }
    }

    func run(_ seconds: TimeInterval, hrBPM: Int? = nil) {
        let end = h.now + seconds
        var nextHR = h.now
        while h.now < end {
            h.now += 0.1
            h.link.advance()
            if let bpm = hrBPM, h.now >= nextHR {
                hr.ingest(HeartRateReading(bpm: bpm, receivedAt: h.now, source: .bleSensor))
                nextHR = h.now + 1
            }
            session.tick()
        }
    }
}

final class WorkoutSessionTests: XCTestCase {
    func program() -> WorkoutProgram {
        WorkoutProgram(name: "Mini", items: [
            .phase(.init(name: "A", durationSeconds: 60, speedKmh: 4, inclinePercent: 0, targetZone: 2)),
            .phase(.init(name: "B", durationSeconds: 60, speedKmh: 6, inclinePercent: 3)),
            .phase(.init(name: "C", durationSeconds: 30, speedKmh: 3)),
        ])
    }

    func testFullProgramRunsAndStopsTreadmill() {
        let s = SessionHarness(program: program())
        XCTAssertNoThrow(try s.session.start().get())
        XCTAssertEqual(s.session.status, .starting)
        s.run(20, hrBPM: 130)
        XCTAssertEqual(s.session.status, .running)
        XCTAssertEqual(s.session.currentPhase?.phase.name, "A")
        s.run(60, hrBPM: 130)
        XCTAssertEqual(s.session.currentPhase?.phase.name, "B")
        s.run(40, hrBPM: 150)
        XCTAssertEqual(s.h.controller.telemetry.speedKmh ?? 0, 6, accuracy: 0.01)
        XCTAssertEqual(s.h.controller.telemetry.inclinePercent ?? 0, 3, accuracy: 0.01)
        s.run(60, hrBPM: 120)
        XCTAssertEqual(s.session.status, .finished)
        guard let r = s.finished else { return XCTFail("séance non terminée") }
        XCTAssertEqual(r.activeSeconds, 150, accuracy: 0.5)
        XCTAssertGreaterThan(r.distanceMeters, 150)
        XCTAssertEqual(r.distanceSource, .treadmill)
        XCTAssertNil(r.steps, "le tapis simulé URTM047 n'envoie pas de pas ; pas d'estimation activée")
        XCTAssertEqual(r.stepsSource, .none)
        XCTAssertEqual(r.maxHR, 150)
        XCTAssertGreaterThan(r.zoneSeconds[2] + r.zoneSeconds[3], 100)
        XCTAssertEqual(r.hrSources, [.bleSensor])
        XCTAssertTrue(s.h.sentCommands.contains(.stop))
        XCTAssertEqual(s.h.sentCommands.filter { $0 == .startOrResume }.count, 1)
        XCTAssertFalse(r.samples.isEmpty)
        // Une seule consigne par changement de phase (pas de doublon).
        XCTAssertEqual(s.h.sentCommands.filter { $0 == .setTargetSpeed(kmh: 6) }.count, 1)
    }

    func testManualOverrideUntilNextPhase() {
        let s = SessionHarness(program: program())
        _ = s.session.start()
        s.run(25)
        XCTAssertNoThrow(try s.session.adjustSpeed(by: 0.5).get())
        XCTAssertEqual(s.session.manualOverride?.speed, 4.5)
        XCTAssertEqual(s.session.effectiveTargets.speed, 4.5)
        s.run(15)
        XCTAssertEqual(s.h.controller.telemetry.speedKmh ?? 0, 4.5, accuracy: 0.01)
        s.run(50)
        XCTAssertEqual(s.session.currentPhase?.phase.name, "B")
        XCTAssertNil(s.session.manualOverride)
        XCTAssertEqual(s.session.effectiveTargets.speed, 6)
    }

    func testPauseResumeKeepsProgress() {
        let s = SessionHarness(program: program())
        _ = s.session.start()
        s.run(30)
        let before = s.session.activeTime
        s.session.pause()
        s.run(60)
        XCTAssertEqual(s.session.activeTime, before, accuracy: 0.01)
        XCTAssertEqual(s.h.controller.state, .paused)
        XCTAssertNoThrow(try s.session.resume().get())
        s.run(20)
        XCTAssertEqual(s.session.status, .running)
        XCTAssertGreaterThan(s.session.activeTime, before)
        XCTAssertEqual(s.session.currentPhase?.phase.name, "A")
        XCTAssertGreaterThan(s.session.record.pausedSeconds, 59)
    }

    func testConnectionLossPausesAndNeverAutoRestarts() {
        let s = SessionHarness(program: program())
        _ = s.session.start()
        s.run(30)
        s.h.link.disconnect()
        s.run(1)
        XCTAssertEqual(s.session.status, .paused(.connectionLost))
        let commands = s.h.sentCommands.count
        s.h.link.connect(to: s.h.controller)
        s.run(30)
        XCTAssertEqual(s.session.status, .paused(.connectionLost))
        XCTAssertEqual(s.h.sentCommands.count, commands)
        // Reprise explicite : le tapis tourne encore, donc pas de Start.
        XCTAssertNoThrow(try s.session.resume().get())
        s.run(5)
        XCTAssertEqual(s.session.status, .running)
        XCTAssertEqual(s.h.sentCommands.filter { $0 == .startOrResume }.count, 1)
        XCTAssertTrue(s.session.record.events.contains { $0.kind == .connectionLost })
    }

    func testSafetyKeyPausesSession() {
        let s = SessionHarness(program: program())
        _ = s.session.start()
        s.run(30)
        s.h.link.treadmill.pullSafetyKey(now: s.h.now)
        s.run(1)
        XCTAssertEqual(s.session.status, .paused(.machineStopped("clé de sécurité")))
    }

    func testIncompatibleProgramIsRefused() {
        let bad = WorkoutProgram(name: "Bad", items: [.phase(.init(name: "x", durationSeconds: 60, speedKmh: 15))])
        let s = SessionHarness(program: bad)
        guard case .failure = s.session.start() else { return XCTFail("programme incompatible lancé") }
        XCTAssertTrue(s.h.sentCommands.isEmpty)
        XCTAssertEqual(s.session.status, .ready)
    }

    func testSkipPhaseAppliesNextTargets() {
        let s = SessionHarness(program: program())
        _ = s.session.start()
        s.run(20)
        s.session.skipToNextPhase()
        s.run(20)
        XCTAssertEqual(s.session.currentPhase?.phase.name, "B")
        XCTAssertEqual(s.h.controller.telemetry.speedKmh ?? 0, 6, accuracy: 0.01)
    }

    func testTreadmillStepsAndCounterResetAcrossStopStart() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.reportsStepCount = true
        let s = SessionHarness(program: nil, quirks: q)
        _ = s.session.start()
        s.run(60)
        let first = s.session.steps.value ?? 0
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(s.session.steps.source, .treadmill)
        let distanceBefore = s.session.distanceMeters
        // Arrêt par le bouton du tapis puis reprise : les compteurs du tapis repartent de 0.
        s.h.link.treadmill.pressStopButton(now: s.h.now)
        s.run(10)
        XCTAssertEqual(s.session.status, .paused(.machineStopped("arrêt sur le tapis")))
        XCTAssertNoThrow(try s.session.resume().get())
        s.run(60)
        XCTAssertGreaterThan(s.session.steps.value ?? 0, first)
        XCTAssertGreaterThan(s.session.distanceMeters, distanceBefore + 30)
    }

    func testCheckpointRecovery() throws {
        let s = SessionHarness(program: program())
        _ = s.session.start()
        s.run(40, hrBPM: 125)
        let cp = s.session.checkpoint()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CheckpointStore(directory: dir)
        try store.save(cp)
        let loaded = try XCTUnwrap(store.load())
        let rec = WorkoutSession.recoveredRecord(from: loaded)
        XCTAssertTrue(rec.interrupted)
        XCTAssertEqual(rec.id, s.session.record.id)
        XCTAssertGreaterThan(rec.activeSeconds, 15)
        XCTAssertEqual(rec.events.last?.kind, .recovered)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testExportCSVAndJSON() throws {
        let s = SessionHarness(program: program())
        _ = s.session.start()
        s.run(200, hrBPM: 140)
        let r = try XCTUnwrap(s.finished)
        let csv = SessionExport.csv(r)
        let lines = csv.split(separator: "\n")
        XCTAssertTrue(lines[0].hasPrefix("timestamp,t_s,active_s,speed_kmh"))
        XCTAssertEqual(lines.count, r.samples.count + 1)
        XCTAssertEqual(lines[1].split(separator: ",", omittingEmptySubsequences: false).count, 14)
        let json = try SessionExport.json([r])
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"foulee.sessions\""))
        let roundTrip = try SessionExport.decodeRecord(SessionExport.encodeRecord(r))
        XCTAssertEqual(roundTrip.id, r.id)
        XCTAssertEqual(roundTrip.samples, r.samples)
        XCTAssertEqual(roundTrip.events, r.events)
        XCTAssertEqual(roundTrip.zoneSeconds, r.zoneSeconds)
        let template = try XCTUnwrap(r.derivedProgram(name: "Modèle"))
        XCTAssertEqual(template.totalDurationSeconds, program().totalDurationSeconds)
        XCTAssertEqual(SessionExport.fileName(for: r, ext: "csv").hasSuffix(".csv"), true)
    }

    func testFreeRunDerivedTemplate() throws {
        let s = SessionHarness(program: nil)
        _ = s.session.start()
        s.run(60)
        _ = s.session.setManualSpeed(5)
        s.run(60)
        s.session.stop()
        s.run(5)
        let r = try XCTUnwrap(s.finished)
        let t = try XCTUnwrap(r.derivedProgram(name: "Libre"))
        XCTAssertEqual(t.schedule.map(\.phase.speedKmh), [3, 5])
    }

    func testWatchMessageRoundTrip() throws {
        let msgs: [WatchMessage] = [
            .heartRate(bpm: 132, sampleDate: Date(timeIntervalSince1970: 1000)),
            .steps(total: 1234, sampleDate: Date(timeIntervalSince1970: 1001)),
            .workoutState(.running, startDate: nil),
            .linkSession(id: UUID(), title: "x"),
            .command(.end),
        ]
        for m in msgs { XCTAssertEqual(try WatchMessage.decode(m.encoded()), m) }
    }
}

final class HealthSyncPlanTests: XCTestCase {
    func record(hrSource: HeartRateSource?) -> SessionRecord {
        var r = SessionRecord(startDate: Date(), program: nil, treadmillName: nil, profileID: nil, simulated: false)
        r.activeSeconds = 600
        r.distanceMeters = 800
        r.distanceSource = .treadmill
        r.calories.treadmillKcal = 50
        r.samples = [SessionSample(t: 0, active: 0, speed: 5, incline: 0, targetSpeed: 5, targetIncline: 0, hr: 120,
                                   hrSource: hrSource, zone: 2, distance: 0, steps: nil, phase: nil, paused: false)]
        return r
    }

    func testWatchOwnsWhenUsed() {
        var s = HealthSettings(); s.enabled = true
        let p = HealthSyncPlan.make(record: record(hrSource: .appleWatch), settings: s, watchWorkoutUsed: true)
        XCTAssertEqual(p.owner, .watch)
        XCTAssertFalse(p.writeDistance || p.writeHeartRate || p.writeEnergy || p.writeSteps)
    }

    func testPhoneOwnerWritesOnlyMissingData() {
        var s = HealthSettings(); s.enabled = true
        let p = HealthSyncPlan.make(record: record(hrSource: .bleSensor), settings: s, watchWorkoutUsed: false)
        XCTAssertEqual(p.owner, .phone)
        XCTAssertTrue(p.writeHeartRate)
        XCTAssertTrue(p.writeDistance)
        XCTAssertFalse(p.writeEnergy, "énergie du tapis désactivée par défaut")
        XCTAssertFalse(p.writeSteps)
    }

    func testIdempotentAndDisabled() {
        var s = HealthSettings(); s.enabled = true
        var r = record(hrSource: .bleSensor)
        r.healthStatus = .saved(workoutUUID: "x")
        XCTAssertEqual(HealthSyncPlan.make(record: r, settings: s, watchWorkoutUsed: false).owner, .none)
        s.enabled = false
        XCTAssertEqual(HealthSyncPlan.make(record: record(hrSource: nil), settings: s, watchWorkoutUsed: false).owner, .none)
    }
}
