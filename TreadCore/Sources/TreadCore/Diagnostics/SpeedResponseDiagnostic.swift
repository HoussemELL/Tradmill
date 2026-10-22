import Foundation

/// Diagnostic actif « réponse en vitesse », lancé explicitement et hors du tapis.
///
/// But : départager les hypothèses sur le symptôme « consigne de vitesse acquittée sans
/// effet », sans supposer que la séquence de démarrage en est la cause. Le tapis est démarré
/// à sa vitesse initiale avec la séquence du profil, puis plusieurs consignes sont envoyées
/// **pendant la marche**, une à la fois. Pour chacune on relève : résultat de la commande,
/// consigne annoncée par le tapis (statut 0x05), vitesse mesurée, délai d'atteinte, et si
/// le renvoi unique du profil a été nécessaire. Option : Request Control avant chaque consigne.
public final class SpeedResponseDiagnostic: ActiveDiagnostic {
    public struct Options: Equatable, Sendable {
        public var requestControlBeforeEachStep = false
        /// Consignes à tester ; nil = vitesse initiale +1, +2, +0,5 km/h.
        public var targets: [Double]?
        /// Observation supplémentaire après le délai d'atteinte attendu.
        public var extraObservation: TimeInterval = 4
        public init() {}
    }

    public struct Measurement: Identifiable, Equatable, Sendable {
        public let id: Int
        public let target: Double
        public let commandResult: String
        public let reportedByTreadmill: Double?
        public let finalObserved: Double?
        public let reachedAfter: TimeInterval?
        public let resendNeeded: Bool
        public let reached: Bool

        public var summary: String {
            var s = String(format: "%.1f km/h : ", target)
            if reached {
                s += String(format: "atteinte en %.0f s", reachedAfter ?? 0) + (resendNeeded ? " après renvoi" : "")
            } else {
                s += commandResult + " · mesure " + (finalObserved.map { String(format: "%.1f", $0) } ?? "—")
            }
            if let r = reportedByTreadmill { s += String(format: " · tapis annonce %.1f", r) }
            return s
        }
    }

    private enum Phase {
        case starting(deadline: TimeInterval)
        case requestingControl(index: Int)
        case measuring(index: Int, sentAt: TimeInterval, deadline: TimeInterval, reportedBefore: Double?)
        case stopping(deadline: TimeInterval)
        case done
    }

    public let title = "Test de réponse en vitesse"
    public private(set) var state: DiagnosticRunState = .idle
    public private(set) var steps: [DiagnosticStep] = []
    public private(set) var measurements: [Measurement] = []
    public let options: Options

    private let controller: TreadmillController
    private var phase: Phase = .done
    private var targets: [Double] = []
    private var initialSpeed = 0.0
    private var reachedAt: TimeInterval?
    private var controlOutcome: CommandOutcome?
    private var success = true

    public init(controller: TreadmillController, options: Options = Options()) {
        self.controller = controller
        self.options = options
    }

    public func begin() -> Result<Void, ControllerError> {
        let p = controller.profile
        let caps = controller.capabilities
        initialSpeed = p.initialSpeed(target: p.initialSpeedKmh, capabilities: caps)
        targets = (options.targets ?? [initialSpeed + 1.0, initialSpeed + 2.0, initialSpeed + 0.5])
            .map { caps.snapSpeed($0) }
        steps = []
        measurements = []
        success = true
        controller.log.log(.info, "=== Diagnostic actif : réponse en vitesse (profil \(p.name)), départ \(initialSpeed) km/h, consignes "
                           + targets.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                           + (options.requestControlBeforeEachStep ? ", Request Control avant chaque consigne" : "") + " ===")
        switch controller.start(targetSpeed: initialSpeed, targetIncline: nil) {
        case .success:
            phase = .starting(deadline: controller.clock() + p.beltStartTimeout + p.initialSpeedSettleTimeout
                              + p.speedSettleTime(from: 0, to: initialSpeed) * 2 + 10)
            state = .running("Démarrage à \(initialSpeed) km/h")
            return .success(())
        case let .failure(e):
            add("Démarrage", false, e.description)
            state = .finished(success: false)
            return .failure(e)
        }
    }

    public func abort() {
        guard case .running = state else { return }
        add("Interruption", false, "Test interrompu par l'utilisateur")
        requestStop()
    }

    public func tick() {
        let now = controller.clock()
        switch phase {
        case let .starting(deadline):
            if controller.state == .startUnconfirmed {
                add("Démarrage", false, "Start acquitté mais aucune vitesse observée")
                requestStop()
            } else if controller.state == .running, !controller.isSettlingInitialSpeed, controller.speed.status == .reached {
                add("Démarrage", true, String(format: "Tapis stabilisé à %.1f km/h", controller.telemetry.speedKmh ?? 0))
                next(0)
            } else if now > deadline {
                add("Démarrage", false, "Vitesse initiale non stabilisée (état : \(controller.state.label))")
                requestStop()
            } else if case .idle = controller.state, controller.lastMessage != nil {
                add("Démarrage", false, controller.lastMessage ?? "échec")
                finish()
            }
        case let .requestingControl(index):
            if let o = controlOutcome {
                controlOutcome = nil
                if !o.isSuccess { add("Request Control", false, "\(o)") }
                send(index)
            }
        case let .measuring(index, sentAt, deadline, reportedBefore):
            if controller.speed.status == .reached, reachedAt == nil { reachedAt = now }
            if !controller.isMoving {
                add("Mesure", false, "Le tapis s'est arrêté pendant le test")
                finish()
                return
            }
            if now > deadline {
                let t = targets[index]
                let reported = controller.speed.machineReported
                let status = controller.speed.status
                let m = Measurement(
                    id: index, target: t,
                    commandResult: commandLabel(status),
                    reportedByTreadmill: reported != reportedBefore || reported == t ? reported : nil,
                    finalObserved: controller.telemetry.speedKmh,
                    reachedAfter: reachedAt.map { $0 - sentAt },
                    resendNeeded: controller.speed.resendsUsed > 0,
                    reached: status == .reached)
                measurements.append(m)
                add("Consigne \(index + 1)", m.reached && !m.resendNeeded, m.summary)
                next(index + 1)
            }
        case let .stopping(deadline):
            if controller.state == .stopped || (controller.state == .idle && !controller.isMoving) {
                add("Arrêt", true, "Vitesse nulle observée")
                conclude()
                finish()
            } else if now > deadline {
                add("Arrêt", false, "Arrêt NON confirmé : utilisez le bouton ou la clé de sécurité")
                conclude()
                finish()
            }
        case .done:
            break
        }
    }

    // MARK: - Interne

    private func next(_ index: Int) {
        guard index < targets.count else { requestStop(); return }
        if options.requestControlBeforeEachStep {
            controlOutcome = nil
            phase = .requestingControl(index: index)
            state = .running("Request Control avant la consigne \(index + 1)")
            controller.sendDiagnosticCommand(.requestControl) { [weak self] o in self?.controlOutcome = o }
        } else {
            send(index)
        }
    }

    private func send(_ index: Int) {
        let t = targets[index]
        let now = controller.clock()
        let p = controller.profile
        let before = controller.speed.machineReported
        reachedAt = nil
        if case let .failure(e) = controller.setTargetSpeed(t, origin: .diagnostic) {
            add("Consigne \(index + 1)", false, e.description)
            next(index + 1)
            return
        }
        let window = p.speedSettleTime(from: controller.telemetry.speedKmh, to: t) * Double(p.maxTargetResends + 1)
            + options.extraObservation + p.responseTimeout
        phase = .measuring(index: index, sentAt: now, deadline: now + window, reportedBefore: before)
        state = .running(String(format: "Consigne %d/%d : %.1f km/h", index + 1, targets.count, t))
    }

    private func requestStop() {
        if case .failure(let e) = controller.stop() {
            add("Arrêt", false, "Commande Stop impossible : \(e)")
            finish()
            return
        }
        phase = .stopping(deadline: controller.clock() + 20)
        state = .running("Arrêt du tapis…")
    }

    private func commandLabel(_ s: TargetTracking.Status) -> String {
        switch s {
        case .reached: return "atteinte"
        case .mismatch: return "acquittée sans effet observé"
        case .acknowledged: return "acquittée, pas encore atteinte"
        case .pending: return "sans réponse"
        case let .failed(m): return "échec (\(m))"
        case .deferred, .none: return "non envoyée"
        }
    }

    /// Lecture des mesures pour orienter le diagnostic (ce ne sont que des indices).
    private func conclude() {
        guard !measurements.isEmpty else { return }
        let reachedDirect = measurements.filter { $0.reached && !$0.resendNeeded }.count
        let reachedAfterResend = measurements.filter { $0.reached && $0.resendNeeded }.count
        let notApplied = measurements.filter { !$0.reached }
        let text: String
        if reachedDirect == measurements.count {
            text = "Toutes les consignes envoyées en marche ont été appliquées du premier coup. Le symptôme observé ailleurs tient probablement au moment ou à la forme des commandes (démarrage, consigne pendant l'accélération, encodage) plutôt qu'au tapis."
        } else if notApplied.isEmpty {
            text = "\(reachedAfterResend) consigne(s) n'ont été appliquées qu'au renvoi : le tapis ignore parfois une consigne (par ex. reçue pendant une accélération). Le renvoi unique du profil est utile."
        } else if notApplied.contains(where: { $0.reportedByTreadmill != nil && abs(($0.reportedByTreadmill ?? 0) - $0.target) < 0.05 }) {
            text = "Le tapis annonce la consigne reçue mais ne l'applique pas : piste firmware/état interne. Comparer avec la trace de Treadmill Assistant si possible."
        } else if notApplied.contains(where: { ($0.reportedByTreadmill ?? -1) <= controller.capabilities.speed.minKmh + 0.05 && $0.reportedByTreadmill != nil }) {
            text = "Le tapis ramène la consigne au minimum : vérifier dans le journal les octets [TX] Set Target Speed (résolution 0,01 km/h attendue)."
        } else {
            text = "\(notApplied.count) consigne(s) acquittée(s) sans effet. Joindre le journal exporté pour analyse."
        }
        controller.log.log(.info, "Conclusion du test de réponse en vitesse : \(text)")
        steps.append(DiagnosticStep(id: steps.count, title: "Lecture", ok: notApplied.isEmpty, detail: text))
    }

    private func finish() {
        phase = .done
        state = .finished(success: success)
        controller.log.log(.info, "=== Diagnostic terminé : \(success ? "réussi" : "échec") — "
                           + steps.map { "\($0.title): \($0.ok ? "OK" : "KO") (\($0.detail))" }.joined(separator: " ; ") + " ===")
    }

    private func add(_ title: String, _ ok: Bool, _ detail: String) {
        if !ok { success = false }
        steps.append(DiagnosticStep(id: steps.count, title: title, ok: ok, detail: detail))
    }
}
