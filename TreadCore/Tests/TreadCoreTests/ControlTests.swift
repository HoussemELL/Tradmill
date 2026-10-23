import XCTest
@testable import TreadCore

/// Écrivain factice : enregistre les écritures, réponses injectées à la main.
final class RecordingWriter: ControlPointWriter {
    var writes: [[UInt8]] = []
    var accept = true
    func writeControlPoint(_ bytes: [UInt8]) -> Bool {
        writes.append(bytes)
        return accept
    }
}

final class CommandQueueTests: XCTestCase {
    var now: TimeInterval = 0
    var queue: CommandQueue!
    var writer: RecordingWriter!

    override func setUp() {
        now = 0
        writer = RecordingWriter()
        queue = CommandQueue(configuration: .init(responseTimeout: 3, minimumSpacing: 0.2))
        queue.writer = writer
        queue.log = DiagnosticLog()
        queue.setLinkReady(true, now: now)
    }

    func testRefusedWhenLinkNotReady() {
        queue.setLinkReady(false, now: 0)
        var outcome: CommandOutcome?
        queue.enqueue(.requestControl, origin: .user, now: 0) { outcome = $0 }
        XCTAssertEqual(outcome, .notReady)
        XCTAssertTrue(writer.writes.isEmpty)
    }

    func testOneCommandInFlightAndSpacing() {
        var results: [CommandOutcome] = []
        queue.enqueue(.requestControl, origin: .user, now: now) { results.append($0) }
        queue.enqueue(.startOrResume, origin: .user, now: now) { results.append($0) }
        XCTAssertEqual(writer.writes, [[0x00]])
        // Réponse : la suivante attend l'espacement minimal.
        now = 0.1
        queue.handleIndication([0x80, 0x00, 0x01], now: now)
        XCTAssertEqual(results, [.success])
        XCTAssertEqual(writer.writes.count, 1)
        now = 0.25
        queue.tick(now: now)
        XCTAssertEqual(writer.writes.last, [0x07])
        queue.handleIndication([0x80, 0x07, 0x01], now: now)
        XCTAssertEqual(results, [.success, .success])
        XCTAssertTrue(queue.isIdle)
    }

    func testNegativeResponse() {
        var outcome: CommandOutcome?
        queue.enqueue(.setTargetSpeed(kmh: 7), origin: .user, now: now) { outcome = $0 }
        queue.handleIndication([0x80, 0x02, 0x05], now: 0.1)
        XCTAssertEqual(outcome, .rejected(.controlNotPermitted))
        queue.enqueue(.setTargetSpeed(kmh: 20), origin: .user, now: 1) { outcome = $0 }
        queue.handleIndication([0x80, 0x02, 0x03], now: 1.1)
        XCTAssertEqual(outcome, .rejected(.invalidParameter))
    }

    func testTimeoutWithoutAutomaticRetry() {
        var outcome: CommandOutcome?
        queue.enqueue(.startOrResume, origin: .user, now: now) { outcome = $0 }
        queue.tick(now: 2.9)
        XCTAssertNil(outcome)
        queue.tick(now: 3.1)
        XCTAssertEqual(outcome, .timeout)
        queue.tick(now: 10)
        XCTAssertEqual(writer.writes.count, 1, "aucune répétition automatique")
        // Réponse tardive : ignorée sans planter ni compléter autre chose.
        XCTAssertTrue(queue.handleIndication([0x80, 0x07, 0x01], now: 11))
    }

    func testMismatchedResponseIsIgnored() {
        var outcome: CommandOutcome?
        queue.enqueue(.setTargetSpeed(kmh: 5), origin: .user, now: now) { outcome = $0 }
        queue.handleIndication([0x80, 0x03, 0x01], now: 0.1)
        XCTAssertNil(outcome)
        queue.handleIndication([0x80, 0x02, 0x01], now: 0.2)
        XCTAssertEqual(outcome, .success)
    }

    func testPendingSpeedCommandsAreCoalesced() {
        var outcomes: [String: CommandOutcome] = [:]
        queue.enqueue(.requestControl, origin: .user, now: now)
        queue.enqueue(.setTargetSpeed(kmh: 5), origin: .user, now: now) { outcomes["5"] = $0 }
        queue.enqueue(.setTargetSpeed(kmh: 6), origin: .user, now: now) { outcomes["6"] = $0 }
        queue.enqueue(.setTargetSpeed(kmh: 7), origin: .user, now: now) { outcomes["7"] = $0 }
        XCTAssertEqual(queue.pendingCommands, [.setTargetSpeed(kmh: 7)])
        XCTAssertEqual(outcomes["5"], .cancelled("remplacée par une consigne plus récente"))
        XCTAssertEqual(outcomes["6"], .cancelled("remplacée par une consigne plus récente"))
        queue.handleIndication([0x80, 0x00, 0x01], now: 0.1)
        queue.tick(now: 0.5)
        XCTAssertEqual(writer.writes.last, [0x02, 0xBC, 0x02])
    }

    func testStopJumpsQueueAndCancelsSetpoints() {
        var startOutcome: CommandOutcome?
        var speedOutcome: CommandOutcome?
        queue.enqueue(.requestControl, origin: .user, now: now)
        queue.enqueue(.setTargetSpeed(kmh: 5), origin: .program, now: now) { speedOutcome = $0 }
        queue.enqueue(.startOrResume, origin: .user, now: now) { startOutcome = $0 }
        queue.enqueue(.stop, origin: .safety, now: now)
        XCTAssertEqual(queue.pendingCommands, [.stop])
        XCTAssertEqual(speedOutcome, .cancelled("annulée par Stop"))
        XCTAssertEqual(startOutcome, .cancelled("annulée par Stop"))
        queue.handleIndication([0x80, 0x00, 0x01], now: 0.1)
        queue.tick(now: 0.5)
        XCTAssertEqual(writer.writes.last, [0x08, 0x01])
    }

    func testDoubleStartPrevented() {
        var second: CommandOutcome?
        queue.enqueue(.startOrResume, origin: .user, now: now)
        queue.enqueue(.startOrResume, origin: .user, now: now) { second = $0 }
        XCTAssertEqual(second, .cancelled("démarrage déjà en cours"))
        XCTAssertEqual(writer.writes.count, 1)
    }

    func testWriteErrorFailsCommand() {
        var outcome: CommandOutcome?
        queue.enqueue(.requestControl, origin: .user, now: now) { outcome = $0 }
        queue.handleWriteResult(error: "Insufficient authorization", now: 0.05)
        XCTAssertEqual(outcome, .writeFailed("Insufficient authorization"))
    }

    func testLinkLossCancelsEverything() {
        var a: CommandOutcome?
        var b: CommandOutcome?
        queue.enqueue(.requestControl, origin: .user, now: now) { a = $0 }
        queue.enqueue(.startOrResume, origin: .user, now: now) { b = $0 }
        queue.setLinkReady(false, now: 0.1)
        XCTAssertEqual(a, .notReady)
        XCTAssertEqual(b, .notReady)
        XCTAssertTrue(queue.isIdle)
    }
}

/// Banc de test : contrôleur + tapis simulé + horloge manuelle.
final class ControllerHarness {
    var now: TimeInterval = 0
    let log = DiagnosticLog(clock: { Date(timeIntervalSince1970: 0) })
    var controller: TreadmillController!
    var link: SimulatedFTMSLink!
    var events: [ControllerEvent] = []

    init(profile: TreadmillProfile, quirks: SimulatedTreadmill.Quirks) {
        controller = TreadmillController(profile: profile, log: log, clock: { [unowned self] in self.now })
        controller.onEvent = { [unowned self] in self.events.append($0) }
        link = SimulatedFTMSLink(treadmill: SimulatedTreadmill(quirks: quirks), clock: { [unowned self] in self.now })
        link.connect(to: controller)
    }

    func run(seconds: TimeInterval, step: TimeInterval = 0.05) {
        let end = now + seconds
        while now < end {
            now += step
            link.advance()
            controller.tick()
        }
    }

    var sentCommands: [ControlCommand] { link.treadmill.receivedCommands }
}

final class TreadmillControllerTests: XCTestCase {

    func testURTM047StartSequenceOrder() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        XCTAssertNoThrow(try h.controller.start(targetSpeed: 7, targetIncline: 2).get())
        h.run(seconds: 30)
        XCTAssertEqual(Array(h.sentCommands.prefix(3)),
                       [.requestControl, .setTargetSpeed(kmh: 1.5), .startOrResume])
        // La consigne du palier part après le mouvement observé, sans nouveau Start.
        XCTAssertEqual(h.sentCommands.filter { $0 == .startOrResume }.count, 1)
        XCTAssertTrue(h.sentCommands.contains(.setTargetSpeed(kmh: 7)))
        XCTAssertTrue(h.sentCommands.contains(.setTargetInclination(percent: 2)))
        XCTAssertEqual(h.controller.state, .running)
        XCTAssertEqual(h.controller.speed.status, .reached)
        XCTAssertEqual(h.controller.telemetry.speedKmh ?? 0, 7, accuracy: 0.01)
        XCTAssertTrue(h.events.contains(.beltStarted))
        XCTAssertTrue(h.events.contains(.speedReached(7)))
    }

    func testGenericSequenceFailsToMoveOnURTM047LikeTreadmill() {
        // Reproduit l'observation : Request Control → Start ne produit pas de mouvement.
        let h = ControllerHarness(profile: .genericFTMS, quirks: .urtm047Like)
        XCTAssertNoThrow(try h.controller.start(targetSpeed: 5, targetIncline: nil).get())
        h.run(seconds: 20)
        XCTAssertEqual(h.controller.state, .startUnconfirmed)
        XCTAssertEqual(h.sentCommands.filter { $0 == .startOrResume }.count, 1, "pas de nouvel essai automatique")
        XCTAssertTrue(h.events.contains { if case .startFailed = $0 { return true }; return false })
    }

    func testAcknowledgedButNotObservedSpeedIsReported() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.ignoresAllSpeedCommands = true
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        // Le tapis ignore toutes les vitesses : Start sans consigne prise en compte ⇒ pas de mouvement.
        // On autorise donc le démarrage par défaut pour isoler le cas « acquitté mais non observé ».
        h.link.treadmill.quirks.requiresSpeedBeforeStart = false
        XCTAssertNoThrow(try h.controller.start(targetSpeed: 7, targetIncline: nil).get())
        h.run(seconds: 120)
        XCTAssertEqual(h.controller.state, .running)
        XCTAssertEqual(h.controller.speed.acknowledged, 7)
        XCTAssertEqual(h.controller.speed.status, .mismatch)
        XCTAssertEqual(h.controller.telemetry.speedKmh ?? 0, 1.0, accuracy: 0.01)
        XCTAssertTrue(h.events.contains(.speedMismatch(target: 7, observed: 1.0)))
        // Un seul renvoi de la consigne (profil URTM047), jamais de Start supplémentaire.
        XCTAssertEqual(h.sentCommands.filter { $0 == .setTargetSpeed(kmh: 7) }.count, 2)
        XCTAssertEqual(h.sentCommands.filter { $0 == .startOrResume }.count, 1)
    }

    func testSpeedChangeWhileRunningDoesNotResendStart() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        _ = h.controller.start(targetSpeed: 4, targetIncline: nil)
        h.run(seconds: 20)
        h.controller.setTargetSpeed(6, origin: .program)
        h.run(seconds: 15)
        h.controller.setTargetSpeed(3.5, origin: .user)
        h.run(seconds: 15)
        XCTAssertEqual(h.sentCommands.filter { $0 == .startOrResume }.count, 1)
        XCTAssertEqual(h.controller.telemetry.speedKmh ?? 0, 3.5, accuracy: 0.01)
        XCTAssertEqual(h.controller.speed.status, .reached)
    }

    func testDoubleStartRejected() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        XCTAssertNoThrow(try h.controller.start(targetSpeed: 4, targetIncline: nil).get())
        if case .success = h.controller.start(targetSpeed: 4, targetIncline: nil) {
            XCTFail("le second démarrage doit être refusé")
        }
        h.run(seconds: 20)
        if case .success = h.controller.start(targetSpeed: 4, targetIncline: nil) {
            XCTFail("démarrage refusé tant que le tapis tourne")
        }
    }

    func testOutOfRangeIsRejectedNotClamped() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        guard case .failure(.outOfRange) = h.controller.start(targetSpeed: 14, targetIncline: nil) else {
            return XCTFail("vitesse hors plage acceptée")
        }
        guard case .failure(.outOfRange) = h.controller.start(targetSpeed: 5, targetIncline: 12) else {
            return XCTFail("inclinaison hors plage acceptée")
        }
        XCTAssertTrue(h.sentCommands.isEmpty)
    }

    func testPauseResumeAndStopConfirmation() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        _ = h.controller.start(targetSpeed: 5, targetIncline: nil)
        h.run(seconds: 25)
        XCTAssertNoThrow(try h.controller.pause().get())
        XCTAssertEqual(h.controller.state, .pausing)
        h.run(seconds: 15)
        XCTAssertEqual(h.controller.state, .paused)
        XCTAssertNoThrow(try h.controller.resume(targetSpeed: 5, targetIncline: nil).get())
        h.run(seconds: 25)
        XCTAssertEqual(h.controller.state, .running)
        XCTAssertEqual(h.controller.telemetry.speedKmh ?? 0, 5, accuracy: 0.01)
        XCTAssertNoThrow(try h.controller.stop().get())
        XCTAssertEqual(h.controller.state, .stopping, "pas d'arrêt affiché avant confirmation")
        h.run(seconds: 15)
        XCTAssertEqual(h.controller.state, .stopped)
        XCTAssertTrue(h.events.contains(.stopConfirmed))
    }

    func testSafetyKeyStopsAndCancelsSequence() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        _ = h.controller.start(targetSpeed: 5, targetIncline: nil)
        h.run(seconds: 20)
        h.link.treadmill.pullSafetyKey(now: h.now)
        h.run(seconds: 1)
        XCTAssertEqual(h.controller.state, .stopped)
        XCTAssertTrue(h.events.contains(.machineStopped(reason: "clé de sécurité", paused: false)))
    }

    func testLinkLossIsReportedAndNoAutomaticRestart() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        _ = h.controller.start(targetSpeed: 5, targetIncline: nil)
        h.run(seconds: 20)
        let countBefore = h.sentCommands.count
        h.link.disconnect()
        XCTAssertEqual(h.controller.state, .linkLost)
        XCTAssertTrue(h.events.contains(.linkLost(wasActive: true)))
        if case .success = h.controller.stop() { XCTFail("un arrêt ne peut être annoncé sans lien") }
        h.link.connect(to: h.controller)
        h.run(seconds: 10)
        XCTAssertEqual(h.sentCommands.count, countBefore, "aucune commande après reconnexion sans action")
        // Le tapis tourne encore : l'état reflète la télémétrie, pas une commande.
        XCTAssertEqual(h.controller.state, .running)
        XCTAssertTrue(h.events.contains(.externalMovement))
    }

    func testCommandsDuringSequenceAreDeferred() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        _ = h.controller.start(targetSpeed: 5, targetIncline: nil)
        h.controller.setTargetSpeed(6, origin: .user)
        h.run(seconds: 30)
        XCTAssertFalse(h.sentCommands.contains(.setTargetSpeed(kmh: 5)))
        XCTAssertTrue(h.sentCommands.contains(.setTargetSpeed(kmh: 6)))
        XCTAssertEqual(h.controller.telemetry.speedKmh ?? 0, 6, accuracy: 0.01)
    }

    func testNoResponseTimesOutAndAbortsStart() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.dropsResponses = true
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        _ = h.controller.start(targetSpeed: 5, targetIncline: nil)
        h.run(seconds: 10)
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.sentCommands, [.requestControl])
        XCTAssertNotNil(h.controller.lastMessage)
    }
}

final class StartSequenceDiagnosticTests: XCTestCase {
    func run(_ h: ControllerHarness, _ d: StartSequenceDiagnostic, seconds: TimeInterval) {
        let end = h.now + seconds
        while h.now < end {
            h.now += 0.1
            h.link.advance()
            h.controller.tick()
            d.tick()
        }
    }

    func testDiagnosticSucceedsWithURTM047Profile() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        let d = StartSequenceDiagnostic(controller: h.controller)
        XCTAssertNoThrow(try d.begin().get())
        run(h, d, seconds: 90)
        XCTAssertEqual(d.state, .finished(success: true), d.steps.map(\.detail).joined(separator: " | "))
        XCTAssertEqual(d.testSpeed, 2.5)
        XCTAssertEqual(h.controller.state, .stopped)
        XCTAssertEqual(Array(h.sentCommands.prefix(3)), [.requestControl, .setTargetSpeed(kmh: 1.5), .startOrResume])
    }

    func testDiagnosticReportsGenericSequenceFailure() {
        let h = ControllerHarness(profile: .genericFTMS, quirks: .urtm047Like)
        let d = StartSequenceDiagnostic(controller: h.controller)
        _ = d.begin()
        run(h, d, seconds: 90)
        XCTAssertEqual(d.state, .finished(success: false))
        XCTAssertTrue(d.steps.contains { $0.title == "Mouvement" && !$0.ok })
    }
}

final class SpeedHypothesisTests: XCTestCase {
    func runDiag(_ h: ControllerHarness, _ d: ActiveDiagnostic, seconds: TimeInterval) {
        let end = h.now + seconds
        while h.now < end {
            h.now += 0.1
            h.link.advance()
            h.controller.tick()
            d.tick()
        }
    }

    /// Hypothèse : le tapis ignore une consigne reçue pendant qu'il accélère.
    /// Le profil URTM047 attend la vitesse initiale avant la consigne : pas de renvoi nécessaire.
    func testSettleBeforeTargetAvoidsIgnoredCommandWhileRamping() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.ignoresSpeedWhileRamping = true
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        XCTAssertNoThrow(try h.controller.start(targetSpeed: 6, targetIncline: nil).get())
        h.run(seconds: 40)
        XCTAssertEqual(h.controller.speed.status, .reached)
        XCTAssertEqual(h.controller.speed.resendsUsed, 0)
        XCTAssertEqual(h.sentCommands.filter { $0 == .setTargetSpeed(kmh: 6) }.count, 1)
        XCTAssertEqual(h.sentCommands.filter { $0 == .startOrResume }.count, 1)
    }

    /// Sans l'attente (consigne envoyée dès le premier mouvement), la consigne est ignorée
    /// par ce tapis simulé et seul le renvoi unique la rattrape.
    func testWithoutSettleTheRampingTreadmillNeedsResend() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.ignoresSpeedWhileRamping = true
        var p = TreadmillProfile.urtm047
        p.waitForInitialSpeedBeforeTarget = false
        let h = ControllerHarness(profile: p, quirks: q)
        _ = h.controller.start(targetSpeed: 6, targetIncline: nil)
        h.run(seconds: 90)
        XCTAssertEqual(h.controller.speed.status, .reached)
        XCTAssertEqual(h.controller.speed.resendsUsed, 1)
        XCTAssertEqual(h.sentCommands.filter { $0 == .setTargetSpeed(kmh: 6) }.count, 2)
    }

    func testManualTargetDuringSettleIsDeferredNotLost() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        _ = h.controller.start(targetSpeed: 5, targetIncline: 2)
        // Jusqu'au premier mouvement (compte à rebours 3 s + accélération).
        while !h.controller.isSettlingInitialSpeed && h.now < 20 { h.run(seconds: 0.1) }
        XCTAssertTrue(h.controller.isSettlingInitialSpeed)
        h.controller.setTargetSpeed(4, origin: .user)
        h.run(seconds: 40)
        XCTAssertFalse(h.sentCommands.contains(.setTargetSpeed(kmh: 5)))
        XCTAssertEqual(h.controller.telemetry.speedKmh ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(h.controller.telemetry.inclinePercent ?? 0, 2, accuracy: 0.01)
    }

    func testSpeedResponseDiagnosticOnHealthyTreadmill() {
        let h = ControllerHarness(profile: .urtm047, quirks: .urtm047Like)
        let d = SpeedResponseDiagnostic(controller: h.controller)
        XCTAssertNoThrow(try d.begin().get())
        runDiag(h, d, seconds: 200)
        XCTAssertEqual(d.state, .finished(success: true), d.steps.map(\.detail).joined(separator: " | "))
        XCTAssertEqual(d.measurements.map(\.target), [2.5, 3.5, 2.0])
        XCTAssertTrue(d.measurements.allSatisfy { $0.reached && !$0.resendNeeded })
        XCTAssertEqual(d.measurements.first?.reportedByTreadmill, 2.5)
        XCTAssertEqual(h.controller.state, .stopped)
        XCTAssertTrue(d.steps.last?.detail.contains("du premier coup") ?? false)
        XCTAssertEqual(h.sentCommands.filter { $0 == .startOrResume }.count, 1)
    }

    func testSpeedResponseDiagnosticDetectsIgnoredCommands() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.ignoresAllSpeedCommands = true
        q.requiresSpeedBeforeStart = false
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        var o = SpeedResponseDiagnostic.Options()
        o.targets = [3.0]
        o.requestControlBeforeEachStep = true
        let d = SpeedResponseDiagnostic(controller: h.controller, options: o)
        _ = d.begin()
        runDiag(h, d, seconds: 200)
        XCTAssertEqual(d.state, .finished(success: false))
        // La vitesse initiale elle-même n'est pas appliquée (tapis à 1,0) : le test s'arrête proprement.
        XCTAssertEqual(h.controller.state, .stopped)
        XCTAssertTrue(d.steps.contains { $0.title == "Démarrage" && !$0.ok })
    }
}

/// Cas observé sur l'URTM047 (essai du 23/10) : Set Target Speed tapis arrêté sans réponse.
final class UnansweredSetpointTests: XCTestCase {
    func testURTM047StartsWhenInitialSpeedGetsNoResponse() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.speedResponse = .silentWhenStopped
        q.reportsSpeedStatus = false
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        XCTAssertNoThrow(try h.controller.start(targetSpeed: 3, targetIncline: nil).get())
        h.run(seconds: 45)
        XCTAssertEqual(Array(h.sentCommands.prefix(3)), [.requestControl, .setTargetSpeed(kmh: 1.5), .startOrResume])
        XCTAssertEqual(h.controller.state, .running)
        XCTAssertEqual(h.controller.speed.status, .reached)
        XCTAssertEqual(h.controller.telemetry.speedKmh ?? 0, 3, accuracy: 0.01)
        XCTAssertTrue(h.log.entries.contains { $0.message.contains("sans réponse : profil tolérant") })
    }

    func testGenericProfileStaysStrictOnMissingResponse() {
        var q = SimulatedTreadmill.Quirks()
        q.speedResponse = .silent
        q.reportsSpeedStatus = false
        let h = ControllerHarness(profile: .genericFTMS, quirks: q)
        _ = h.controller.start(targetSpeed: 3, targetIncline: nil)
        h.run(seconds: 40)
        // Start acquitté (générique), mais la consigne sans réponse est un échec affiché.
        guard case .failed = h.controller.speed.status else {
            return XCTFail("statut attendu : échec, obtenu \(h.controller.speed.status)")
        }
    }

    func testSilentSpeedCommandVerifiedByTelemetryWhileRunning() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.speedResponse = .silent
        q.reportsSpeedStatus = false
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        _ = h.controller.start(targetSpeed: 4, targetIncline: nil)
        h.run(seconds: 50)
        XCTAssertEqual(h.controller.speed.status, .reached)
        XCTAssertNil(h.controller.speed.acknowledged, "jamais présentée comme acquittée")
        XCTAssertEqual(h.controller.speed.unanswered, 4)
    }

    func testSilentAndIgnoredSpeedIsReportedAsMismatch() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.speedResponse = .silent
        q.reportsSpeedStatus = false
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        _ = h.controller.start(targetSpeed: 1.5, targetIncline: nil)
        h.run(seconds: 30)
        XCTAssertEqual(h.controller.speed.status, .reached)
        h.link.treadmill.quirks.ignoresAllSpeedCommands = true
        h.controller.setTargetSpeed(4, origin: .user)
        h.run(seconds: 120)
        XCTAssertEqual(h.controller.speed.status, .mismatch)
        XCTAssertEqual(h.controller.telemetry.speedKmh ?? 0, 1.5, accuracy: 0.01)
        XCTAssertTrue(h.controller.lastMessage?.contains("sans réponse") ?? false)
    }

    func testStatusEchoActsAsImplicitAcknowledgement() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.speedResponse = .silent
        q.reportsSpeedStatus = true
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        _ = h.controller.start(targetSpeed: 3, targetIncline: nil)
        h.run(seconds: 45)
        XCTAssertEqual(h.controller.speed.acknowledged, 3)
        XCTAssertEqual(h.controller.speed.status, .reached)
        XCTAssertTrue(h.log.entries.contains { $0.message.contains("acquittement implicite") })
    }

    func testLateResponseUpgradesUnansweredToAcknowledged() {
        var q = SimulatedTreadmill.Quirks.urtm047Like
        q.speedResponse = .late(seconds: 6)
        q.reportsSpeedStatus = false
        let h = ControllerHarness(profile: .urtm047, quirks: q)
        _ = h.controller.start(targetSpeed: 3, targetIncline: nil)
        h.run(seconds: 60)
        XCTAssertEqual(h.controller.speed.status, .reached)
        XCTAssertEqual(h.controller.speed.acknowledged, 3)
        XCTAssertTrue(h.log.entries.contains { $0.message.contains("acquittement tardif") })
    }
}
