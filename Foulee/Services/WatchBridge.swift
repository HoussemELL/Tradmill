import Foundation
import HealthKit
import WatchConnectivity
import Observation
import TreadCore

/// Côté iPhone : reçoit la session d'exercice Apple Watch en miroir (HealthKit, iOS 17+)
/// et, à défaut, les messages WatchConnectivity. Ne lit jamais d'anciens échantillons
/// HealthKit : seules les mesures envoyées en direct par la Watch sont utilisées.
@Observable
final class WatchBridge {
    enum LinkState: Equatable {
        case idle
        case launching
        case mirrored
        case connectivity
        case ended
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Apple Watch inactive"
            case .launching: return "Lancement de l'exercice sur la Watch…"
            case .mirrored: return "Watch connectée (miroir HealthKit)"
            case .connectivity: return "Watch connectée (WatchConnectivity)"
            case .ended: return "Exercice Watch terminé"
            case let .failed(m): return "Watch : \(m)"
            }
        }
    }

    private(set) var linkState: LinkState = .idle
    private(set) var watchState: WatchWorkoutState = .notStarted
    private(set) var lastMessageAt: Date?
    /// Vrai si un exercice Watch a fourni des données pendant la séance en cours.
    private(set) var usedDuringSession = false
    /// Incrémenté quand WatchConnectivity signale un changement (jumelage, installation).
    private(set) var connectivityRevision = 0

    @ObservationIgnored private let healthStore: HKHealthStore
    @ObservationIgnored private let log: DiagnosticLog
    @ObservationIgnored private var mirrored: HKWorkoutSession?
    @ObservationIgnored private let sessionProxy = MirrorProxy()
    @ObservationIgnored private let wcProxy = ConnectivityProxy()
    @ObservationIgnored private var pendingLink: WatchMessage?
    @ObservationIgnored private var pendingMetadata: WatchMessage?

    @ObservationIgnored var onHeartRate: ((Double, TimeInterval) -> Void)?
    @ObservationIgnored var onSteps: ((Double) -> Void)?
    @ObservationIgnored var onActiveEnergy: ((Double) -> Void)?
    /// Commande du tapis demandée depuis la montre.
    @ObservationIgnored var onRemoteCommand: ((WatchRemoteCommand) -> Void)?
    @ObservationIgnored var onControl: ((WatchControl) -> Void)?
    @ObservationIgnored var onStartRequest: ((WatchStartRequest) -> Void)?
    @ObservationIgnored var onContextRequested: (() -> Void)?
    @ObservationIgnored private var lastContext: WatchPhoneContext?
    /// Dernier message reçu de la montre (pour l'affichage « Watch reliée »).
    private(set) var lastWatchMessageAt: Date?

    init(healthStore: HKHealthStore, log: DiagnosticLog) {
        self.healthStore = healthStore
        self.log = log
        sessionProxy.owner = self
        wcProxy.owner = self
        if HKHealthStore.isHealthDataAvailable() {
            // Doit être installé tôt : iOS peut relancer l'app en arrière-plan pour le miroir.
            healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
                DispatchQueue.main.async { self?.attach(session) }
            }
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = wcProxy
            WCSession.default.activate()
        }
    }

    var isWatchPaired: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isPaired
    }

    var isAppInstalled: Bool {
        _ = connectivityRevision
        return WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isWatchAppInstalled
    }

    /// État d'installation lisible, avec la marche à suivre.
    var installationStatus: String {
        _ = connectivityRevision
        guard WCSession.isSupported() else { return "Apple Watch non prise en charge sur cet appareil" }
        guard WCSession.default.activationState == .activated else { return "Vérification en cours…" }
        guard WCSession.default.isPaired else { return "Aucune Apple Watch jumelée" }
        guard WCSession.default.isWatchAppInstalled else { return "App Foulée non installée sur la Watch" }
        return "Installée"
    }

    static let installHelp = "Installez l'app Watch : sur l'iPhone, app Watch › Mes montres › Apps disponibles › Foulée › Installer. Ou depuis Xcode : scheme FouleeWatch, destination votre Apple Watch (Mode développeur activé sur la montre)."


    /// Début de séance : identifiant et métadonnées initiales pour la séance Watch
    /// (renvoyés dès que le miroir s'établit si la Watch n'est pas encore reliée).
    func beginSession(id: UUID, title: String, metadata: WatchMessage) {
        usedDuringSession = false
        pendingLink = .linkSession(id: id, title: title)
        pendingMetadata = metadata
        if mirrored != nil {
            send(.linkSession(id: id, title: title))
            send(metadata)
        }
    }

    func endSessionTracking() {
        pendingLink = nil
        pendingMetadata = nil
    }

    /// Lance l'app Watch et son exercice (cardio en direct). L'utilisateur peut aussi
    /// démarrer l'exercice depuis la Watch.
    func launchWatchWorkout(running: Bool) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        if WCSession.isSupported(), WCSession.default.activationState == .activated, !WCSession.default.isWatchAppInstalled {
            linkState = .failed(WCSession.default.isPaired ? "app non installée sur la montre" : "aucune montre jumelée")
            log.log(.warning, "Lancement Watch impossible : \(installationStatus). \(Self.installHelp)")
            return
        }
        let config = HKWorkoutConfiguration()
        config.activityType = running ? .running : .walking
        config.locationType = .indoor
        linkState = .launching
        healthStore.startWatchApp(with: config) { [weak self] ok, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.log.log(.watch, "Demande de lancement de l'exercice Watch envoyée")
                } else {
                    // iOS renvoie « Unable to launch watch app » si l'app n'est pas installée,
                    // si la montre est verrouillée/hors de portée ou si Santé n'est pas autorisé.
                    self.linkState = .failed("lancement impossible (app installée ? montre déverrouillée et à portée ?)")
                    self.log.log(.warning, "Lancement Watch impossible : \(error?.localizedDescription ?? "?")")
                }
            }
        }
    }

    /// App Watch ouverte et joignable par WatchConnectivity.
    var isReachable: Bool {
        _ = connectivityRevision
        return WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    /// Publie programmes, état du tapis et séance (dernier état gagnant, livré même si la montre
    /// est hors de portée), et l'envoie tout de suite si l'app Watch est ouverte.
    func publish(_ ctx: WatchPhoneContext, force: Bool = false) {
        guard force || !ctx.sameContent(as: lastContext) else { return }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? ctx.encoded() else { return }
        do {
            try WCSession.default.updateApplicationContext([WatchPhoneContext.key: data])
            lastContext = ctx
        } catch {
            log.log(.warning, "Contexte Watch non publié : \(error.localizedDescription)")
        }
        if WCSession.default.isReachable { send(.context(ctx), quiet: true) }
    }

    /// Message important (résultat de démarrage) : direct si possible, sinon file WatchConnectivity.
    func sendReliably(_ message: WatchMessage) {
        guard let data = try? message.encoded(), WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage([WatchMessage.wcKey: data], replyHandler: nil) { _ in
                _ = WCSession.default.transferUserInfo([WatchMessage.wcKey: data])
            }
        } else {
            _ = WCSession.default.transferUserInfo([WatchMessage.wcKey: data])
        }
    }

    /// La montre peut recevoir l'état en direct (miroir établi ou app Watch joignable).
    var canStreamToWatch: Bool {
        mirrored != nil || (WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable)
    }

    /// - Parameter quiet: n'écrit pas les échecs dans le journal (état en direct envoyé chaque seconde).
    func send(_ message: WatchMessage, quiet: Bool = false) {
        guard let data = try? message.encoded() else { return }
        if let s = mirrored {
            s.sendToRemoteWorkoutSession(data: data) { [weak self] ok, error in
                if !ok {
                    DispatchQueue.main.async {
                        if !quiet { self?.log.log(.warning, "Envoi vers la Watch (miroir) échoué : \(error?.localizedDescription ?? "?")") }
                        self?.sendViaConnectivity(data, quiet: quiet)
                    }
                }
            }
        } else {
            sendViaConnectivity(data, quiet: quiet)
        }
    }

    private func sendViaConnectivity(_ data: Data, quiet: Bool = false) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([WatchMessage.wcKey: data], replyHandler: nil) { [weak self] error in
            guard !quiet else { return }
            DispatchQueue.main.async { self?.log.log(.warning, "WatchConnectivity : \(error.localizedDescription)") }
        }
    }

    // MARK: - Réception

    fileprivate func connectivityChanged() {
        connectivityRevision += 1
    }

    fileprivate func attach(_ session: HKWorkoutSession) {
        mirrored = session
        session.delegate = sessionProxy
        linkState = .mirrored
        log.log(.watch, "Session d'exercice Watch reçue en miroir")
        if let m = pendingLink { send(m) }
        if let m = pendingMetadata { send(m) }
    }

    fileprivate func mirroredStateChanged(_ state: HKWorkoutSessionState) {
        switch state {
        case .running: watchState = .running
        case .paused: watchState = .paused
        case .ended, .stopped:
            watchState = .ended
            linkState = .ended
            mirrored = nil
        default: break
        }
    }

    fileprivate func mirroredDisconnected(_ error: Error?) {
        log.log(.warning, "Miroir Watch déconnecté" + (error.map { " : \($0.localizedDescription)" } ?? ""))
        mirrored = nil
        linkState = .failed("miroir interrompu")
    }

    fileprivate func receive(_ data: Data, via mirror: Bool) {
        guard let msg = try? WatchMessage.decode(data) else {
            log.log(.warning, "Message Watch illisible (\(data.count) octets)")
            return
        }
        lastMessageAt = Date()
        lastWatchMessageAt = lastMessageAt
        if !mirror, linkState != .mirrored, case .heartRate = msg { linkState = .connectivity }
        switch msg {
        case let .heartRate(bpm, sampleDate):
            usedDuringSession = pendingLink != nil || usedDuringSession
            onHeartRate?(bpm, Date().timeIntervalSince(sampleDate))
        case let .steps(total, _):
            onSteps?(total)
        case let .activeEnergy(kcal, _):
            onActiveEnergy?(kcal)
        case let .workoutState(state, _):
            watchState = state
            if state == .running, pendingLink != nil { usedDuringSession = true }
            log.log(.watch, "Exercice Watch : \(state.rawValue)")
        case let .remoteCommand(c):
            log.log(.watch, "Commande depuis la Watch : \(c.rawValue)")
            onRemoteCommand?(c)
        case let .control(c):
            log.log(.watch, "Commande depuis la Watch : \(c.command.rawValue)")
            onControl?(c)
        case let .startRequest(r):
            log.log(.watch, "Démarrage demandé depuis la Watch (\(r.programID.map { "programme \($0.uuidString.prefix(8))" } ?? "séance libre"))")
            onStartRequest?(r)
        case .requestContext:
            if let c = lastContext { send(.context(c), quiet: true) }
            onContextRequested?()
        case .linkSession, .command, .workoutMetadata, .liveStatus, .context, .startResult:
            break
        }
    }
}

private final class MirrorProxy: NSObject, HKWorkoutSessionDelegate {
    weak var owner: WatchBridge?

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async { self.owner?.mirroredStateChanged(toState) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.owner?.mirroredDisconnected(error) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        DispatchQueue.main.async { data.forEach { self.owner?.receive($0, via: true) } }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        DispatchQueue.main.async { self.owner?.mirroredDisconnected(error) }
    }
}

private final class ConnectivityProxy: NSObject, WCSessionDelegate {
    weak var owner: WatchBridge?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.owner?.connectivityChanged() }
    }
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.owner?.connectivityChanged() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.owner?.connectivityChanged() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchMessage.wcKey] as? Data else { return }
        DispatchQueue.main.async { self.owner?.receive(data, via: false) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
        guard let data = message[WatchMessage.wcKey] as? Data else { return }
        DispatchQueue.main.async { self.owner?.receive(data, via: false) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchMessage.wcKey] as? Data else { return }
        DispatchQueue.main.async { self.owner?.receive(data, via: false) }
    }
}
