import Foundation
import CoreBluetooth
import Observation
import TreadCore

/// Gestionnaire central CoreBluetooth unique (tapis + capteur cardio).
/// Les callbacks arrivent sur la file principale (queue nil).
@Observable
final class BluetoothHub {
    enum Role: String { case treadmill, heartRate }

    struct Discovered: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var role: Role
        var lastSeen: Date
    }

    private(set) var state: CBManagerState = .unknown
    private(set) var discovered: [Discovered] = []
    private(set) var scanningRole: Role?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private let proxy = CentralProxy()
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var pendingAfterPowerOn: [() -> Void] = []
    @ObservationIgnored let log: DiagnosticLog

    /// Rappels vers les services propriétaires (tapis ou cardio) selon l'identifiant.
    @ObservationIgnored var onConnect: [Role: (CBPeripheral) -> Void] = [:]
    @ObservationIgnored var onDisconnect: [Role: (CBPeripheral, Error?) -> Void] = [:]
    @ObservationIgnored var onFailToConnect: [Role: (CBPeripheral, Error?) -> Void] = [:]
    @ObservationIgnored private var roles: [UUID: Role] = [:]

    init(log: DiagnosticLog) {
        self.log = log
        proxy.owner = self
    }

    var isPoweredOn: Bool { state == .poweredOn }

    var stateLabel: String {
        switch state {
        case .poweredOn: return "Bluetooth actif"
        case .poweredOff: return "Bluetooth désactivé"
        case .unauthorized: return "Accès Bluetooth refusé (Réglages > Foulée)"
        case .unsupported: return "Bluetooth LE non disponible"
        case .resetting: return "Bluetooth en réinitialisation"
        default: return "Bluetooth en attente"
        }
    }

    /// Crée le gestionnaire au premier besoin (déclenche la demande d'autorisation).
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: proxy, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    private func whenPoweredOn(_ work: @escaping () -> Void) {
        activate()
        if state == .poweredOn { work() } else { pendingAfterPowerOn.append(work) }
    }

    func startScan(for role: Role) {
        whenPoweredOn { [weak self] in
            guard let self, let central = self.central else { return }
            self.discovered.removeAll { $0.role == role }
            self.scanningRole = role
            let service = CBUUID(string: role == .treadmill ? GATTID.fitnessMachineService : GATTID.heartRateService)
            central.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            self.log.log(.ble, "Recherche \(role == .treadmill ? "tapis FTMS (0x1826)" : "capteurs cardio (0x180D)")…")
        }
    }

    func stopScan() {
        central?.stopScan()
        scanningRole = nil
    }

    /// Connexion à un appareil déjà vu ou mémorisé.
    func connect(id: UUID, role: Role) {
        whenPoweredOn { [weak self] in
            guard let self, let central = self.central else { return }
            let p = self.peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
            guard let p else {
                self.log.log(.warning, "Appareil \(id) introuvable : relancez une recherche")
                return
            }
            self.peripherals[id] = p
            self.roles[id] = role
            self.log.log(.ble, "Connexion à \(p.name ?? id.uuidString)…")
            central.connect(p, options: nil)
        }
    }

    func cancelConnection(id: UUID) {
        guard let central, let p = peripherals[id] else { return }
        roles[id] = nil
        central.cancelPeripheralConnection(p)
    }

    func role(of id: UUID) -> Role? { roles[id] }

    // MARK: - Délégué

    fileprivate func didUpdateState(_ s: CBManagerState) {
        state = s
        log.log(.ble, stateLabel)
        if s == .poweredOn {
            let work = pendingAfterPowerOn
            pendingAfterPowerOn.removeAll()
            work.forEach { $0() }
        }
    }

    fileprivate func didDiscover(_ p: CBPeripheral, advertisement: [String: Any], rssi: NSNumber) {
        guard let role = scanningRole else { return }
        peripherals[p.identifier] = p
        let advName = advertisement[CBAdvertisementDataLocalNameKey] as? String
        let name = p.name ?? advName ?? "Appareil sans nom"
        if let i = discovered.firstIndex(where: { $0.id == p.identifier }) {
            discovered[i].rssi = rssi.intValue
            discovered[i].lastSeen = Date()
            discovered[i].name = name
        } else {
            discovered.append(Discovered(id: p.identifier, name: name, rssi: rssi.intValue, role: role, lastSeen: Date()))
            log.log(.ble, "Trouvé : \(name) (RSSI \(rssi))")
        }
    }

    fileprivate func didConnect(_ p: CBPeripheral) {
        guard let role = roles[p.identifier] else {
            central?.cancelPeripheralConnection(p)
            return
        }
        log.log(.ble, "Connecté : \(p.name ?? p.identifier.uuidString)")
        onConnect[role]?(p)
    }

    fileprivate func didFailToConnect(_ p: CBPeripheral, error: Error?) {
        log.log(.error, "Échec de connexion : \(error?.localizedDescription ?? "inconnu")")
        if let role = roles[p.identifier] { onFailToConnect[role]?(p, error) }
    }

    fileprivate func didDisconnect(_ p: CBPeripheral, error: Error?) {
        log.log(.ble, "Déconnecté : \(p.name ?? p.identifier.uuidString)" + (error.map { " (\($0.localizedDescription))" } ?? ""))
        if let role = roles[p.identifier] { onDisconnect[role]?(p, error) }
    }
}

/// Proxy NSObject pour le délégué CoreBluetooth (évite de mélanger @Observable et NSObject).
private final class CentralProxy: NSObject, CBCentralManagerDelegate {
    weak var owner: BluetoothHub?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        owner?.didUpdateState(central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        owner?.didDiscover(peripheral, advertisement: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        owner?.didConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        owner?.didFailToConnect(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        owner?.didDisconnect(peripheral, error: error)
    }
}
