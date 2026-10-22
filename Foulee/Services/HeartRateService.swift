import Foundation
import CoreBluetooth
import Observation
import TreadCore

/// Sources cardio : ceinture BLE (0x180D), Apple Watch (via WatchBridge), capteur du tapis.
/// Une seule source active, choisie par `HeartRateMonitor`.
@Observable
final class HeartRateService {
    enum SensorConnection: Equatable {
        case none, connecting(String), connected(String), reconnecting(String)
        var label: String {
            switch self {
            case .none: return "Aucune ceinture"
            case let .connecting(n): return "Connexion à \(n)…"
            case let .connected(n): return n
            case let .reconnecting(n): return "Reconnexion à \(n)…"
            }
        }
    }

    private(set) var status: HeartRateStatus = .unavailable
    private(set) var sensorConnection: SensorConnection = .none
    private(set) var sensorContact: HeartRateMeasurement.SensorContact?
    private(set) var lastBySource: [HeartRateSource: HeartRateReading] = [:]

    @ObservationIgnored let monitor: HeartRateMonitor
    @ObservationIgnored private let hub: BluetoothHub
    @ObservationIgnored private let log: DiagnosticLog
    @ObservationIgnored private var link: HeartRateSensorLink?
    @ObservationIgnored private var sensorID: UUID?
    @ObservationIgnored private var sensorName: String?
    @ObservationIgnored private var wantConnected = false
    @ObservationIgnored var onSensorRemembered: ((UUID, String) -> Void)?
    @ObservationIgnored private var lastLoggedBPMAt: TimeInterval = 0

    init(hub: BluetoothHub, log: DiagnosticLog, preference: HeartRateSourcePreference) {
        self.hub = hub
        self.log = log
        monitor = HeartRateMonitor(preference: preference)
        monitor.onSourceChange = { [weak log] old, new in
            log?.log(.heart, "Source cardio : \(old?.label ?? "aucune") → \(new?.label ?? "aucune")")
        }
        hub.onConnect[.heartRate] = { [weak self] p in self?.didConnect(p) }
        hub.onDisconnect[.heartRate] = { [weak self] p, _ in self?.didDisconnect(p) }
        hub.onFailToConnect[.heartRate] = { [weak self] _, _ in
            self?.sensorConnection = .none
            self?.wantConnected = false
        }
    }

    func setPreference(_ p: HeartRateSourcePreference) {
        monitor.preference = p
        refresh()
    }

    func connectSensor(id: UUID, name: String) {
        wantConnected = true
        sensorID = id
        sensorName = name
        sensorConnection = .connecting(name)
        hub.connect(id: id, role: .heartRate)
    }

    func disconnectSensor() {
        wantConnected = false
        if let id = sensorID { hub.cancelConnection(id: id) }
        link = nil
        sensorConnection = .none
        monitor.clear(source: .bleSensor)
        refresh()
    }

    /// Mesure Apple Watch. `sampleAge` = ancienneté de l'échantillon HealthKit à réception.
    func ingestWatch(bpm: Double, sampleAge: TimeInterval) {
        let now = MonotonicClock.now()
        monitor.ingest(HeartRateReading(bpm: Int(bpm.rounded()), receivedAt: now - max(0, sampleAge), source: .appleWatch))
        refresh()
    }

    func refresh() {
        let now = MonotonicClock.now()
        let s = monitor.status(now: now)
        if s != status { status = s }
        if lastBySource != monitor.latest { lastBySource = monitor.latest }
    }

    private func didConnect(_ p: CBPeripheral) {
        let name = p.name ?? sensorName ?? "Capteur cardio"
        sensorConnection = .connected(name)
        onSensorRemembered?(p.identifier, name)
        let l = HeartRateSensorLink(peripheral: p, log: log)
        l.onMeasurement = { [weak self] m in self?.handle(m) }
        link = l
        l.start()
    }

    private func didDisconnect(_ p: CBPeripheral) {
        link = nil
        monitor.clear(source: .bleSensor)
        refresh()
        if wantConnected {
            sensorConnection = .reconnecting(sensorName ?? "capteur")
            hub.connect(id: p.identifier, role: .heartRate)
        } else {
            sensorConnection = .none
        }
    }

    private func handle(_ m: HeartRateMeasurement) {
        sensorContact = m.contact
        let now = MonotonicClock.now()
        if m.isUsable {
            monitor.ingest(HeartRateReading(bpm: m.bpm, receivedAt: now, source: .bleSensor))
        }
        if now - lastLoggedBPMAt > 10 {
            lastLoggedBPMAt = now
            log.log(.heart, "Ceinture : \(m.bpm) bpm" + (m.contact == .notDetected ? " (pas de contact)" : ""))
        }
        refresh()
    }
}
