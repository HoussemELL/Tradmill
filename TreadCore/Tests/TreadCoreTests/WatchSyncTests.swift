import XCTest
@testable import TreadCore

/// Synchronisation iPhone ↔ Apple Watch : catalogue, démarrage depuis la montre, commandes.
final class WatchSyncTests: XCTestCase {
    private let caps = TreadmillProfile.urtm047.fallbackCapabilities

    func testCatalogKeepsExactStepsAndBlocks() {
        let s = WatchProgramSummary(.intervalRun911)
        XCTAssertEqual(s.name, "Interval Run 9/11")
        XCTAssertEqual(s.totalSeconds, 30 * 60)
        XCTAssertEqual(s.groups.count, 7)
        let block = s.groups[3]
        XCTAssertTrue(block.isBlock)
        XCTAssertEqual(block.repeatCount, 6)
        XCTAssertEqual(block.steps.map(\.speedKmh), [9, 5])
        XCTAssertEqual(s.stepCount, 18)
        XCTAssertTrue(s.suggestsRunning)
        let auto = WatchProgramSummary(.zone2Auto)
        XCTAssertTrue(auto.isAuto)
        XCTAssertEqual(auto.groups[0].steps[0].speedText, "4.0 → 5.5 km/h")
        XCTAssertEqual(auto.groups[1].steps[0].speedText, "auto 4.0–7.0 km/h")
        XCTAssertEqual(auto.groups[1].steps[0].targetZone, 2)
        XCTAssertTrue(WatchProgramSummary(.cardioBaseline).isLocked)
    }

    func testContextRoundTripAndChangeDetection() throws {
        let ctx = WatchPhoneContext(programs: WorkoutProgram.templates.map(WatchProgramSummary.init),
                                    treadmill: .init(name: "URTM047", ready: true, simulated: false, label: "URTM047"),
                                    activeSessionID: nil, activeProgramName: nil,
                                    zoneBounds: HeartZoneSettings().bounds, sentAt: Date(timeIntervalSince1970: 100))
        let back = try WatchPhoneContext.decode(ctx.encoded())
        XCTAssertEqual(back, ctx)
        var later = ctx
        later.sentAt = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(later.sameContent(as: ctx), "seule la date change : pas de republication")
        later.programs.removeLast()
        XCTAssertFalse(later.sameContent(as: ctx), "programme supprimé sur l'iPhone : republication")
        XCTAssertLessThan(try ctx.encoded().count, 60_000, "le contexte tient dans un message WatchConnectivity")
        let msg = WatchMessage.context(ctx)
        XCTAssertEqual(try WatchMessage.decode(msg.encoded()), msg)
    }

    func testStartPolicy() {
        let programs = WorkoutProgram.templates
        let now = Date(timeIntervalSince1970: 1000)
        func eval(_ id: UUID?, age: TimeInterval = 1, ready: Bool = true, active: Bool = false) -> WatchStartPolicy.Decision {
            WatchStartPolicy.evaluate(WatchStartRequest(programID: id, issuedAt: now.addingTimeInterval(-age)), now: now,
                                      programs: programs, treadmillReady: ready, sessionActive: active,
                                      diagnosticRunning: false, capabilities: caps)
        }
        XCTAssertEqual(eval(programs[6].id), .start(programs[6]))
        XCTAssertEqual(eval(nil), .start(nil))
        if case .refuse = eval(programs[0].id, ready: false) {} else { XCTFail("tapis non connecté") }
        if case .refuse = eval(programs[0].id, active: true) {} else { XCTFail("séance déjà en cours") }
        if case .refuse = eval(programs[0].id, age: 45) {} else { XCTFail("demande périmée : jamais de démarrage tardif") }
        if case .refuse = eval(programs[0].id, age: 25) {} else { XCTFail("plus de 20 s : refusée") }
        XCTAssertLessThan(WatchStartPolicy.maxRequestAge, WatchStartPolicy.watchGiveUpAfter,
                          "la montre n'annonce l'échec qu'une fois toute acceptation impossible")
        if case .refuse = eval(UUID()) {} else { XCTFail("programme inconnu") }
        var tooFast = programs[0]
        if case var .phase(p) = tooFast.items[1] { p.speedKmh = 15; tooFast.items[1] = .phase(p) }
        let r = WatchStartPolicy.evaluate(WatchStartRequest(programID: tooFast.id, issuedAt: now), now: now, programs: [tooFast],
                                          treadmillReady: true, sessionActive: false, diagnosticRunning: false, capabilities: caps)
        if case .refuse = r {} else { XCTFail("programme incompatible") }
    }

    func testControlsAreTiedToSessionAndNeverReplayResumeLate() {
        let sid = UUID()
        let now = Date(timeIntervalSince1970: 1000)
        func c(_ cmd: WatchRemoteCommand, age: TimeInterval, session: UUID? = nil) -> WatchControl {
            WatchControl(command: cmd, sessionID: session ?? sid, issuedAt: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(c(.pause, age: 1).isAcceptable(now: now, currentSessionID: sid))
        XCTAssertTrue(c(.stop, age: 90).isAcceptable(now: now, currentSessionID: sid), "un arrêt retardé reste appliqué")
        XCTAssertFalse(c(.resume, age: 20).isAcceptable(now: now, currentSessionID: sid), "reprise retardée : jamais rejouée")
        XCTAssertFalse(c(.stop, age: 1, session: UUID()).isAcceptable(now: now, currentSessionID: sid), "autre séance")
        XCTAssertFalse(c(.pause, age: 1).isAcceptable(now: now, currentSessionID: nil), "plus de séance")
        XCTAssertEqual(try WatchMessage.decode(WatchMessage.control(c(.stop, age: 0)).encoded()), .control(c(.stop, age: 0)))
    }

    func testSimulatedHeartFollowsSpeedWithLag() {
        var h = SimulatedHeartModel()
        var bpm = 0
        for _ in 0..<5 { bpm = h.advance(dt: 1, speedKmh: 6, inclinePercent: 0) }
        XCTAssertLessThan(bpm, 100, "réponse progressive")
        for _ in 0..<200 { bpm = h.advance(dt: 1, speedKmh: 6, inclinePercent: 0) }
        XCTAssertEqual(bpm, 126)
    }

    /// Chemin réel de la FC Apple Watch : une mesure toutes les 5 s suffit au filtre du pilote.
    func testAutopilotWorksWithWatchCadenceHeartRate() {
        var settings = SessionSettings()
        settings.zones = HeartZoneSettings(maxHR: 185, restingHR: 60)  // Z2 = 135–148 bpm
        let s = SessionHarness(program: .zone2Auto, settings: settings)
        XCTAssertNoThrow(try s.session.start().get())
        var h = SimulatedHeartModel()
        let end = s.h.now + 11 * 60
        var nextHR = s.h.now
        while s.h.now < end {
            s.h.now += 0.1
            s.h.link.advance()
            if s.h.now >= nextHR {
                let bpm = h.advance(dt: 5, speedKmh: s.h.controller.telemetry.speedKmh ?? 0, inclinePercent: 0)
                s.hr.ingest(HeartRateReading(bpm: bpm, receivedAt: s.h.now, source: .appleWatch))
                nextHR = s.h.now + 5
            }
            s.session.tick()
        }
        XCTAssertEqual(s.session.autopilot?.mode, .regulating)
        XCTAssertGreaterThanOrEqual(s.session.record.autoAdjustments?.filter { $0.kind == .increase }.count ?? 0, 3,
                                    "FC Watch sous la zone : accélérations progressives")
    }

    func testLiveStatusCarriesSessionAndLinkState() {
        let s = SessionHarness(program: .cardioBaseline)
        XCTAssertNoThrow(try s.session.start().get())
        s.run(20, hrBPM: 110)
        let st = WatchLiveStatus.make(session: s.session, now: s.h.now, date: Date())
        XCTAssertEqual(st.sessionID, s.session.record.id)
        XCTAssertEqual(st.treadmillLinkLost, false)
        s.h.link.disconnect()
        s.run(1)
        let lost = WatchLiveStatus.make(session: s.session, now: s.h.now, date: Date())
        XCTAssertEqual(lost.treadmillLinkLost, true)
        XCTAssertEqual(lost.state, .paused)
    }
}
