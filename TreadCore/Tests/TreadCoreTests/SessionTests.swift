import XCTest
@testable import TreadCore

final class SessionHarness {
    let h: ControllerHarness
    let hr = HeartRateMonitor(preference: .automatic)
    var session: WorkoutSession!
    var finished: SessionRecord?
    var finalized: SessionRecord?

    init(program: WorkoutProgram?, quirks: SimulatedTreadmill.Quirks = .urtm047Like, settings: SessionSettings = SessionSettings()) {
        h = ControllerHarness(profile: .urtm047, quirks: quirks)
        session = WorkoutSession(program: program, controller: h.controller, heartRate: hr, settings: settings,
                                 treadmillName: "URTM047", simulated: true, log: h.log,
                                 clock: { [unowned h] in h.now }, wallClock: { Date(timeIntervalSince1970: 1_700_000_000) })
        h.controller.onTelemetry = { [unowned self] d, t in self.session.handleTelemetry(d, at: t) }
        h.controller.onEvent = { [unowned self] e in self.h.events.append(e); self.session.handle(controllerEvent: e) }
        session.onFinished = { [unowned self] in self.finished = $0 }
        session.onRecordFinalized = { [unowned self] in self.finalized = $0 }
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

    func testFullProgramRunsAndStopsTreadmill() throws {
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
        // Zones recalculées après coup (autre méthode) : même FC, nouvelles zones, même temps total.
        let same = try XCTUnwrap(r.zoneSettings)
        XCTAssertEqual(r.rezoned(with: same), r, "mêmes bornes : séance inchangée")
        let custom = HeartZoneSettings(maxHR: 200, method: .customBPM, customBounds: [90, 110, 125, 140, 160, 200])
        let z = r.rezoned(with: custom)
        XCTAssertEqual(z.zoneSettings, custom)
        XCTAssertEqual(z.zoneSeconds.reduce(0, +), r.zoneSeconds.reduce(0, +), accuracy: 3)
        XCTAssertGreaterThan(z.zoneSeconds[3], 60, "130 bpm : zone 3 avec ces seuils")
        XCTAssertGreaterThan(z.zoneSeconds[4], 20, "150 bpm : zone 4")
        XCTAssertEqual(z.samples.compactMap(\.zone).count, r.samples.compactMap(\.hr).count)
        XCTAssertEqual(z.samples.map(\.hr), r.samples.map(\.hr))
        XCTAssertEqual(z.id, r.id)
        XCTAssertEqual(r.rezoned(with: custom).rezoned(with: same).zoneSeconds.reduce(0, +),
                       r.zoneSeconds.reduce(0, +), accuracy: 3)
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

    func testFrozenTreadmillDistanceFallsBackToMeasuredSpeed() throws {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.frozenDistance = true
        let s = SessionHarness(program: program(), quirks: q)
        XCTAssertNoThrow(try s.session.start().get())
        s.run(200, hrBPM: 130)
        let r = try XCTUnwrap(s.finished)
        XCTAssertFalse(s.session.usesTreadmillDistance)
        XCTAssertEqual(r.distanceSource, .estimated, "distance intégrée depuis la vitesse mesurée")
        // 60 s à 4 km/h + 60 s à 6 km/h + 30 s à 3 km/h ≈ 192 m (rampes comprises).
        XCTAssertGreaterThan(r.distanceMeters, 150)
        XCTAssertLessThan(r.distanceMeters, 230)

        let normal = SessionHarness(program: program())
        XCTAssertNoThrow(try normal.session.start().get())
        normal.run(200, hrBPM: 130)
        XCTAssertEqual(try XCTUnwrap(normal.finished).distanceSource, .treadmill, "compteur du tapis plausible : retenu")
    }

    func testWatchLiveStatusCarriesClosedPauses() throws {
        let s = SessionHarness(program: program())
        XCTAssertNoThrow(try s.session.start().get())
        s.run(30, hrBPM: 120)
        s.session.pause()
        s.run(20, hrBPM: 120)
        XCTAssertNoThrow(try s.session.resume().get())
        s.run(20, hrBPM: 120)
        s.session.pause()
        let status = WatchLiveStatus.make(session: s.session, now: s.h.now, date: Date(timeIntervalSince1970: 1_700_000_100))
        let pauses = try XCTUnwrap(status.pauses)
        XCTAssertEqual(pauses.count, 1, "seule la pause terminée")
        XCTAssertEqual(pauses[0][1].timeIntervalSince(pauses[0][0]), 20, accuracy: 6)
        let belt = try XCTUnwrap(status.beltStartDate)
        let past = WatchWorkoutAlignment.pastPauses(start: belt, now: pauses[0][1].addingTimeInterval(60), live: status)
        XCTAssertEqual(past.count, 1)
        XCTAssertTrue(WatchWorkoutAlignment.pastPauses(start: pauses[0][1], now: pauses[0][1].addingTimeInterval(60), live: status).isEmpty,
                      "pause antérieure au début de l'exercice : ignorée")
    }

    func testZoneTimeRuleCountsBeltTimeOnly() throws {
        let s = SessionHarness(program: program())
        XCTAssertNoThrow(try s.session.start().get())
        s.run(40, hrBPM: 130)
        s.session.pause()
        s.run(30, hrBPM: 130)
        XCTAssertNoThrow(try s.session.resume().get())
        s.run(200, hrBPM: 130)
        let r = try XCTUnwrap(s.finished)
        let zones = try XCTUnwrap(r.zoneSettings)
        let secs = SessionAnalysis.zoneSeconds(r, zones: zones)
        XCTAssertEqual(secs, r.zoneSeconds, "même règle à l'enregistrement et à l'affichage")
        let active = SessionAnalysis.activeIntervals(r).reduce(0) { $0 + $1.end - $1.start }
        XCTAssertGreaterThan(SessionAnalysis.activeIntervals(r).count, 1, "pause exclue")
        // Toute la période de bande en mouvement est couverte (FC chaque seconde), pas la pause.
        XCTAssertEqual(secs.reduce(0, +), active, accuracy: 2)
        XCTAssertLessThan(secs.reduce(0, +), r.activeSeconds + 15)
        XCTAssertEqual(r.rezoned(with: zones).zoneSeconds, r.zoneSeconds)
    }

    func testPilotZoneBoundsKeptWhenZonesRecomputed() throws {
        let s = SessionHarness(program: .zone2Auto)
        XCTAssertNoThrow(try s.session.start().get())
        s.run(30, hrBPM: 120)
        s.session.stop()
        s.run(5, hrBPM: 120)
        let r = try XCTUnwrap(s.finished)
        let pilot = try XCTUnwrap(r.pilotZoneBounds)
        XCTAssertEqual(pilot, r.zoneSettings?.bounds)
        let other = HeartZoneSettings(maxHR: 200, method: .customBPM, customBounds: [90, 110, 125, 140, 160, 200])
        let z = r.rezoned(with: other)
        XCTAssertEqual(z.zoneSettings?.bounds, other.bounds)
        XCTAssertEqual(z.pilotZoneBounds, pilot, "limites du pilote conservées")
        let export = RythmeSessionExport(record: z)
        XCTAssertEqual(export.pilotZoneBounds, pilot)
        XCTAssertEqual(export.zones?.bounds, other.bounds)
        // Séance antérieure au champ : bornes enregistrées avec la séance.
        var old = r
        old.pilotZoneBounds = nil
        XCTAssertEqual(old.rezoned(with: other).pilotZoneBounds, pilot)
        // Sans phase pilotée : rien.
        let plain = SessionHarness(program: program())
        XCTAssertNoThrow(try plain.session.start().get())
        plain.run(200, hrBPM: 130)
        XCTAssertNil(try XCTUnwrap(plain.finished).effectivePilotZoneBounds)
    }

    func testZone2AutoStartsAtLearnedSpeedAndLearnsFromSession() throws {
        // Zones par défaut (FC max 200, sans repos) : Z2 = 120–139.
        let s = SessionHarness(program: .zone2Auto)
        s.session.learnedAutoStartKmh = 7.2
        XCTAssertNoThrow(try s.session.start().get())
        s.run(310, hrBPM: 100)
        XCTAssertEqual(s.session.autopilot?.targetKmh ?? 0, 7.2, accuracy: 0.01, "départ appris")
        s.run(240, hrBPM: 130)
        s.session.stop()
        s.run(5, hrBPM: 130)
        var r = try XCTUnwrap(s.finished)
        XCTAssertNil(SessionAnalysis.learnedAutoStart(for: .zone2Auto, records: [r]), "séance simulée : rien appris")
        r.simulated = false
        let learned = try XCTUnwrap(SessionAnalysis.learnedAutoStart(for: .zone2Auto, records: [r]))
        XCTAssertEqual(learned, 7.2, accuracy: 0.3)
        XCTAssertNil(SessionAnalysis.learnedAutoStart(for: .cardioBaseline, records: [r]))
    }

    func testWatchWorkoutStartAlignedOnBelt() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func live(_ state: WatchLiveStatus.State, belt: Date?, sent: Date = now) -> WatchLiveStatus {
            WatchLiveStatus(state: state, stateLabel: "", programName: nil, activeSeconds: 0, speedKmh: nil, inclinePercent: nil,
                            targetSpeedKmh: 0, targetInclinePercent: 0, phaseName: nil, phaseIndex: nil, phaseCount: 0,
                            phaseRemaining: nil, programRemaining: nil, nextPhaseName: nil, zoneBounds: [], zoneSeconds: [],
                            targetZone: nil, phoneHeartRate: nil, phoneHeartRateSource: nil, phoneZone: nil,
                            autopilotStatus: nil, autopilotManual: false, sentAt: sent, beltStartDate: belt)
        }
        let belt = now.addingTimeInterval(-120)
        XCTAssertEqual(WatchWorkoutAlignment.startDate(now: now, live: live(.running, belt: belt)), belt, "montre en retard de 2 min")
        XCTAssertEqual(WatchWorkoutAlignment.startDate(now: now, live: live(.starting, belt: nil)), now, "bande pas encore partie")
        XCTAssertEqual(WatchWorkoutAlignment.startDate(now: now, live: live(.running, belt: now.addingTimeInterval(-2))), now)
        XCTAssertEqual(WatchWorkoutAlignment.startDate(now: now, live: live(.running, belt: now.addingTimeInterval(-1140))), now.addingTimeInterval(-1140),
                       "exercice relancé 19 min après le départ (coupure) : aligné sur la bande")
        XCTAssertEqual(WatchWorkoutAlignment.startDate(now: now, live: live(.running, belt: now.addingTimeInterval(-5 * 3600))), now)
        XCTAssertEqual(WatchWorkoutAlignment.startDate(now: now, live: live(.running, belt: belt, sent: now.addingTimeInterval(-60))), now,
                       "état trop ancien")
        XCTAssertEqual(WatchWorkoutAlignment.startDate(now: now, live: nil), now)
    }

    func testLegacyDefaultZonesDetected() {
        var legacy = HeartZoneSettings(maxHR: 200, method: .percentOfMax)
        XCTAssertTrue(legacy.isLegacyDefault)
        legacy.maxHRIsUserValue = true
        XCTAssertFalse(legacy.isLegacyDefault, "FC max saisie : réglage choisi, pas de migration")
        var custom = HeartZoneSettings(method: .percentOfMax)
        custom.percentBounds = [0.5, 0.62, 0.72, 0.82, 0.9, 1.0]
        XCTAssertFalse(custom.isLegacyDefault)
        XCTAssertFalse(HeartZoneSettings().isLegacyDefault, "méthode Rythme")
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
            .workoutMetadata(standard: StandardWorkoutMetadata(syncIdentifier: "X", syncVersion: 2, indoor: true),
                             foulee: ["FouleeProgram": .string("Collines"), "FouleeMaxSpeedKmh": .number(6.5)]),
        ]
        for m in msgs { XCTAssertEqual(try WatchMessage.decode(m.encoded()), m) }
    }
}


/// Règles Apple Santé : propriétaire unique, séance, échantillons, métadonnées, anti-doublons.
final class HealthWritePlanTests: XCTestCase {
    let inputs = HealthWritePlan.Inputs(healthEnabled: true, watchWorkoutUsed: false, bodyMassKg: 70)

    func phoneSessionWithBelt(program: WorkoutProgram? = nil, minutes: Double = 5, pauseSeconds: Double = 0,
                              speed: Double? = nil) -> SessionRecord {
        makePhoneSessionWithBelt(program: program, minutes: minutes, pauseSeconds: pauseSeconds, speed: speed)
    }

    func testPhoneOwnerWithBeltWritesEverythingInShortChunks() {
        let r = phoneSessionWithBelt()
        let p = HealthWritePlan.make(record: r, inputs: inputs)
        XCTAssertEqual(p.owner, .phone)
        XCTAssertEqual(p.activityType, .walking)
        XCTAssertEqual(p.standard, StandardWorkoutMetadata(syncIdentifier: r.id.uuidString, syncVersion: 1, indoor: true))
        XCTAssertEqual(p.fouleeMetadata[FouleeMetadataKey.sessionID], .string(r.id.uuidString))
        XCTAssertEqual(p.fouleeMetadata[FouleeMetadataKey.program], .string("Séance libre"))
        XCTAssertEqual(p.fouleeMetadata[FouleeMetadataKey.energySource], .string("acsm"))
        XCTAssertNotNil(p.fouleeMetadata[FouleeMetadataKey.averageSpeed])
        XCTAssertNotNil(p.fouleeMetadata[FouleeMetadataKey.maxSpeed])
        // Début = démarrage réel de la bande (après le compte à rebours), pas l'appui sur Démarrer.
        XCTAssertGreaterThan(p.start, r.startDate)
        XCTAssertEqual(p.start, r.beltStartDate)
        XCTAssertEqual(p.end, r.beltStopDate)
        let kinds = Set(p.quantities.map(\.kind))
        XCTAssertEqual(kinds, [.distanceWalkingRunning, .stepCount, .activeEnergyBurned, .heartRate])
        // Tranches d'au plus 1 minute, jamais un bloc unique.
        for q in p.quantities where q.kind != .heartRate {
            XCTAssertLessThanOrEqual(q.end.timeIntervalSince(q.start), 60.001)
            XCTAssertGreaterThan(q.value, 0, "jamais de 0 à la place d'une donnée")
            XCTAssertTrue(q.start >= p.start && q.end <= p.end)
        }
        XCTAssertGreaterThan(p.quantities.filter { $0.kind == .distanceWalkingRunning }.count, 3)
        let distance = p.quantities.filter { $0.kind == .distanceWalkingRunning }.map(\.value).reduce(0, +)
        XCTAssertEqual(distance, r.distanceMeters, accuracy: 2)
        let steps = p.quantities.filter { $0.kind == .stepCount }.map(\.value).reduce(0, +)
        XCTAssertEqual(steps, Double(r.steps ?? 0), accuracy: 2)
        // FC : ~1 mesure / 5 s, dont les 2 minutes après l'arrêt (non associées, hors séance).
        let hr = p.quantities.filter { $0.kind == .heartRate }.sorted { $0.start < $1.start }
        for (a, b) in zip(hr, hr.dropFirst()) { XCTAssertGreaterThanOrEqual(b.start.timeIntervalSince(a.start), 4.5) }
        let post = hr.filter { !$0.associated }
        XCTAssertGreaterThanOrEqual(post.count, 20)
        XCTAssertTrue(post.allSatisfy { $0.start > p.end && $0.start <= p.end.addingTimeInterval(120) })
        XCTAssertTrue(post.allSatisfy { $0.value == 100 })
        XCTAssertEqual(p.sampleMetadata[FouleeMetadataKey.sessionID], .string(r.id.uuidString))
    }

    func testWatchOwnerMeansPhoneWritesNothing() {
        let r = phoneSessionWithBelt(minutes: 2)
        let p = HealthWritePlan.make(record: r, inputs: .init(healthEnabled: true, watchWorkoutUsed: true, bodyMassKg: 70))
        XCTAssertEqual(p.owner, .watch)
        XCTAssertTrue(p.quantities.isEmpty)
        XCTAssertTrue(p.segments.isEmpty)
        XCTAssertFalse(p.discardWatchWorkout)
        let (std, meta) = HealthWritePlan.watchMetadata(record: r)
        XCTAssertEqual(std.syncIdentifier, r.id.uuidString)
        XCTAssertEqual(meta[FouleeMetadataKey.program], .string("Séance libre"))
        XCTAssertNil(meta[FouleeMetadataKey.energySource], "l'énergie de la Watch est la sienne")
    }

    func testHIITProgramWithSegments() {
        let program = WorkoutProgram(name: "Intervalles marche/course", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 60, speedKmh: 4)),
            .block(.init(name: "Sprints", repeatCount: 2, phases: [
                .init(name: "Sprint", kind: .work, durationSeconds: 40, speedKmh: 8),
                .init(name: "Récupération", kind: .recovery, durationSeconds: 40, speedKmh: 4.5),
            ])),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 40, speedKmh: 3.5)),
        ])
        let r = phoneSessionWithBelt(program: program, minutes: 6)
        let p = HealthWritePlan.make(record: r, inputs: inputs)
        XCTAssertEqual(p.activityType, .hiit)
        XCTAssertEqual(p.segments.map(\.name), ["Échauffement", "Sprint · 1/2", "Récupération · 1/2", "Sprint · 2/2",
                                                "Récupération · 2/2", "Retour au calme"])
        XCTAssertEqual(p.segments[1].targetSpeedKmh, 8)
        XCTAssertEqual(p.segments[1].end.timeIntervalSince(p.segments[1].start), 40, accuracy: 1)
        XCTAssertTrue(p.segments.allSatisfy { $0.start >= p.start && $0.end <= p.end })
    }

    func testPausesExcludedFromDuration() {
        let r = phoneSessionWithBelt(minutes: 2, pauseSeconds: 40)
        let p = HealthWritePlan.make(record: r, inputs: inputs)
        XCTAssertEqual(p.pauses.count, 1)
        let pause = p.pauses[0].end.timeIntervalSince(p.pauses[0].start)
        // Pause = de la demande de pause à la reprise effective de la bande (compte à rebours inclus).
        XCTAssertGreaterThanOrEqual(pause, 40)
        XCTAssertEqual(p.activeDuration, p.end.timeIntervalSince(p.start) - pause, accuracy: 0.01)
    }

    func testRunningDetectedFromSpeed() {
        let r = phoneSessionWithBelt(minutes: 3, speed: 8)
        XCTAssertEqual(HealthWritePlan.make(record: r, inputs: inputs).activityType, .running)
    }

    func testEnergyFromTreadmillWithoutBodyMass() {
        let r = phoneSessionWithBelt(minutes: 2)
        let p = HealthWritePlan.make(record: r, inputs: .init(healthEnabled: true, watchWorkoutUsed: false, bodyMassKg: nil))
        XCTAssertEqual(p.energySource, "tapis")
        XCTAssertEqual(p.fouleeMetadata[FouleeMetadataKey.energySource], .string("tapis"))
        XCTAssertFalse(p.quantities.filter { $0.kind == .activeEnergyBurned }.isEmpty)
    }

    func testNothingWrittenWhenShortSimulatedOrDisabled() {
        var r = phoneSessionWithBelt(minutes: 2)
        XCTAssertEqual(HealthWritePlan.make(record: r, inputs: .init(healthEnabled: false, watchWorkoutUsed: false, bodyMassKg: 70)).owner, .none)
        r.simulated = true
        XCTAssertEqual(HealthWritePlan.make(record: r, inputs: inputs).owner, .none)
        r.simulated = false
        r.beltStopDate = r.beltStartDate.map { $0.addingTimeInterval(45) }
        let short = HealthWritePlan.make(record: r, inputs: inputs)
        XCTAssertEqual(short.owner, .none)
        XCTAssertTrue(short.reason.contains("moins d'1 minute"))
        let watchShort = HealthWritePlan.make(record: r, inputs: .init(healthEnabled: true, watchWorkoutUsed: true, bodyMassKg: 70))
        XCTAssertTrue(watchShort.discardWatchWorkout)
    }

    func testNoTreadmillStepsMeansNoStepsWritten() {
        let s = SessionHarness(program: nil)
        _ = s.session.start()
        s.run(120)
        s.session.stop()
        s.run(30)
        var r = try! XCTUnwrap(s.finalized)
        r.simulated = false
        let p = HealthWritePlan.make(record: r, inputs: inputs)
        XCTAssertFalse(p.quantities.contains { $0.kind == .stepCount })
        XCTAssertFalse(p.quantities.contains { $0.kind == .heartRate })
        XCTAssertTrue(p.notWritten.contains { $0.hasPrefix("Pas") })
        XCTAssertTrue(p.notWritten.contains { $0.hasPrefix("FC") })
    }

    // MARK: - Anti-doublons

    func plan(version: Int = 1) -> HealthWritePlan {
        var r = SessionRecord(startDate: Date(timeIntervalSince1970: 0), program: nil, treadmillName: nil, profileID: nil, simulated: false)
        r.beltStartDate = Date(timeIntervalSince1970: 100)
        r.beltStopDate = Date(timeIntervalSince1970: 1_300)
        r.revision = version
        return HealthWritePlan.make(record: r, inputs: inputs)
    }

    func testSameSessionTwiceIsNotWrittenAgain() {
        let p = plan()
        let mine = ExistingHealthWorkout(uuid: "A", sourceName: "Foulée", syncIdentifier: p.standard.syncIdentifier, syncVersion: 1,
                                         start: p.start, end: p.end)
        XCTAssertEqual(HealthWriteDecision.decide(plan: p, existing: [mine]), .alreadySaved(uuid: "A"))
        XCTAssertEqual(HealthWriteDecision.decide(plan: p, existing: []), .write(replacing: []))
    }

    func testCorrectionReplacesPreviousVersion() {
        let p = plan(version: 2)
        XCTAssertEqual(p.standard.syncVersion, 2)
        let old = ExistingHealthWorkout(uuid: "A", sourceName: "Foulée", syncIdentifier: p.standard.syncIdentifier, syncVersion: 1,
                                        start: p.start, end: p.end)
        XCTAssertEqual(HealthWriteDecision.decide(plan: p, existing: [old]), .write(replacing: ["A"]))
    }

    func testOverlapOver50PercentBlocksWriting() {
        let p = plan()
        let watch = ExistingHealthWorkout(uuid: "W", sourceName: "Apple Watch de Houssem", syncIdentifier: nil, syncVersion: nil,
                                          start: p.start.addingTimeInterval(-60), end: p.start.addingTimeInterval(800))
        XCTAssertEqual(HealthWriteDecision.decide(plan: p, existing: [watch]), .overlapping(by: "Apple Watch de Houssem"))
        let small = ExistingHealthWorkout(uuid: "U", sourceName: "UR", syncIdentifier: nil, syncVersion: nil,
                                          start: p.start, end: p.start.addingTimeInterval(300))
        XCTAssertEqual(HealthWriteDecision.decide(plan: p, existing: [small]), .write(replacing: []))
        // Watch et iPhone en même temps : même si une ancienne version Foulée existe, la Watch gagne.
        let mineOld = ExistingHealthWorkout(uuid: "A", sourceName: "Foulée", syncIdentifier: p.standard.syncIdentifier, syncVersion: 0,
                                            start: p.start, end: p.end)
        XCTAssertEqual(HealthWriteDecision.decide(plan: p, existing: [mineOld, watch]), .overlapping(by: "Apple Watch de Houssem"))
    }

    func testReportText() {
        let r = phoneSessionWithBelt(minutes: 2)
        let p = HealthWritePlan.make(record: r, inputs: inputs)
        let rep = HealthWriteReport(plan: p, outcome: "écrit", workoutUUID: "X")
        XCTAssertTrue(rep.text.contains("SyncVersion = 1"))
        XCTAssertTrue(rep.text.contains("FouleeProgram = Séance libre"))
        XCTAssertTrue(rep.quantities.allSatisfy { $0.kind == .heartRate || $0.maxChunkSeconds <= 60.001 })
        let data = try! CoreJSON.encode(rep)
        XCTAssertEqual(try! CoreJSON.decode(HealthWriteReport.self, from: data).text, rep.text)
    }
}

/// Zones identiques à Rythme et calcul FC max / repos depuis Santé.
final class RythmeZoneTests: XCTestCase {
    func testDefaultMethodIsRythmeReserve() {
        let z = HeartZoneSettings(maxHR: 190, restingHR: 60)
        XCTAssertEqual(z.method, .rythme)
        XCTAssertEqual(z.bounds, [0, 138, 151, 164, 177, 190])
        XCTAssertEqual(z.zone(for: 40), 1, "pas de plancher en zone 1")
        XCTAssertEqual(z.zone(for: 137), 1)
        XCTAssertEqual(z.zone(for: 138), 2)
        XCTAssertEqual(z.zone(for: 164), 4)
        XCTAssertEqual(z.zone(for: 177), 5)
        XCTAssertEqual(z.zone(for: 230), 5)
        // Cas réel : FC max 193, repos moyen 59 → Z2 commence à 139,4 : 139 en Z1, 140 en Z2
        // (premier bpm de la zone, comme Rythme et l'Apple Watch ; pas l'arrondi au plus proche).
        var real = HeartZoneSettings(maxHR: 193, restingHR: 59)
        XCTAssertEqual(real.bounds[1], 140)
        XCTAssertEqual(real.zone(for: 139), 1)
        XCTAssertEqual(real.zone(for: 140), 2)
        XCTAssertEqual(real.zones[1].inclusiveText, "140–152")
        XCTAssertEqual(real.zones[0].inclusiveText, "≤ 139")
        XCTAssertEqual(real.bounds[2], 153, "59 + 0,7 × 134 = 152,8 → 153")
        // FC de repos décimale de Santé : bornes calculées sans arrondir le repos.
        var decimal = HeartZoneSettings(maxHR: 193, restingHR: 58)
        XCTAssertEqual(decimal.bounds[1], 139, "repos 58 : 58 + 0,6 × 135 = 139,0")
        decimal.restingHRExact = 58.4
        XCTAssertEqual(decimal.bounds[1], 140, "repos 58,4 : 58,4 + 0,6 × 134,6 = 139,16 → 140")
        decimal.restingHRIsUserValue = true
        XCTAssertEqual(decimal.bounds[1], 139, "repos saisi dans Foulée : valeur entière")
        let res = ZoneProfileResolver.resolve(userMax: 193, userResting: nil, birthDate: nil, now: Date(),
                                              highHR: [], restingHR: [59, 60, 59, 60, 60])
        XCTAssertEqual(res.restingHR, 60)
        XCTAssertEqual(res.restingHRExact ?? 0, 59.6, accuracy: 0.0001)
        let noRest = HeartZoneSettings(maxHR: 190, restingHR: nil)
        XCTAssertEqual(noRest.bounds, [0, 114, 133, 152, 171, 190])
        XCTAssertTrue(noRest.methodDescription.contains("FC de repos indisponible"))
    }

    func testOldSettingsStillDecode() throws {
        let json = #"{"maxHR":200,"method":"percentOfMax","percentBounds":[0.5,0.6,0.7,0.8,0.9,1],"customBounds":[100,120,140,160,180,200]}"#
        let z = try JSONDecoder().decode(HeartZoneSettings.self, from: Data(json.utf8))
        XCTAssertEqual(z.method, .percentOfMax)
        XCTAssertFalse(z.maxHRIsUserValue)
        let empty = try JSONDecoder().decode(HeartZoneSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.method, .rythme)
    }

    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func pts(_ values: [(Double, Double)]) -> [ZoneProfileResolver.HRPoint] {
        values.map { ZoneProfileResolver.HRPoint(date: now.addingTimeInterval(-86_400 * 30 + $0.0), bpm: $0.1) }
    }

    func testSustainedMaxIgnoresIsolatedSpikesAndAbove230() {
        let p = pts([(0, 185), (60, 182), (10_000, 205), (20_000, 240), (20_030, 238)])
        XCTAssertEqual(ZoneProfileResolver.sustainedMax(p)?.bpm, 185)
        let neighbourBelow170 = pts([(0, 172), (90, 168)])
        XCTAssertEqual(ZoneProfileResolver.sustainedMax(neighbourBelow170)?.bpm, 172)
        let tooFar = pts([(0, 190), (130, 189)])
        XCTAssertNil(ZoneProfileResolver.sustainedMax(tooFar))
        // 190 isolé (voisin 6 bpm en dessous) est écarté ; 184 est confirmé par 190 → 184.
        let tooLow = pts([(0, 190), (60, 184)])
        XCTAssertEqual(ZoneProfileResolver.sustainedMax(tooLow)?.bpm, 184)
    }

    func testResolverRules() {
        let birth = Calendar(identifier: .gregorian).date(byAdding: .year, value: -40, to: now)!
        // 220 − 40 = 180 ; FC tenue 186 → 186.
        var r = ZoneProfileResolver.resolve(userMax: nil, userResting: nil, birthDate: birth, now: now,
                                            highHR: pts([(0, 186), (30, 183)]), restingHR: [58, 62, 60])
        XCTAssertEqual(r.maxHR, 186)
        XCTAssertEqual(r.restingHR, 60)
        // FC tenue plus basse que 220 − âge → 180.
        r = ZoneProfileResolver.resolve(userMax: nil, userResting: nil, birthDate: birth, now: now,
                                        highHR: pts([(0, 175), (30, 174)]), restingHR: [])
        XCTAssertEqual(r.maxHR, 180)
        XCTAssertNil(r.restingHR)
        // Valeur saisie prioritaire.
        r = ZoneProfileResolver.resolve(userMax: 200, userResting: nil, birthDate: birth, now: now, highHR: [], restingHR: [55])
        XCTAssertEqual(r.maxHR, 200)
        XCTAssertEqual(r.maxSource, "saisie dans Foulée")
        // FC repos incohérente ignorée (> FC max − 40, ou < 30).
        r = ZoneProfileResolver.resolve(userMax: 150, userResting: nil, birthDate: nil, now: now, highHR: [], restingHR: [115])
        XCTAssertNil(r.restingHR)
        r = ZoneProfileResolver.resolve(userMax: 190, userResting: nil, birthDate: nil, now: now, highHR: [], restingHR: [25])
        XCTAssertNil(r.restingHR)
        // Rien dans Santé : valeur par défaut, signalée.
        r = ZoneProfileResolver.resolve(userMax: nil, userResting: nil, birthDate: nil, now: now, highHR: [], restingHR: [])
        XCTAssertEqual(r.maxHR, 200)
        XCTAssertTrue(r.maxSource.contains("par défaut"))
    }
}

/// Imprime les rapports d'exemple (docs/SANTE.md) : FOULEE_PRINT_EXAMPLES=1 swift test --filter HealthExamples
final class HealthExamples: XCTestCase {
    func testPrintExamples() throws {
        guard ProcessInfo.processInfo.environment["FOULEE_PRINT_EXAMPLES"] != nil else { return }
        let inputs = HealthWritePlan.Inputs(healthEnabled: true, watchWorkoutUsed: false, bodyMassKg: 72)
        let phone = makePhoneSessionWithBelt(minutes: 4, pauseSeconds: 30)
        let hiitProgram = WorkoutProgram(name: "Intervalles marche/course", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 120, speedKmh: 4.5)),
            .block(.init(name: "Sprints", repeatCount: 3, phases: [
                .init(name: "Sprint", kind: .work, durationSeconds: 60, speedKmh: 8.5),
                .init(name: "Récupération", kind: .recovery, durationSeconds: 60, speedKmh: 5),
            ])),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 60, speedKmh: 4)),
        ])
        let hiit = makePhoneSessionWithBelt(program: hiitProgram, minutes: 9)
        let cases: [(String, SessionRecord, HealthWritePlan.Inputs)] = [
            ("iPhone seul + ceinture", phone, inputs),
            ("Watch propriétaire", phone, .init(healthEnabled: true, watchWorkoutUsed: true, bodyMassKg: 72)),
            ("HIIT avec phases", hiit, inputs),
        ]
        for (name, r, i) in cases {
            let p = HealthWritePlan.make(record: r, inputs: i)
            print("=== EXEMPLE: \(name) ===")
            print(HealthWriteReport(plan: p, outcome: "simulé (plan calculé, non écrit)", workoutUUID: nil).text)
            print("=== FIN ===")
        }
    }
}

/// Séance réelle simulée : ceinture BLE, pas fournis par le tapis, arrêt puis 2 min de récupération.
func makePhoneSessionWithBelt(program: WorkoutProgram? = nil, minutes: Double = 5, pauseSeconds: Double = 0,
                              speed: Double? = nil) -> SessionRecord {
    var q = SimulatedTreadmill.Quirks.urtm047Like
    q.reportsStepCount = true
    let s = SessionHarness(program: program, quirks: q)
    XCTAssertNoThrow(try s.session.start().get())
    s.run(15, hrBPM: 120)
    if let v = speed { _ = s.session.setManualSpeed(v) }
    if pauseSeconds > 0 {
        s.run(minutes * 30, hrBPM: 130)
        s.session.pause()
        s.run(pauseSeconds, hrBPM: 110)
        _ = s.session.resume()
        s.run(minutes * 30, hrBPM: 135)
    } else {
        s.run(minutes * 60, hrBPM: 132)
    }
    if s.session.status != .finished { s.session.stop() }
    s.run(150, hrBPM: 100)
    var r = try! XCTUnwrap(s.finalized, "séance non finalisée")
    r.simulated = false
    return r
}
