import Foundation

/// Diagnostic actif, lancé explicitement et hors du tapis : exécute la séquence de démarrage
/// du profil à basse vitesse, demande +1 km/h, observe la télémétrie puis arrête le tapis.
/// Utilise exactement le même code que les séances (pas de séquence expérimentale parallèle).
public final class StartSequenceDiagnostic {
    public struct Step: Identifiable, Equatable, Sendable {
        public let id: Int
        public let title: String
        public let ok: Bool
        public let detail: String
    }

    public enum State: Equatable, Sendable {
        case idle
        case running(String)
        case finished(success: Bool)
    }

    private enum Phase {
        case starting(deadline: TimeInterval)
        case observing(until: TimeInterval)
        case stopping(deadline: TimeInterval)
        case done
    }

    public private(set) var steps: [Step] = []
    public private(set) var state: State = .idle
    public private(set) var testSpeed: Double = 0

    private let controller: TreadmillController
    private var phase: Phase = .done
    private var observedMin = Double.infinity
    private var observedMax = 0.0
    private var success = true

    public init(controller: TreadmillController) {
        self.controller = controller
    }

    public func begin() -> Result<Void, ControllerError> {
        let p = controller.profile
        let caps = controller.capabilities
        testSpeed = caps.snapSpeed(p.initialSpeed(target: p.initialSpeedKmh, capabilities: caps) + 1.0)
        steps = []
        success = true
        controller.log.log(.info, "=== Diagnostic actif : séquence de démarrage du profil \(p.name), cible \(testSpeed) km/h ===")
        switch controller.start(targetSpeed: testSpeed, targetIncline: nil) {
        case .success:
            phase = .starting(deadline: controller.clock() + p.beltStartTimeout + p.speedSettleTime(from: 0, to: testSpeed) * 2 + 10)
            state = .running("Séquence " + p.startSteps.map(\.description).joined(separator: " → "))
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
        if let v = controller.telemetry.speedKmh, controller.isMoving {
            observedMin = min(observedMin, v)
            observedMax = max(observedMax, v)
        }
        switch phase {
        case let .starting(deadline):
            if controller.state == .startUnconfirmed {
                add("Mouvement", false, "Start acquitté mais aucune vitesse observée")
                requestStop()
            } else if controller.state == .running && controller.speed.status == .reached {
                add("Mouvement", true, "Tapis en mouvement")
                add("Consigne", true, String(format: "%.1f km/h observée", testSpeed))
                phase = .observing(until: now + 8)
                state = .running("Observation de la vitesse…")
            } else if controller.speed.status == .mismatch {
                add("Mouvement", controller.isMoving, controller.isMoving ? "Tapis en mouvement" : "Pas de mouvement")
                add("Consigne", false, String(format: "%.1f km/h acquittée mais mesure %@", testSpeed,
                                              controller.telemetry.speedKmh.map { String(format: "%.1f", $0) } ?? "—"))
                phase = .observing(until: now + 5)
            } else if now > deadline {
                add("Délai", false, "Pas de résultat dans le délai prévu (état : \(controller.state.label))")
                requestStop()
            } else if case .idle = controller.state, controller.lastMessage != nil {
                add("Séquence", false, controller.lastMessage ?? "échec")
                state = .finished(success: false)
                phase = .done
            }
        case let .observing(until):
            if now > until {
                if observedMax > 0 {
                    add("Stabilité", true, String(format: "mesures entre %.2f et %.2f km/h", observedMin, observedMax))
                }
                requestStop()
            }
        case let .stopping(deadline):
            if controller.state == .stopped || (controller.state == .idle && !controller.isMoving) {
                add("Arrêt", true, "Vitesse nulle observée")
                finish()
            } else if now > deadline {
                add("Arrêt", false, "Arrêt NON confirmé : utilisez le bouton ou la clé de sécurité")
                finish()
            }
        case .done:
            break
        }
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

    private func finish() {
        phase = .done
        state = .finished(success: success)
        controller.log.log(.info, "=== Diagnostic terminé : \(success ? "réussi" : "échec") — "
                           + steps.map { "\($0.title): \($0.ok ? "OK" : "KO") (\($0.detail))" }.joined(separator: " ; ") + " ===")
    }

    private func add(_ title: String, _ ok: Bool, _ detail: String) {
        if !ok { success = false }
        steps.append(Step(id: steps.count, title: title, ok: ok, detail: detail))
    }
}
