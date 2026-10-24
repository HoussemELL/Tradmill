import Foundation
import TreadCore

/// Partage automatique avec Rythme : un fichier `foulee.rythme.session` (docs/RYTHME.md) par
/// séance, dans le dossier commun des deux apps (App Group), sans export manuel.
///
/// - `<id>.json` réécrit à chaque enregistrement de la séance (fin, récupération FC, ressenti,
///   correction), supprimé avec elle ;
/// - séances simulées jamais écrites ;
/// - zones calculées avec les réglages actuels, comme à l'écran : tous les fichiers sont
///   réécrits quand la méthode ou la FC max change.
final class RythmeShare {
    static let appGroup = "group.com.houssemelloumi.rythme"

    /// nil : App Group absent de la signature (build non signé, simulateur sans capacité).
    let directory: URL?
    private let log: DiagnosticLog
    private let queue = DispatchQueue(label: "foulee.rythme-share", qos: .utility)
    private let defaults: UserDefaults
    private static let zonesKey = "foulee.rythmeShare.zones"

    init(log: DiagnosticLog, fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.log = log
        self.defaults = defaults
        directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent("Foulee/sessions", isDirectory: true)
        if directory == nil {
            log.log(.warning, "Partage Rythme indisponible : App Group \(Self.appGroup) absent de la signature")
        }
    }

    /// Enregistrement ou mise à jour d'une séance.
    func write(_ record: SessionRecord, zones: HeartZoneSettings) {
        guard let dir = directory else { return }
        guard !record.simulated else { return remove(id: record.id) }
        queue.async { [log] in
            Self.writeFile(record.rezoned(with: zones), in: dir, log: log)
        }
    }

    func remove(id: UUID) {
        guard let dir = directory else { return }
        queue.async {
            try? FileManager.default.removeItem(at: Self.url(id, in: dir))
        }
    }

    /// Au lancement et quand les zones changent : écrit les fichiers manquants (historique),
    /// réécrit tout si les zones ont changé depuis la dernière fois, retire les fichiers de
    /// séances supprimées ou simulées.
    ///
    /// Prudence : `records` doit venir d'une lecture réussie de la vraie base. Les fichiers des
    /// séances de `keep` (présentes mais illisibles) sont gardés, et rien n'est retiré si la base
    /// ne contient aucune séance (une suppression passe de toute façon par `remove(id:)`).
    func sync(_ records: [SessionRecord], keep: Set<UUID> = [], zones: HeartZoneSettings) {
        guard let dir = directory else { return }
        let key = Self.zonesFingerprint(zones)
        queue.async { [log, defaults] in
            // Lu dans la file : deux synchros rapprochées ne réécrivent pas tout deux fois.
            let zonesChanged = defaults.string(forKey: Self.zonesKey) != key
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            let shared = records.filter { !$0.simulated }
            var written = 0
            for r in shared where zonesChanged || !existing.contains(Self.fileName(r.id)) {
                if Self.writeFile(r.rezoned(with: zones), in: dir, log: log) { written += 1 }
            }
            let keepNames = Set(shared.map { Self.fileName($0.id) } + keep.map(Self.fileName))
            var removed = 0
            if !records.isEmpty || !keep.isEmpty {
                for name in existing where name.hasSuffix(".json") && !keepNames.contains(name) {
                    if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
                }
            }
            defaults.set(key, forKey: Self.zonesKey)
            if written > 0 || removed > 0 {
                Self.report(log, .session, "Partage Rythme : \(written) séance(s) écrite(s), \(removed) retirée(s)"
                            + (zonesChanged ? " (zones modifiées)" : ""))
            }
        }
    }

    // MARK: - Fichiers

    static func fileName(_ id: UUID) -> String { "\(id.uuidString).json" }

    static func url(_ id: UUID, in dir: URL) -> URL { dir.appendingPathComponent(fileName(id)) }

    static func zonesFingerprint(_ z: HeartZoneSettings) -> String {
        "\(z.effectiveMethod.rawValue)|\(z.bounds.map(String.init).joined(separator: ","))"
    }

    /// Le journal n'est pas thread-safe : écriture sur la file principale.
    private static func report(_ log: DiagnosticLog, _ category: DiagnosticLog.Category, _ message: String) {
        DispatchQueue.main.async { log.log(category, message) }
    }

    @discardableResult
    private static func writeFile(_ r: SessionRecord, in dir: URL, log: DiagnosticLog) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Un seul objet par fichier : même encodage que « Exporter pour Rythme ».
            try RythmeSessionExport.json([r]).write(to: url(r.id, in: dir), options: .atomic)
            return true
        } catch {
            report(log, .warning, "Partage Rythme : écriture impossible (\(r.id.uuidString)) : \(error.localizedDescription)")
            return false
        }
    }
}
