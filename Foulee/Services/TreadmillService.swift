import Foundation
import CoreBluetooth
import Observation
import TreadCore

/// Connexion au tapis (BLE réel ou simulateur clairement identifié) et état observable
/// du contrôleur FTMS pour l'interface.
@Observable
final class TreadmillService {
    enum Connection: Equatable {
        case none
        case connecting(String)
        case discovering(String)
        case ready(String)
        case reconnecting(String)
        case failed(String)

        var label: String {
            switch self {
            case .none: return "Aucun tapis"
            case let .connecting(n): return "Connexion à \(n)…"
            case let .discovering(n): return "\(n) : lecture des capacités…"
            case let .ready(n): return n
            case let .reconnecting(n): return "Reconnexion à \(n)…"
            case let .failed(m): return m
            }
        }

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    // État observable (copies rafraîchies depuis le contrôleur).
    private(set) var connection: Connection = .none
    private(set) var isSimulated = false
    private(set) var deviceName: String?
    private(set) var deviceID: UUID?
    private(set) var deviceInfo: [String: String] = [:]
    private(set) var beltState: BeltState = .disconnected
    private(set) var telemetry = TreadmillTelemetry()
    private(set) var speed = TargetTracking()
    private(set) var incline = TargetTracking()
    private(set) var hasControl = false
    /// Démarrage : attente de la vitesse initiale stable avant la consigne du palier.
    private(set) var settlingInitialSpeed = false
    private(set) var lastMessage: String?
    private(set) var capabilities: TreadmillCapabilities
    private(set) var profile: TreadmillProfile

    @ObservationIgnored let controller: TreadmillController
    @ObservationIgnored private let hub: BluetoothHub
    @ObservationIgnored private let log: DiagnosticLog
    @ObservationIgnored private var link: FTMSLink?
    @ObservationIgnored private var simLink: SimulatedFTMSLink?
    @ObservationIgnored private var wantConnected = false
    @ObservationIgnored var profileOverrideID: String?

    /// Abonnés supplémentaires (séance en cours).
    @ObservationIgnored var eventSink: ((ControllerEvent) -> Void)?
    @ObservationIgnored var telemetrySink: ((TreadmillData, TimeInterval) -> Void)?
    /// Appelé à chaque paquet de télémétrie (fait avancer la séance en arrière-plan).
    @ObservationIgnored var onPacket: (() -> Void)?
    @ObservationIgnored var onDeviceRemembered: ((UUID, String) -> Void)?

    init(hub: BluetoothHub, log: DiagnosticLog) {
        self.hub = hub
        self.log = log
        let p = TreadmillProfile.genericFTMS
        profile = p
        capabilities = p.fallbackCapabilities
        controller = TreadmillController(profile: p, log: log, clock: MonotonicClock.now)
        controller.onEvent = { [weak self] e in
            self?.eventSink?(e)
            self?.refresh()
        }
        controller.onTelemetry = { [weak self] d, t in
            self?.telemetrySink?(d, t)
        }
        hub.onConnect[.treadmill] = { [weak self] p in self?.didConnect(p) }
        hub.onDisconnect[.treadmill] = { [weak self] p, e in self?.didDisconnect(p, error: e) }
        hub.onFailToConnect[.treadmill] = { [weak self] p, e in
            self?.connection = .failed("Échec de connexion : \(e?.localizedDescription ?? "inconnu")")
            self?.wantConnected = false
        }
    }

    // MARK: - Connexion

    func connect(id: UUID, name: String) {
        disconnectSimulator()
        wantConnected = true
        deviceID = id
        deviceName = name
        isSimulated = false
        connection = .connecting(name)
        hub.connect(id: id, role: .treadmill)
    }

    func disconnect() {
        wantConnected = false
        if isSimulated { disconnectSimulator(); return }
        if let id = deviceID { hub.cancelConnection(id: id) }
        link = nil
        controller.linkDidDisconnect()
        connection = .none
        refresh()
    }

    func connectSimulator() {
        if let id = deviceID, !isSimulated { hub.cancelConnection(id: id) }
        link = nil
        let sim = SimulatedFTMSLink(treadmill: SimulatedTreadmill(quirks: .urtm047Like), clock: MonotonicClock.now)
        simLink = sim
        isSimulated = true
        deviceName = "SIMULATEUR"
        deviceID = nil
        applyProfile(for: "URTM047")
        sim.connect(to: controller)
        connection = .ready("SIMULATEUR (aucun tapis réel)")
        refresh()
    }

    private func disconnectSimulator() {
        guard let sim = simLink else { return }
        sim.disconnect()
        simLink = nil
        isSimulated = false
        connection = .none
        refresh()
    }

    private func applyProfile(for name: String?) {
        let p = profileOverrideID.flatMap(TreadmillProfile.profile(id:)) ?? TreadmillProfile.match(deviceName: name)
        controller.setProfile(p)
        profile = p
    }

    private func didConnect(_ p: CBPeripheral) {
        let name = p.name ?? deviceName ?? "Tapis"
        deviceName = name
        applyProfile(for: name)
        controller.linkDidConnect()
        let l = FTMSLink(peripheral: p, controller: controller, profile: profile, log: log)
        l.onReadyChange = { [weak self] ready in
            guard let self, ready else { return }
            self.connection = .ready(name)
            self.onDeviceRemembered?(p.identifier, name)
            self.refresh()
        }
        l.onInfoChange = { [weak self, weak l] in self?.deviceInfo = l?.deviceInfo ?? [:] }
        l.onTelemetryPacket = { [weak self] in
            self?.onPacket?()
        }
        controller.queue.writer = l
        link = l
        connection = .discovering(name)
        l.start()
        refresh()
    }

    private func didDisconnect(_ p: CBPeripheral, error: Error?) {
        link = nil
        controller.linkDidDisconnect()
        refresh()
        let name = deviceName ?? "tapis"
        if wantConnected {
            // Reconnexion du lien uniquement : aucune commande ne sera envoyée sans action.
            connection = .reconnecting(name)
            hub.connect(id: p.identifier, role: .treadmill)
        } else {
            connection = .none
        }
    }

    // MARK: - Boucle

    /// Appelé par la boucle de l'app (≈ 4 Hz) quand aucune séance ne pilote déjà le contrôleur.
    func tick(drivenBySession: Bool) {
        simLink?.advance()
        if !drivenBySession { controller.tick() }
        refresh()
    }

    func refresh() {
        if beltState != controller.state { beltState = controller.state }
        if telemetry != controller.telemetry { telemetry = controller.telemetry }
        if speed != controller.speed { speed = controller.speed }
        if incline != controller.incline { incline = controller.incline }
        if hasControl != controller.hasControl { hasControl = controller.hasControl }
        if settlingInitialSpeed != controller.isSettlingInitialSpeed { settlingInitialSpeed = controller.isSettlingInitialSpeed }
        if lastMessage != controller.lastMessage { lastMessage = controller.lastMessage }
        if capabilities != controller.capabilities { capabilities = controller.capabilities }
    }

    // MARK: - Diagnostic

    func exploreGATT(listenToUnknown: Bool) {
        link?.exploreAll(listenToUnknown: listenToUnknown)
    }

    var canExploreGATT: Bool { link != nil }
}
