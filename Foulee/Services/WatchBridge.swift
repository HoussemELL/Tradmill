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
    /// Réception du miroir actuel (pour reconnaître un miroir périmé, voir `WatchLinkPolicy`).
    @ObservationIgnored private var mirroredAt: Date?
    /// Première FC de la montre reçue pendant la séance en cours (journalisée une fois, avec le canal).
    @ObservationIgnored private var heartRateLoggedForSession = false
    /// Dernier message d'exercice de la montre (FC, pas, énergie, état), tous canaux confondus.
    @ObservationIgnored private var lastWorkoutMessageAt: Date?
    @ObservationIgnored private let sessionProxy = MirrorProxy()
    @ObservationIgnored private let wcProxy = ConnectivityProxy()
    @ObservationIgnored private var pendingLink: WatchMessage?
    @ObservationIgnored private var pendingMetadata: WatchMessage?

    @ObservationIgnored var onHeartRate: ((Double, TimeInterval) -> Void)?
    /// Total de pas de l'exercice Watch et ancienneté de la mesure (s).
    @ObservationIgnored var onSteps: ((Double, TimeInterval) -> Void)?
    @ObservationIgnored var onActiveEnergy: ((Double) -> Void)?
    /// Commande du tapis demandée depuis la montre.
    @ObservationIgnored var onRemoteCommand: ((WatchRemoteCommand) -> Void)?
    @ObservationIgnored var onControl: ((WatchControl) -> Void)?
    @ObservationIgnored var onStartRequest: ((WatchStartRequest) -> Void)?
    @ObservationIgnored var onContextRequested: (() -> Void)?
    @ObservationIgnored private var lastContext: WatchPhoneContext?
    @ObservationIgnored private var lastPublishError: String?
    /// Contexte et état de séance actuels, renvoyés dans la réponse à une demande de la montre
    /// (fonctionne même quand l'iPhone ne peut pas envoyer de lui-même).
    @ObservationIgnored var contextProvider: (() -> WatchPhoneContext)?
    @ObservationIgnored var liveProvider: (() -> WatchLiveStatus?)?
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
        heartRateLoggedForSession = false
        dropStaleMirror(reason: "début de séance")
        // État d'une séance précédente : ne doit pas faire croire que l'exercice tourne déjà.
        if mirrored == nil { watchState = .notStarted }
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
        if WCSession.isSupported(), WCSession.default.activationState == .activated, !WCSession.default.isPaired {
            linkState = .failed("aucune montre jumelée")
            log.log(.warning, "Lancement Watch impossible : aucune montre jumelée")
            return
        }
        // « App non installée » d'après WatchConnectivity n'est pas fiable (app installée depuis
        // Xcode, état pas encore à jour) : on tente quand même, HealthKit dira si ça échoue.
        if WCSession.isSupported(), WCSession.default.activationState == .activated, !WCSession.default.isWatchAppInstalled {
            log.log(.warning, "WatchConnectivity indique l'app Watch non installée : lancement tenté quand même")
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

    /// L'exercice de la montre tourne (relié en miroir vivant ou état reçu).
    var watchWorkoutActive: Bool {
        dropStaleMirror(reason: "vérification avant lancement")
        return mirrored != nil || watchState == .running || watchState == .paused
    }

    /// Miroir sans aucun message de la montre depuis `WatchLinkPolicy.mirrorSilenceLimit` : c'est
    /// un reste (exercice d'une séance précédente, réinstallation). On l'oublie pour que l'exercice
    /// de la montre soit relancé et que son nouveau miroir soit accepté.
    static func label(_ state: HKWorkoutSessionState) -> String {
        switch state {
        case .notStarted: return "non démarré"
        case .prepared: return "préparé"
        case .running: return "en cours"
        case .paused: return "en pause"
        case .stopped: return "arrêté"
        case .ended: return "terminé"
        @unknown default: return "état \(state.rawValue)"
        }
    }

    func dropStaleMirror(reason: String) {
        guard mirrored != nil, let at = mirroredAt,
              !WatchLinkPolicy.isMirrorLive(attachedAt: at, lastWorkoutMessageAt: lastWorkoutMessageAt, now: Date()) else { return }
        let since = lastWorkoutMessageAt.map { $0 >= at ? "dernier message d'exercice il y a \(Int(Date().timeIntervalSince($0))) s"
                                                         : "aucun message d'exercice depuis sa réception" }
            ?? "aucun message d'exercice depuis sa réception"
        log.log(.warning, "Miroir Watch périmé (reçu il y a \(Int(Date().timeIntervalSince(at))) s, \(since)) : ignoré (\(reason))")
        mirrored?.delegate = nil
        mirrored = nil
        mirroredAt = nil
        if linkState == .mirrored { linkState = .idle }
        if watchState == .running || watchState == .paused { watchState = .notStarted }
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
        lastContext = ctx
        guard WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        do {
            try WCSession.default.updateApplicationContext([WatchPhoneContext.key: data])
            lastPublishError = nil
        } catch {
            if lastPublishError != error.localizedDescription {
                lastPublishError = error.localizedDescription
                log.log(.warning, "Contexte Watch non publié : \(error.localizedDescription)")
            }
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
        lastContext = nil  // republier (app Watch installée entre-temps, nouvelle montre…)
    }

    fileprivate func attach(_ session: HKWorkoutSession) {
        if mirrored != nil, mirrored !== session { log.log(.watch, "Nouveau miroir Watch : remplace le précédent") }
        mirrored = session
        mirroredAt = Date()
        session.delegate = sessionProxy
        linkState = .mirrored
        // Miroir (r)établi pendant une séance : l'exercice de la montre tourne et la suit.
        if pendingLink != nil { usedDuringSession = true }
        if session.state == .running { watchState = .running } else if session.state == .paused { watchState = .paused }
        let started = session.startDate.map { ", commencé il y a \(Int(Date().timeIntervalSince($0))) s" } ?? ""
        log.log(.watch, "Session d'exercice Watch reçue en miroir (\(Self.label(session.state))\(started))"
                + (pendingLink == nil ? " — aucune séance Foulée en cours" : ""))
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
            mirroredAt = nil
        default: break
        }
    }

    fileprivate func mirroredDisconnected(_ error: Error?) {
        log.log(.warning, "Miroir Watch déconnecté" + (error.map { " : \($0.localizedDescription)" } ?? ""))
        mirrored = nil
        mirroredAt = nil
        linkState = .failed("miroir interrompu")
    }

    /// Message de la montre attendant une réponse : la demande de contexte reçoit programmes,
    /// tapis, dernier résultat de démarrage et état de séance.
    fileprivate func receive(_ data: Data, reply: @escaping ([String: Any]) -> Void) {
        guard let msg = try? WatchMessage.decode(data), case .requestContext = msg else {
            reply([:])
            receive(data, via: false)
            return
        }
        lastWatchMessageAt = Date()
        var answer: [String: Any] = [:]
        if let ctx = contextProvider?(), let d = try? ctx.encoded() { answer[WatchPhoneContext.key] = d }
        if let live = liveProvider?(), let d = try? WatchMessage.liveStatus(live).encoded() { answer[WatchPhoneContext.liveKey] = d }
        reply(answer)
        onContextRequested?()
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
        case .heartRate, .steps, .activeEnergy, .workoutState: lastWorkoutMessageAt = lastMessageAt
        default: break
        }
        switch msg {
        case let .heartRate(bpm, sampleDate):
            usedDuringSession = pendingLink != nil || usedDuringSession
            if pendingLink != nil, !heartRateLoggedForSession {
                heartRateLoggedForSession = true
                log.log(.watch, "Première FC de la montre reçue (\(mirror ? "miroir" : "WatchConnectivity"), mesure d'il y a \(Int(Date().timeIntervalSince(sampleDate))) s)")
            }
            onHeartRate?(bpm, Date().timeIntervalSince(sampleDate))
        case let .steps(total, sampleDate):
            onSteps?(total, Date().timeIntervalSince(sampleDate))
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
            if let c = contextProvider?() ?? lastContext { send(.context(c), quiet: true) }
            onContextRequested?()
        case let .watchLog(text):
            log.log(.watch, "Montre : \(text)")
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
        guard let data = message[WatchMessage.wcKey] as? Data else { replyHandler([:]); return }
        DispatchQueue.main.async {
            guard let owner = self.owner else { replyHandler([:]); return }
            owner.receive(data, reply: replyHandler)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchMessage.wcKey] as? Data else { return }
        DispatchQueue.main.async { self.owner?.receive(data, via: false) }
    }
}
