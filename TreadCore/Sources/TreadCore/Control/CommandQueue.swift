import Foundation

/// Origine d'une commande, conservée dans le journal.
public enum CommandOrigin: String, Sendable, Codable {
    case user = "utilisateur"
    case program = "programme"
    case autopilot = "pilote FC"
    case startSequence = "séquence démarrage"
    case resumeSequence = "séquence reprise"
    case safety = "sécurité"
    case diagnostic = "diagnostic"
    case reconcile = "vérification"
}

/// Résultat d'une commande du Control Point.
public enum CommandOutcome: Equatable, Sendable, CustomStringConvertible {
    case success
    case rejected(ControlResultCode)
    case timeout
    case writeFailed(String)
    case cancelled(String)
    case notReady

    public var isSuccess: Bool { self == .success }

    public var description: String {
        switch self {
        case .success: return "acquittée"
        case let .rejected(code): return "refusée (\(code))"
        case .timeout: return "sans réponse (délai dépassé)"
        case let .writeFailed(msg): return "écriture échouée (\(msg))"
        case let .cancelled(msg): return "annulée (\(msg))"
        case .notReady: return "lien non prêt"
        }
    }
}

/// Abstraction de l'écriture sur le Control Point (BLE réel ou simulateur).
public protocol ControlPointWriter: AnyObject {
    /// Écrit avec réponse. Renvoie `false` si l'écriture est impossible immédiatement.
    func writeControlPoint(_ bytes: [UInt8]) -> Bool
}

/// File série des commandes du Control Point.
///
/// Règles :
/// - une seule commande en vol ; la suivante part après la réponse (indication 0x80),
///   une erreur d'écriture ou le délai d'expiration ;
/// - espacement minimal entre deux envois ;
/// - aucune répétition automatique : un échec est remonté à l'appelant ;
/// - les consignes vitesse/inclinaison non encore envoyées sont fusionnées (la plus récente gagne) ;
/// - Stop/Pause passent en tête de file et annulent les consignes et démarrages en attente ;
/// - un Start déjà en attente ou en vol empêche un second Start (pas de double démarrage).
public final class CommandQueue {
    public struct Configuration: Equatable, Sendable {
        public var responseTimeout: TimeInterval
        public var minimumSpacing: TimeInterval
        public init(responseTimeout: TimeInterval = 4, minimumSpacing: TimeInterval = 0.25) {
            self.responseTimeout = responseTimeout
            self.minimumSpacing = minimumSpacing
        }
    }

    public typealias Completion = (CommandOutcome) -> Void

    struct Entry {
        let id: Int
        var command: ControlCommand
        let origin: CommandOrigin
        let enqueuedAt: TimeInterval
        var sentAt: TimeInterval?
        var writeAcknowledged = false
        var completions: [Completion]
    }

    public var configuration: Configuration
    public weak var writer: ControlPointWriter?
    public var log: DiagnosticLog?
    /// Réponse reçue après expiration du délai de la commande correspondante.
    public var onLateResponse: ((ControlPointResponse) -> Void)?

    /// Vrai quand les indications du Control Point sont actives (prérequis FTMS).
    public private(set) var isLinkReady = false

    private var pending: [Entry] = []
    private var inFlight: Entry?
    private var lastSendAt: TimeInterval = -.infinity
    private var nextID = 1
    private var lateResponseOpCodes: [UInt8] = []

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public var inFlightCommand: ControlCommand? { inFlight?.command }
    public var pendingCommands: [ControlCommand] { pending.map(\.command) }
    public var isIdle: Bool { inFlight == nil && pending.isEmpty }

    public func setLinkReady(_ ready: Bool, now: TimeInterval) {
        guard ready != isLinkReady else { return }
        isLinkReady = ready
        if ready {
            pump(now: now)
        } else {
            cancelAll(reason: "lien Control Point indisponible", outcome: .notReady)
        }
    }

    /// Ajoute une commande. Renvoie l'identifiant de l'entrée (ou nil si refusée immédiatement).
    @discardableResult
    public func enqueue(_ command: ControlCommand, origin: CommandOrigin, now: TimeInterval,
                        completion: Completion? = nil) -> Int? {
        let completions = completion.map { [$0] } ?? []
        guard isLinkReady else {
            log?.log(.command, "\(command) [\(origin.rawValue)] refusée : lien non prêt")
            completion?(.notReady)
            return nil
        }

        switch command {
        case .stop, .pause:
            // Déjà la même commande en vol ou en attente : on s'y rattache.
            if let f = inFlight, f.command == command {
                inFlight?.completions += completions
                return f.id
            }
            if let idx = pending.firstIndex(where: { $0.command == command }) {
                pending[idx].completions += completions
                return pending[idx].id
            }
            // Annule les consignes et démarrages en attente : ils ne doivent pas suivre un arrêt.
            let dropped = pending.filter { isCancelledBySafety($0.command) }
            pending.removeAll { isCancelledBySafety($0.command) }
            for d in dropped {
                log?.log(.command, "\(d.command) annulée par \(command)")
                d.completions.forEach { $0(.cancelled("annulée par \(command)")) }
            }
            let entry = makeEntry(command, origin, now, completions)
            pending.insert(entry, at: 0)
            log?.log(.command, "En file (prioritaire) : \(command) [\(origin.rawValue)]")
            pump(now: now)
            return entry.id

        case .startOrResume:
            if inFlight?.command == .startOrResume || pending.contains(where: { $0.command == .startOrResume }) {
                log?.log(.warning, "Start ignoré : un démarrage est déjà en cours")
                completion?(.cancelled("démarrage déjà en cours"))
                return nil
            }

        case .setTargetSpeed, .setTargetInclination:
            if let idx = pending.firstIndex(where: { sameKind($0.command, command) }) {
                let old = pending[idx]
                pending[idx].command = command
                pending[idx].completions = completions
                log?.log(.command, "\(old.command) remplacée par \(command) avant envoi")
                old.completions.forEach { $0(.cancelled("remplacée par une consigne plus récente")) }
                pump(now: now)
                return old.id
            }

        case .requestControl, .reset:
            if let idx = pending.firstIndex(where: { $0.command == command }) {
                pending[idx].completions += completions
                return pending[idx].id
            }
        }

        let entry = makeEntry(command, origin, now, completions)
        pending.append(entry)
        log?.log(.command, "En file : \(command) [\(origin.rawValue)]")
        pump(now: now)
        return entry.id
    }

    /// Traite une indication reçue sur le Control Point. Renvoie vrai si c'est une réponse.
    @discardableResult
    public func handleIndication(_ bytes: [UInt8], now: TimeInterval) -> Bool {
        let response: ControlPointResponse
        do {
            response = try ControlPointResponse.decode(bytes)
        } catch {
            log?.log(.error, "Indication Control Point illisible : \(error)", bytes: bytes)
            return false
        }
        let opLabel = ControlOpCode.label(forRaw: response.requestOpCode)
        guard let current = inFlight, current.command.opCode.rawValue == response.requestOpCode else {
            if let i = lateResponseOpCodes.firstIndex(of: response.requestOpCode) {
                lateResponseOpCodes.remove(at: i)
                log?.log(.response, "Réponse tardive : \(opLabel) → \(response.result)", bytes: bytes)
                onLateResponse?(response)
            } else {
                log?.log(.warning, "Réponse inattendue : \(opLabel) → \(response.result)", bytes: bytes)
            }
            return true
        }
        let latency = current.sentAt.map { String(format: " en %.0f ms", (now - $0) * 1000) } ?? ""
        log?.log(.response, "\(current.command) → \(response.result)\(latency)", bytes: bytes)
        complete(response.result == .success ? .success : .rejected(response.result), now: now)
        return true
    }

    /// Résultat de l'écriture GATT (callback didWriteValueFor).
    public func handleWriteResult(error: String?, now: TimeInterval) {
        guard inFlight != nil else { return }
        if let error {
            log?.log(.error, "Écriture Control Point échouée : \(error)")
            complete(.writeFailed(error), now: now)
        } else {
            inFlight?.writeAcknowledged = true
        }
    }

    /// À appeler régulièrement : gère les délais et l'envoi différé.
    public func tick(now: TimeInterval) {
        if let f = inFlight, let sent = f.sentAt, now - sent > configuration.responseTimeout {
            log?.log(.warning, "\(f.command) : aucune réponse après \(Int(configuration.responseTimeout)) s"
                     + (f.writeAcknowledged ? " (écriture acquittée par la pile BLE)" : ""))
            lateResponseOpCodes.append(f.command.opCode.rawValue)
            if lateResponseOpCodes.count > 8 { lateResponseOpCodes.removeFirst() }
            complete(.timeout, now: now)
            return
        }
        pump(now: now)
    }

    /// Acquittement implicite : le tapis a confirmé l'effet de la commande en vol par un autre
    /// canal (statut). Sans effet si une autre commande est en vol.
    @discardableResult
    public func resolveInFlight(_ command: ControlCommand, reason: String, now: TimeInterval) -> Bool {
        guard let f = inFlight, f.command == command else { return false }
        log?.log(.response, "\(f.command) → acquittement implicite (\(reason))")
        complete(.success, now: now)
        return true
    }

    public func cancelAll(reason: String, outcome: CommandOutcome? = nil) {
        let result = outcome ?? .cancelled(reason)
        let all = (inFlight.map { [$0] } ?? []) + pending
        inFlight = nil
        pending.removeAll()
        if !all.isEmpty {
            log?.log(.command, "\(all.count) commande(s) annulée(s) : \(reason)")
        }
        for e in all { e.completions.forEach { $0(result) } }
    }

    // MARK: - Interne

    private func makeEntry(_ c: ControlCommand, _ o: CommandOrigin, _ now: TimeInterval, _ comps: [Completion]) -> Entry {
        defer { nextID += 1 }
        return Entry(id: nextID, command: c, origin: o, enqueuedAt: now, completions: comps)
    }

    private func sameKind(_ a: ControlCommand, _ b: ControlCommand) -> Bool {
        switch (a, b) {
        case (.setTargetSpeed, .setTargetSpeed), (.setTargetInclination, .setTargetInclination): return true
        default: return false
        }
    }

    private func isCancelledBySafety(_ c: ControlCommand) -> Bool {
        switch c {
        case .setTargetSpeed, .setTargetInclination, .startOrResume: return true
        default: return false
        }
    }

    private func complete(_ outcome: CommandOutcome, now: TimeInterval) {
        guard let done = inFlight else { return }
        inFlight = nil
        done.completions.forEach { $0(outcome) }
        pump(now: now)
    }

    private func pump(now: TimeInterval) {
        guard isLinkReady, inFlight == nil, !pending.isEmpty else { return }
        guard now - lastSendAt >= configuration.minimumSpacing else { return }
        var entry = pending.removeFirst()
        let bytes = entry.command.encode()
        guard let writer else {
            log?.log(.error, "Aucun lien pour envoyer \(entry.command)")
            entry.completions.forEach { $0(.notReady) }
            pump(now: now)
            return
        }
        entry.sentAt = now
        lastSendAt = now
        inFlight = entry
        log?.log(.tx, "\(entry.command) [\(entry.origin.rawValue)]", bytes: bytes)
        if !writer.writeControlPoint(bytes) {
            log?.log(.error, "Écriture impossible pour \(entry.command)")
            complete(.writeFailed("écriture impossible"), now: now)
        }
    }
}
