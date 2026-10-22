import Foundation
import CoreBluetooth
import TreadCore

/// Lien GATT vers un tapis FTMS réel.
///
/// Séquence : découverte des services 0x1826 et 0x180A → lecture Feature et plages →
/// activation des notifications (Treadmill Data, Status, Training Status) et des
/// indications (Control Point) → « prêt ». Aucune commande n'est envoyée ici.
final class FTMSLink: NSObject, CBPeripheralDelegate, ControlPointWriter {
    let peripheral: CBPeripheral
    private let controller: TreadmillController
    private let log: DiagnosticLog
    private let profile: TreadmillProfile

    private var controlPoint: CBCharacteristic?
    private var feature: FitnessMachineFeature?
    private var speedRange: SpeedRange?
    private var inclinationRange: InclinationRange?
    private var pendingReads = Set<String>()
    private var controlPointIndicating = false
    private var dataNotifying = false
    private var announcedReady = false
    private var capabilitiesSent = false
    private var exploring = false
    private var listenUnknown = false

    private(set) var deviceInfo: [String: String] = [:]
    var onReadyChange: ((Bool) -> Void)?
    var onInfoChange: (() -> Void)?
    /// Appelé à chaque paquet de télémétrie (pour faire avancer la séance même en arrière-plan).
    var onTelemetryPacket: (() -> Void)?

    init(peripheral: CBPeripheral, controller: TreadmillController, profile: TreadmillProfile, log: DiagnosticLog) {
        self.peripheral = peripheral
        self.controller = controller
        self.profile = profile
        self.log = log
        super.init()
        peripheral.delegate = self
    }

    func start() {
        log.log(.ble, "Découverte des services FTMS…")
        peripheral.discoverServices([CBUUID(string: GATTID.fitnessMachineService),
                                     CBUUID(string: GATTID.deviceInformationService)])
    }

    /// Diagnostic explicite : liste tous les services/caractéristiques et lit celles qui sont lisibles.
    /// Avec `listenToUnknown`, s'abonne aussi aux notifications hors FTMS (journalisées en brut),
    /// utile pour repérer un éventuel compteur de pas propriétaire.
    func exploreAll(listenToUnknown: Bool) {
        exploring = true
        listenUnknown = listenToUnknown
        log.log(.ble, "Exploration GATT complète demandée")
        peripheral.discoverServices(nil)
    }

    // MARK: - ControlPointWriter

    func writeControlPoint(_ bytes: [UInt8]) -> Bool {
        guard let cp = controlPoint, peripheral.state == .connected else { return false }
        peripheral.writeValue(Data(bytes), for: cp, type: .withResponse)
        return true
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log.log(.error, "Découverte des services : \(error.localizedDescription)")
            return
        }
        for s in peripheral.services ?? [] {
            if exploring {
                log.log(.ble, "Service \(s.uuid.uuidString) — \(GATTID.name(for: s.uuid.uuidString))")
                peripheral.discoverCharacteristics(nil, for: s)
                continue
            }
            switch s.uuid.uuidString.uppercased() {
            case GATTID.fitnessMachineService:
                peripheral.discoverCharacteristics(nil, for: s)
            case GATTID.deviceInformationService:
                peripheral.discoverCharacteristics([GATTID.manufacturerName, GATTID.modelNumber, GATTID.firmwareRevision,
                                                    GATTID.hardwareRevision, GATTID.softwareRevision].map { CBUUID(string: $0) }, for: s)
            default:
                break
            }
        }
        if !exploring && !(peripheral.services ?? []).contains(where: { $0.uuid.uuidString.uppercased() == GATTID.fitnessMachineService }) {
            log.log(.error, "Ce périphérique n'expose pas le service FTMS 0x1826")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log.log(.error, "Caractéristiques de \(service.uuid.uuidString) : \(error.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        if exploring {
            for c in chars {
                log.log(.ble, "  \(c.uuid.uuidString) — \(GATTID.name(for: c.uuid.uuidString)) [\(propertiesLabel(c.properties))]")
                if c.properties.contains(.read) { peripheral.readValue(for: c) }
                let isFTMS = service.uuid.uuidString.uppercased() == GATTID.fitnessMachineService
                if listenUnknown && !isFTMS && (c.properties.contains(.notify) || c.properties.contains(.indicate)) {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            return
        }
        let uuid = service.uuid.uuidString.uppercased()
        if uuid == GATTID.deviceInformationService {
            chars.forEach { peripheral.readValue(for: $0) }
            return
        }
        guard uuid == GATTID.fitnessMachineService else { return }
        log.log(.ble, "FTMS : " + chars.map { "\(GATTID.name(for: $0.uuid.uuidString)) [\(propertiesLabel($0.properties))]" }.joined(separator: ", "))
        for c in chars {
            switch c.uuid.uuidString.uppercased() {
            case GATTID.fitnessMachineFeature, GATTID.supportedSpeedRange, GATTID.supportedInclinationRange:
                pendingReads.insert(c.uuid.uuidString.uppercased())
                peripheral.readValue(for: c)
            case GATTID.treadmillData, GATTID.fitnessMachineStatus, GATTID.trainingStatus:
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
            case GATTID.fitnessMachineControlPoint:
                controlPoint = c
                // Indications obligatoires avant toute écriture (FTMS §4.16).
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
        if controlPoint == nil {
            log.log(.warning, "Pas de Control Point : lecture seule, aucune commande possible")
        }
        if pendingReads.isEmpty { sendCapabilities() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        let name = GATTID.name(for: c.uuid.uuidString)
        if let error {
            log.log(.error, "Abonnement \(name) refusé : \(error.localizedDescription)")
            return
        }
        log.log(.ble, "\(name) : \(c.isNotifying ? (c.properties.contains(.indicate) && !c.properties.contains(.notify) ? "indications" : "notifications") + " actives" : "abonnement arrêté")")
        switch c.uuid.uuidString.uppercased() {
        case GATTID.fitnessMachineControlPoint: controlPointIndicating = c.isNotifying
        case GATTID.treadmillData: dataNotifying = c.isNotifying
        default: break
        }
        checkReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let uuid = c.uuid.uuidString.uppercased()
        if let error {
            log.log(.error, "Lecture \(GATTID.name(for: uuid)) : \(error.localizedDescription)")
            if pendingReads.remove(uuid) != nil, pendingReads.isEmpty { sendCapabilities() }
            return
        }
        let bytes = [UInt8](c.value ?? Data())
        switch uuid {
        case GATTID.treadmillData:
            controller.handleTreadmillData(bytes)
            onTelemetryPacket?()
        case GATTID.fitnessMachineControlPoint:
            controller.handleControlPointIndication(bytes)
        case GATTID.fitnessMachineStatus:
            controller.handleMachineStatus(bytes)
        case GATTID.trainingStatus:
            if let t = try? TrainingStatus.decode(bytes) {
                log.log(.status, "Training Status : \(t.label)" + (t.text.map { " « \($0) »" } ?? ""), bytes: bytes)
            } else {
                log.log(.warning, "Training Status illisible", bytes: bytes)
            }
        case GATTID.fitnessMachineFeature:
            do {
                let f = try FitnessMachineFeature.decode(bytes)
                feature = f
                log.log(.rx, "Feature — mesures : \(f.machineDescription) ; consignes : \(f.targetDescription)", bytes: bytes)
            } catch { log.log(.error, "Feature illisible : \(error)", bytes: bytes) }
            readDone(uuid)
        case GATTID.supportedSpeedRange:
            do {
                let r = try SpeedRange.decode(bytes)
                speedRange = r
                log.log(.rx, String(format: "Plage vitesse : %.2f–%.2f km/h, pas %.2f", r.minKmh, r.maxKmh, r.incrementKmh), bytes: bytes)
            } catch { log.log(.error, "Plage vitesse illisible : \(error)", bytes: bytes) }
            readDone(uuid)
        case GATTID.supportedInclinationRange:
            do {
                let r = try InclinationRange.decode(bytes)
                inclinationRange = r
                log.log(.rx, String(format: "Plage inclinaison : %.1f–%.1f %%, pas %.1f", r.minPercent, r.maxPercent, r.incrementPercent), bytes: bytes)
            } catch { log.log(.error, "Plage inclinaison illisible : \(error)", bytes: bytes) }
            readDone(uuid)
        case GATTID.manufacturerName, GATTID.modelNumber, GATTID.firmwareRevision, GATTID.hardwareRevision, GATTID.softwareRevision:
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            deviceInfo[GATTID.name(for: uuid)] = text
            log.log(.rx, "\(GATTID.name(for: uuid)) : \(text)")
            onInfoChange?()
        default:
            log.log(.rx, "\(GATTID.name(for: uuid)) (\(uuid))", bytes: bytes)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid.uuidString.uppercased() == GATTID.fitnessMachineControlPoint else { return }
        controller.handleControlPointWrite(error: error?.localizedDescription)
    }

    // MARK: - Interne

    private func readDone(_ uuid: String) {
        if pendingReads.remove(uuid) != nil, pendingReads.isEmpty { sendCapabilities() }
    }

    private func sendCapabilities() {
        guard !capabilitiesSent else { return }
        capabilitiesSent = true
        let fallback = profile.fallbackCapabilities
        let caps = TreadmillCapabilities(
            speed: speedRange ?? fallback.speed,
            inclination: inclinationRange ?? (feature?.targetSettings.contains(.inclination) == true ? fallback.inclination : nil),
            feature: feature,
            speedRangeFromDevice: speedRange != nil,
            inclinationRangeFromDevice: inclinationRange != nil)
        if speedRange == nil { log.log(.warning, "Plage de vitesse non lue : valeurs du profil utilisées") }
        controller.setCapabilities(caps)
        checkReady()
    }

    private func checkReady() {
        let ready = controlPointIndicating && dataNotifying && capabilitiesSent
        if ready && !announcedReady {
            announcedReady = true
            controller.linkDidBecomeReady()
            onReadyChange?(true)
        }
    }

    private func propertiesLabel(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("lecture") }
        if p.contains(.write) { out.append("écriture") }
        if p.contains(.writeWithoutResponse) { out.append("écriture sans réponse") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ", ")
    }
}

/// Lien vers une ceinture/brassard Heart Rate Service.
final class HeartRateSensorLink: NSObject, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    private let log: DiagnosticLog
    var onMeasurement: ((HeartRateMeasurement) -> Void)?

    init(peripheral: CBPeripheral, log: DiagnosticLog) {
        self.peripheral = peripheral
        self.log = log
        super.init()
        peripheral.delegate = self
    }

    func start() {
        peripheral.discoverServices([CBUUID(string: GATTID.heartRateService)])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid.uuidString.uppercased() == GATTID.heartRateService {
            peripheral.discoverCharacteristics([CBUUID(string: GATTID.heartRateMeasurement)], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid.uuidString.uppercased() == GATTID.heartRateMeasurement {
            peripheral.setNotifyValue(true, for: c)
            log.log(.heart, "Abonnement Heart Rate Measurement")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        do {
            onMeasurement?(try HeartRateMeasurement.decode([UInt8](data)))
        } catch {
            log.log(.warning, "Mesure FC illisible : \(error)", bytes: [UInt8](data))
        }
    }
}
