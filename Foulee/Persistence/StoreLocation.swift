import Foundation
import SwiftData
import TreadCore

/// Emplacement de la base SwiftData de Foulée.
///
/// Toujours dans le conteneur **privé** de l'app, à l'emplacement d'origine. Sans URL explicite,
/// SwiftData place la base dans le premier App Group des entitlements (`groupContainer:
/// .automatic`) : depuis l'ajout du dossier partagé avec Rythme, Foulée ouvrait une autre base
/// (vide, ou celle de Rythme) et l'historique semblait avoir disparu.
enum StoreLocation {
    static let schema = Schema([ProgramEntity.self, SessionEntity.self])

    /// Emplacement par défaut de SwiftData avant l'App Group : les données existantes y sont.
    static var url: URL { URL.applicationSupportDirectory.appending(path: "default.store") }

    /// Base ouverte par erreur dans le dossier commun (version précédente de Foulée).
    static var misplacedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RythmeShare.appGroup)?
            .appending(path: "Library/Application Support/default.store")
    }

    /// Erreur d'ouverture de la base (l'app tourne alors sans enregistrer : à signaler).
    private(set) static var openError: String?

    static func makeContainer() -> ModelContainer {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let config = ModelConfiguration(schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            openError = error.localizedDescription
            // Dernier recours : stockage en mémoire pour que l'app reste utilisable.
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    /// Une seule fois : séances et programmes personnels enregistrés dans la base ouverte par
    /// erreur dans le dossier commun, recopiés dans la vraie base (ceux qui y manquent).
    /// Ouverture en lecture seule : une base qui n'est pas celle de Foulée (Rythme) est refusée
    /// sans être modifiée.
    static func recoverMisplacedData(into store: DataStore, log: DiagnosticLog, defaults: UserDefaults = .standard) {
        let doneKey = "foulee.store.misplacedRecovered"
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let u = misplacedURL, FileManager.default.fileExists(atPath: u.path) else { return }
        do {
            let config = ModelConfiguration(schema: schema, url: u, allowsSave: false, cloudKitDatabase: .none)
            let other = ModelContext(try ModelContainer(for: schema, configurations: config))
            var sessions = 0, programs = 0
            for e in try other.fetch(FetchDescriptor<SessionEntity>()) {
                guard let r = e.record, store.record(id: r.id) == nil else { continue }
                store.upsert(r)
                sessions += 1
            }
            // Programmes prédéfinis : déjà présents (même modèle) ; seuls les programmes personnels.
            let known = Set(store.allPrograms().map(\.id))
            for e in try other.fetch(FetchDescriptor<ProgramEntity>()) {
                guard let p = e.program, p.templateID == nil, !known.contains(p.id) else { continue }
                store.upsert(p)
                programs += 1
            }
            log.log(.info, "Base du dossier commun : \(sessions) séance(s) et \(programs) programme(s) récupérés")
        } catch {
            log.log(.info, "Base du dossier commun non lue (pas celle de Foulée) : \(error.localizedDescription)")
        }
    }
}
