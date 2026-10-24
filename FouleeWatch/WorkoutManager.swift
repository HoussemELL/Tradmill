import Foundation
import HealthKit
import WatchConnectivity
import Observation
import TreadCore

/// Cœur de l'app Watch :
/// - catalogue des programmes et état du tapis publiés par l'iPhone (WatchConnectivity) ;
/// - lancement d'un programme depuis la montre : l'iPhone démarre le tapis (FTMS), la montre
///   démarre son exercice (HKWorkoutSession + HKLiveWorkoutBuilder) et fournit la FC ;
/// - état de séance en direct reçu de l'iPhone, commandes Pause/Reprise/Arrêt liées à la séance.
///
/// L'iPhone reste la seule autorité sur le tapis : la montre ne fait que demander.
@Observable
final class WorkoutManager {
    static let shared = WorkoutManager()

    enum Phase: Equatable { case idle, starting, running, paused, ending, ended(saved: Bool), failed(String) }

    /// Étape d'un lancement demandé à l'iPhone.
    enum LaunchState: Equatable {
        case none
        case requesting(String)
        case refused(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var launch: LaunchState = .none
    private(set) var heartRate: Double?
    private(set) var heartRateDate: Date?
    private(set) var steps: Double?
    private(set) var activeEnergy: Double?
    private(set) var startDate: Date?
    private(set) var mirroring = false
    private(set) var linkedTitle: String?
    /// Programmes, tapis et séance publiés par l'iPhone (mémorisés pour l'affichage hors connexion).
    private(set) var context: WatchPhoneContext?
    private(set) var phoneReachable = false
    /// Dernier état de séance reçu de l'iPhone.
    private(set) var live: WatchLiveStatus?
    private(set) var liveReceivedAt: Date?
    /// Bornes des zones (reçues de l'iPhone, mémorisées pour une séance sans iPhone).
    private(set) var zoneBounds: [Int]
    /// Temps par zone mesuré par la montre (utilisé quand l'iPhone n'est pas relié).
    private(set) var localZoneSeconds: [Double] = Array(repeating: 0, count: 6)
    /// Arrêt demandé à l'iPhone (le tapis s'arrête, puis l'iPhone termine l'exercice).
    private(set) var stopRequestedAt: Date?
    /// Message important à afficher (iPhone injoignable pendant un arrêt…).
    var warning: String?
    /// Séance de l'iPhone suivie par cet exercice (mémorisée : reprise après fermeture de l'app).
    private(set) var linkedSessionID: UUID? {
        didSet { UserDefaults.standard.set(linkedSessionID?.uuidString, forKey: Self.linkedKey) }
    }
    private static let linkedKey = "foulee.watch.linkedSession"
    /// Exercice simulé (tests dans le simulateur : pas de HealthKit, FC calculée).
    let simulated: Bool

    @ObservationIgnored let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private let proxy = WorkoutProxy()
    @ObservationIgnored private let wcProxy = WatchConnectivityProxy()
    @ObservationIgnored private var discardOnEnd = false
    /// Métadonnées Foulée reçues avant que le builder existe : appliquées au démarrage.
    @ObservationIgnored private var pendingMetadata: [String: Any] = [:]
    @ObservationIgnored private var lastZoneSampleAt: Date?
    @ObservationIgnored private var pendingRequest: (request: WatchStartRequest, summary: WatchProgramSummary?)?
    @ObservationIgnored private var simTimer: Timer?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var lastPollAt = Date.distantPast
    @ObservationIgnored private var simHeart = SimulatedHeartModel(restBPM: 38)
    /// Coupure volontaire de la FC simulée (test de perte de FC), en secondes depuis le départ.
    @ObservationIgnored var simulatedHeartGap: ClosedRange<Double>?
    @ObservationIgnored var onEvent: ((String) -> Void)?
    @ObservationIgnored private static let boundsKey = "foulee.zoneBounds"
    @ObservationIgnored private static let contextKey = "foulee.context"

    private init() {
        simulated = ProcessInfo.processInfo.arguments.contains("-FouleeSimulated")
        zoneBounds = UserDefaults.standard.array(forKey: Self.boundsKey) as? [Int] ?? HeartZoneSettings().bounds
        if let data = UserDefaults.standard.data(forKey: Self.contextKey), let c = try? WatchPhoneContext.decode(data) {
            context = c
        }
        proxy.owner = self
        wcProxy.owner = self
        if WCSession.isSupported() {
            WCSession.default.delegate = wcProxy
            WCSession.default.activate()
        }
        // Filet de sécurité : la montre réclame catalogue, résultat de démarrage et état de
        // séance (souvent pendant un lancement ou si l'état en direct n'arrive plus).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Un contexte de l'iPhone a été reçu depuis le lancement (le contexte mémorisé ou de
    /// démonstration ne compte pas).
    private(set) var hasFreshContext = false

    private func poll() {
        let now = Date()
        var urgent = context == nil || !hasFreshContext
        if case .requesting = launch { urgent = true }
        if isActive, !(liveReceivedAt.map { now.timeIntervalSince($0) < 2.5 } ?? false) { urgent = true }
        let interval: TimeInterval = urgent ? (isActive ? 1 : 2) : 15
        if now.timeIntervalSince(lastPollAt) >= interval { requestContext() }
    }

    var isActive: Bool {
        switch phase {
        case .starting, .running, .paused, .ending: return true
        default: return false
        }
    }

    var programs: [WatchProgramSummary] { context?.programs ?? [] }

    // MARK: - Contexte de l'iPhone

    fileprivate func connectivityActivated() {
        phoneReachable = WCSession.default.isReachable
        if let data = WCSession.default.receivedApplicationContext[WatchPhoneContext.key] as? Data {
            apply(contextData: data)
        }
        requestContext()
    }

    fileprivate func reachabilityChanged() {
        let was = phoneReachable
        phoneReachable = WCSession.default.isReachable
        if phoneReachable && !was { requestContext() }
    }

    /// Demande programmes, tapis, résultat de démarrage et état de séance ; l'iPhone répond
    /// directement (fonctionne même s'il ne peut pas envoyer de lui-même).
    func requestContext() {
        lastPollAt = Date()
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable,
              let data = try? WatchMessage.requestContext.encoded() else { return }
        WCSession.default.sendMessage([WatchMessage.wcKey: data], replyHandler: { [weak self] reply in
            let ctx = reply[WatchPhoneContext.key] as? Data
            let live = reply[WatchPhoneContext.liveKey] as? Data
            DispatchQueue.main.async {
                if let ctx { self?.apply(contextData: ctx) }
                if let live { self?.receive(live) }
            }
        }, errorHandler: nil)
    }

    fileprivate func apply(contextData data: Data) {
        guard let c = try? WatchPhoneContext.decode(data) else { return }
        hasFreshContext = true
        apply(context: c)
    }

    func apply(context c: WatchPhoneContext) {
        if let old = context, old.sentAt > c.sentAt { return }
        context = c
        if c.zoneBounds.count == 6, c.zoneBounds != zoneBounds {
            zoneBounds = c.zoneBounds
            UserDefaults.standard.set(c.zoneBounds, forKey: Self.boundsKey)
        }
        if let data = try? c.encoded() { UserDefaults.standard.set(data, forKey: Self.contextKey) }
        onEvent?("context:\(c.programs.count)")
        if let r = c.lastStartResult { handle(startResult: r) }
    }

    /// L'iPhone a envoyé son état de séance il y a moins de 5 s.
    func isPhoneLinked(now: Date = Date()) -> Bool {
        guard let at = liveReceivedAt, live != nil else { return false }
        return now.timeIntervalSince(at) < 5
    }

    /// Séance en cours sur l'iPhone que la montre ne suit pas encore.
    var phoneSessionToFollow: (id: UUID, name: String)? {
        guard !isActive, let c = context, let id = c.activeSessionID else { return nil }
        return (id, c.activeProgramName ?? "Séance")
    }

    // MARK: - Lancement depuis la montre

    /// Demande à l'iPhone de démarrer le programme (nil = séance libre) sur le tapis. L'exercice
    /// de la montre ne démarre qu'une fois le tapis lancé.
    func startProgram(_ summary: WatchProgramSummary?) {
        guard !isActive else { return }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            launch = .refused("iPhone injoignable. Ouvrez Foulée sur l'iPhone, à proximité.")
            return
        }
        let r = WatchStartRequest(programID: summary?.id, issuedAt: Date())
        pendingRequest = (r, summary)
        launch = .requesting(summary?.name ?? "Séance libre")
        onEvent?("startRequest:\(summary?.name ?? "libre")")
        guard let data = try? WatchMessage.startRequest(r).encoded() else { return }
        WCSession.default.sendMessage([WatchMessage.wcKey: data], replyHandler: { _ in }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pendingRequest?.request.requestID == r.requestID else { return }
                self.pendingRequest = nil
                self.launch = .refused("iPhone injoignable : \(error.localizedDescription)")
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + WatchStartPolicy.watchGiveUpAfter) { [weak self] in
            guard let self, self.pendingRequest?.request.requestID == r.requestID else { return }
            self.pendingRequest = nil
            self.launch = .refused("Pas de réponse de l'iPhone. Rien n'a été démarré.")
        }
    }

    func dismissLaunchMessage() { launch = .none }

    /// Tests (simulateur) : état de séance de démonstration, sans iPhone.
    func injectDemo(live s: WatchLiveStatus) {
        live = s
        liveReceivedAt = Date()
        zoneBounds = s.zoneBounds
    }

    private func handle(startResult res: WatchStartResult) {
        guard let p = pendingRequest, p.request.requestID == res.requestID else { return }
        pendingRequest = nil
        onEvent?("startResult:\(res.accepted)")
        guard res.accepted else {
            launch = .refused(res.message)
            return
        }
        launch = .none
        linkedSessionID = res.sessionID
        linkedTitle = p.summary?.name ?? "Séance libre"
        Task { @MainActor in
            await self.start(activity: (p.summary?.suggestsRunning ?? false) ? .running : .walking)
        }
    }

    /// Suit une séance lancée sur l'iPhone : démarre l'exercice de la montre (FC).
    func followPhoneSession() {
        guard let s = phoneSessionToFollow else { return }
        linkedSessionID = s.id
        linkedTitle = s.name
        Task { @MainActor in await self.start(activity: .walking) }
    }

    // MARK: - Exercice (HealthKit)

    func requestAuthorization() async {
        // Sans ces clés, HealthKit lève une exception Objective-C (plantage).
        for key in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"] {
            guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty else { return }
        }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.stepCount),
                                       HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning),
                                       HKObjectType.workoutType()]
        try? await healthStore.requestAuthorization(toShare: share, read: read)
    }

    /// Démarre l'exercice (après un lancement accepté, depuis l'iPhone, ou exercice libre).
    @MainActor
    func start(activity: HKWorkoutActivityType) async {
        guard !isActive else { return }
        // Un exercice tourne encore (app fermée puis relancée) : on le reprend au lieu d'en
        // démarrer un second, qui couperait la séance en deux dans Santé.
        if !simulated, await recoverActiveWorkout() { return }
        phase = .starting
        heartRate = nil
        steps = nil
        activeEnergy = nil
        localZoneSeconds = Array(repeating: 0, count: 6)
        lastZoneSampleAt = nil
        stopRequestedAt = nil
        warning = nil
        if simulated {
            startSimulatedWorkout()
            return
        }
        await requestAuthorization()
        await refreshLiveBeforeStart()
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        config.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let b = s.associatedWorkoutBuilder()
            let source = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            source.enableCollection(for: HKQuantityType(.stepCount), predicate: nil)
            b.dataSource = source
            s.delegate = proxy
            b.delegate = proxy
            session = s
            builder = b
            discardOnEnd = false
            // Bande déjà en route (montre lancée en retard) : début aligné sur la bande.
            let date = WatchWorkoutAlignment.startDate(now: Date(), live: live)
            if Date().timeIntervalSince(date) > 1 { onEvent?("start-aligned:\(Int(Date().timeIntervalSince(date)))") }
            startDate = date
            s.startActivity(with: date)
            try await b.beginCollection(at: date)
            // Début aligné sur la bande : les pauses déjà faites sont reportées dans l'exercice.
            let past = WatchWorkoutAlignment.pastPauses(start: date, now: Date(), live: live)
            if !past.isEmpty {
                let events = past.flatMap { p in
                    [HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: p.start, duration: 0), metadata: nil),
                     HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: p.end, duration: 0), metadata: nil)]
                }
                try? await b.addWorkoutEvents(events)
                onEvent?("past-pauses:\(past.count)")
            }
            do {
                try await s.startMirroringToCompanionDevice()
                mirroring = true
            } catch {
                // Repli : WatchConnectivity si l'iPhone est joignable.
                mirroring = false
            }
            send(.workoutState(.running, startDate: date))
            if let id = linkedSessionID { addLinkMetadata(id) }
            if !pendingMetadata.isEmpty {
                try? await b.addMetadata(pendingMetadata)
                pendingMetadata = [:]
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Avant de démarrer : état de séance récent de l'iPhone (au plus ~2 s d'attente), pour
    /// savoir si la bande tourne déjà et depuis quand.
    @MainActor
    private func refreshLiveBeforeStart() async {
        if let at = liveReceivedAt, Date().timeIntervalSince(at) < 5 { return }
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        let asked = Date()
        requestContext()
        for _ in 0..<10 {
            if let at = liveReceivedAt, at >= asked { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Reprend l'exercice resté actif après une fermeture de l'app (plantage, mémoire, mise à jour) :
    /// même exercice, même séance Santé. Renvoie vrai si un exercice a été repris.
    @MainActor
    @discardableResult
    func recoverActiveWorkout() async -> Bool {
        guard !isActive, !simulated else { return false }
        let recovered: HKWorkoutSession? = await withCheckedContinuation { cont in
            healthStore.recoverActiveWorkoutSession { s, _ in cont.resume(returning: s) }
        }
        guard let s = recovered else { return false }
        let b = s.associatedWorkoutBuilder()
        b.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: s.workoutConfiguration)
        s.delegate = proxy
        b.delegate = proxy
        session = s
        builder = b
        discardOnEnd = false
        startDate = b.startDate ?? s.startDate ?? Date()
        if linkedSessionID == nil, let id = UserDefaults.standard.string(forKey: Self.linkedKey).flatMap(UUID.init) {
            linkedSessionID = id
        }
        phase = s.state == .paused ? .paused : .running
        do {
            try await s.startMirroringToCompanionDevice()
            mirroring = true
        } catch {
            mirroring = false
        }
        send(.workoutState(phase == .paused ? .paused : .running, startDate: startDate))
        onEvent?("recovered")
        requestContext()
        return true
    }

    func pause() {
        if simulated { if phase == .running { phase = .paused; send(.workoutState(.paused, startDate: startDate)) }; return }
        session?.pause()
    }

    func resume() {
        if simulated { if phase == .paused { phase = .running; send(.workoutState(.running, startDate: startDate)) }; return }
        session?.resume()
    }

    func end(discard: Bool = false) {
        discardOnEnd = discard
        if simulated {
            simTimer?.invalidate()
            simTimer = nil
            phase = .ended(saved: false)
            send(.workoutState(.ended, startDate: startDate))
            onEvent?("ended")
            return
        }
        phase = .ending
        session?.end()
    }

    func reset() {
        phase = .idle
        session = nil
        builder = nil
        startDate = nil
        linkedTitle = nil
        linkedSessionID = nil
        live = nil
        liveReceivedAt = nil
        stopRequestedAt = nil
        warning = nil
    }

    // MARK: - Commandes de séance (le tapis est piloté par l'iPhone)

    private var sessionIDForControl: UUID? { live?.sessionID ?? linkedSessionID ?? context?.activeSessionID }

    private func sendControl(_ c: WatchRemoteCommand) {
        send(.control(WatchControl(command: c, sessionID: sessionIDForControl, issuedAt: Date())))
        onEvent?("control:\(c.rawValue)")
    }

    /// Pause : met en pause le tapis via l'iPhone (qui met ensuite l'exercice en pause),
    /// ou seulement l'exercice si l'iPhone n'est pas relié.
    func requestPause() {
        if isPhoneLinked() { sendControl(.pause) } else { pause() }
    }

    /// Reprise : toujours une action explicite ; jamais rejouée en retard par l'iPhone.
    func requestResume() {
        if isPhoneLinked() { sendControl(.resume) }
        if phase == .paused { resume() }
    }

    /// Arrêt : arrête le tapis via l'iPhone, qui termine ensuite l'exercice avec les métadonnées
    /// Foulée. Sans réponse en 8 s, l'exercice est terminé ici. Sans iPhone : avertissement, car
    /// le tapis ne peut être arrêté que par l'iPhone, son bouton ou la clé de sécurité.
    func requestStop() {
        guard isPhoneLinked() else {
            if live != nil || linkedSessionID != nil {
                warning = "iPhone injoignable : arrêtez le tapis avec son bouton ou la clé de sécurité."
                sendControl(.stop)
            }
            end()
            return
        }
        stopRequestedAt = Date()
        sendControl(.stop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.stopRequestedAt != nil, self.isActive, self.phase != .ending else { return }
            self.end()
        }
    }

    func requestAutopilot() { sendControl(.resumeAutopilot) }

    /// Zone de la FC de la montre, avec les bornes reçues.
    var currentZone: Int? {
        guard let bpm = heartRate else { return nil }
        return WatchLiveStatus.zone(for: Int(bpm.rounded()), bounds: zoneBounds)
    }

    /// Temps par zone : celui de l'iPhone s'il est relié, sinon celui mesuré par la montre.
    var zoneSeconds: [Double] {
        if isPhoneLinked(), let l = live { return l.zoneSeconds }
        return localZoneSeconds
    }

    private func accumulateZone(bpm: Double, at date: Date) {
        defer { lastZoneSampleAt = date }
        guard phase == .running, let last = lastZoneSampleAt else { return }
        let dt = min(max(date.timeIntervalSince(last), 0), 5)
        if let z = WatchLiveStatus.zone(for: Int(bpm.rounded()), bounds: zoneBounds), z < localZoneSeconds.count {
            localZoneSeconds[z] += dt
        }
    }

    // MARK: - Exercice simulé (simulateur)

    /// Sans HealthKit : FC calculée à partir de la vitesse mesurée par l'iPhone, envoyée comme
    /// une vraie mesure de la montre (même chemin WatchConnectivity).
    private func startSimulatedWorkout() {
        let date = Date()
        startDate = date
        phase = .running
        simHeart = SimulatedHeartModel(restBPM: 38)
        send(.workoutState(.running, startDate: date))
        onEvent?("workoutStarted")
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.simulatedTick()
        }
    }

    private func simulatedTick() {
        guard phase == .running || phase == .paused, let start = startDate else { return }
        let now = Date()
        let speed = isPhoneLinked(now: now) ? (live?.speedKmh ?? 0) : 0
        let incline = live?.inclinePercent ?? 0
        let bpm = simHeart.advance(dt: 2, speedKmh: speed, inclinePercent: incline)
        let t = now.timeIntervalSince(start)
        if let gap = simulatedHeartGap, gap.contains(t) {
            heartRate = nil
            return
        }
        heartRate = Double(bpm)
        heartRateDate = now
        accumulateZone(bpm: Double(bpm), at: now)
        send(.heartRate(bpm: Double(bpm), sampleDate: now))
        onEvent?("hr")
    }

    // MARK: - Échanges avec l'iPhone

    func send(_ message: WatchMessage) {
        guard let data = try? message.encoded() else { return }
        if mirroring, let s = session {
            s.sendToRemoteWorkoutSession(data: data) { [weak self] ok, _ in
                if !ok { DispatchQueue.main.async { self?.sendViaConnectivity(data, message: message) } }
            }
        } else {
            sendViaConnectivity(data, message: message)
        }
    }

    private func sendViaConnectivity(_ data: Data, message: WatchMessage) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage([WatchMessage.wcKey: data], replyHandler: nil) { _ in
                // Un arrêt ou une pause non remis est mis en file (l'iPhone vérifie la séance et l'âge).
                if case let .control(c) = message, c.command == .stop || c.command == .pause {
                    _ = WCSession.default.transferUserInfo([WatchMessage.wcKey: data])
                }
            }
        } else if case let .control(c) = message, c.command == .stop || c.command == .pause {
            _ = WCSession.default.transferUserInfo([WatchMessage.wcKey: data])
        }
    }

    fileprivate func receive(_ data: Data) {
        guard let msg = try? WatchMessage.decode(data) else { return }
        switch msg {
        case let .linkSession(id, title):
            linkedSessionID = id
            linkedTitle = title
            addLinkMetadata(id)
        case let .workoutMetadata(standard, foulee):
            var meta: [String: Any] = [
                HKMetadataKeySyncIdentifier: standard.syncIdentifier,
                HKMetadataKeySyncVersion: NSNumber(value: standard.syncVersion),
                HKMetadataKeyExternalUUID: standard.syncIdentifier,
                HKMetadataKeyIndoorWorkout: NSNumber(value: standard.indoor),
            ]
            for (k, v) in foulee {
                switch v {
                case let .string(x): meta[k] = x
                case let .number(x): meta[k] = NSNumber(value: x)
                case let .integer(x): meta[k] = NSNumber(value: x)
                case let .bool(x): meta[k] = NSNumber(value: x)
                }
            }
            if let b = builder, isActive {
                b.addMetadata(meta) { _, _ in }
            } else {
                pendingMetadata.merge(meta) { _, new in new }
            }
        case let .liveStatus(s):
            if let l = live, let at = liveReceivedAt, l.sentAt > s.sentAt, Date().timeIntervalSince(at) < 5 { return }
            live = s
            liveReceivedAt = Date()
            if s.zoneBounds.count == 6, s.zoneBounds != zoneBounds {
                zoneBounds = s.zoneBounds
                UserDefaults.standard.set(s.zoneBounds, forKey: Self.boundsKey)
            }
            onEvent?("live:\(s.state.rawValue):\(s.phaseName ?? "-"):\(s.targetSpeedKmh)")
            followPhoneState(s)
        case let .context(c):
            hasFreshContext = true
            apply(context: c)
        case let .startResult(r):
            handle(startResult: r)
        case let .command(c):
            onEvent?("command:\(c.rawValue)")
            switch c {
            case .pause: pause()
            case .resume: resume()
            case .end: stopRequestedAt = nil; end()
            case .discard: end(discard: true)
            }
        default:
            break
        }
    }

    /// L'exercice de la montre suit l'état de la séance de l'iPhone (pause, reprise, fin), même
    /// si la commande directe de l'iPhone s'est perdue.
    private func followPhoneState(_ s: WatchLiveStatus) {
        guard isActive, phase != .ending, s.sessionID == nil || linkedSessionID == nil || s.sessionID == linkedSessionID else { return }
        switch s.state {
        case .paused where phase == .running: pause()
        case .running where phase == .paused: resume()
        case .finished:
            // L'iPhone envoie normalement « terminer » avec les métadonnées ; sinon on termine ici.
            let id = s.sessionID
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.isActive, self.phase != .ending, self.live?.state == .finished, self.live?.sessionID == id else { return }
                self.onEvent?("ended-after-phone")
                self.end()
            }
        default:
            break
        }
    }

    private func addLinkMetadata(_ id: UUID) {
        // Identifiant de la séance iPhone : même clé que la séance Foulée (anti-doublon).
        builder?.addMetadata([HKMetadataKeyExternalUUID: id.uuidString,
                              HKMetadataKeySyncIdentifier: id.uuidString,
                              HKMetadataKeySyncVersion: NSNumber(value: 1),
                              HKMetadataKeyIndoorWorkout: true]) { _, _ in }
    }

    // MARK: - Délégués

    fileprivate func stateChanged(_ state: HKWorkoutSessionState, date: Date) {
        switch state {
        case .running:
            phase = .running
            send(.workoutState(.running, startDate: startDate))
        case .paused:
            phase = .paused
            send(.workoutState(.paused, startDate: startDate))
        case .ended:
            finish(at: date)
        default:
            break
        }
    }

    private func finish(at date: Date) {
        guard let b = builder else { return }
        let discard = discardOnEnd
        b.endCollection(withEnd: date) { [weak self] _, _ in
            if discard {
                b.discardWorkout()
                DispatchQueue.main.async {
                    self?.phase = .ended(saved: false)
                    self?.send(.workoutState(.ended, startDate: self?.startDate))
                }
            } else {
                b.finishWorkout { workout, _ in
                    DispatchQueue.main.async {
                        self?.phase = .ended(saved: workout != nil)
                        self?.send(.workoutState(.ended, startDate: self?.startDate))
                    }
                }
            }
        }
    }

    fileprivate func failed(_ error: Error) {
        phase = .failed(error.localizedDescription)
        send(.workoutState(.failed, startDate: startDate))
    }

    fileprivate func collected(_ types: Set<HKSampleType>) {
        guard let b = builder else { return }
        for type in types {
            guard let qt = type as? HKQuantityType, let stats = b.statistics(for: qt) else { continue }
            let date = stats.mostRecentQuantityDateInterval()?.end ?? Date()
            switch qt {
            case HKQuantityType(.heartRate):
                if let q = stats.mostRecentQuantity() {
                    let bpm = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    heartRate = bpm
                    heartRateDate = date
                    accumulateZone(bpm: bpm, at: date)
                    send(.heartRate(bpm: bpm, sampleDate: date))
                }
            case HKQuantityType(.stepCount):
                if let q = stats.sumQuantity() {
                    let v = q.doubleValue(for: .count())
                    steps = v
                    send(.steps(total: v, sampleDate: date))
                }
            case HKQuantityType(.activeEnergyBurned):
                if let q = stats.sumQuantity() {
                    let v = q.doubleValue(for: .kilocalorie())
                    activeEnergy = v
                    send(.activeEnergy(kcal: v, sampleDate: date))
                }
            default:
                break
            }
        }
    }
}

private final class WorkoutProxy: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    weak var owner: WorkoutManager?

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async { self.owner?.stateChanged(toState, date: date) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.owner?.failed(error) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        DispatchQueue.main.async { data.forEach { self.owner?.receive($0) } }
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        DispatchQueue.main.async { self.owner?.collected(collectedTypes) }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

private final class WatchConnectivityProxy: NSObject, WCSessionDelegate {
    weak var owner: WorkoutManager?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.owner?.connectivityActivated() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.owner?.reachabilityChanged() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchPhoneContext.key] as? Data else { return }
        DispatchQueue.main.async { self.owner?.apply(contextData: data) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchMessage.wcKey] as? Data else { return }
        DispatchQueue.main.async { self.owner?.receive(data) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
        guard let data = message[WatchMessage.wcKey] as? Data else { return }
        DispatchQueue.main.async { self.owner?.receive(data) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchMessage.wcKey] as? Data else { return }
        DispatchQueue.main.async { self.owner?.receive(data) }
    }
}
