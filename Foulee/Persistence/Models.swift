import Foundation
import SwiftData
import TreadCore

/// Programme persistant : le contenu est stocké en JSON (format versionné de TreadCore),
/// ce qui garde le schéma SwiftData simple et stable.
@Model
final class ProgramEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var totalSeconds: Int
    var sortIndex: Int
    var updatedAt: Date
    var payload: Data

    init(program: WorkoutProgram, sortIndex: Int) {
        id = program.id
        name = program.name
        totalSeconds = program.totalDurationSeconds
        self.sortIndex = sortIndex
        updatedAt = program.updatedAt
        payload = (try? CoreJSON.encode(program)) ?? Data()
    }

    var program: WorkoutProgram? {
        try? CoreJSON.decode(WorkoutProgram.self, from: payload)
    }

    func update(from program: WorkoutProgram) {
        name = program.name
        totalSeconds = program.totalDurationSeconds
        updatedAt = program.updatedAt
        payload = (try? CoreJSON.encode(program)) ?? payload
    }
}

/// Séance terminée. Le résumé est dupliqué en colonnes pour la liste ;
/// le détail complet (séries temporelles, événements) est dans `payload`.
@Model
final class SessionEntity {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var title: String
    var activeSeconds: Double
    var distanceMeters: Double
    var avgHR: Int?
    var steps: Int?
    var interrupted: Bool
    var simulated: Bool
    var healthLabel: String
    @Attribute(.externalStorage) var payload: Data

    init(record: SessionRecord) {
        id = record.id
        startDate = record.startDate
        title = record.title
        activeSeconds = record.activeSeconds
        distanceMeters = record.distanceMeters
        avgHR = record.avgHR
        steps = record.steps
        interrupted = record.interrupted
        simulated = record.simulated
        healthLabel = record.healthStatus.label
        payload = (try? SessionExport.encodeRecord(record)) ?? Data()
    }

    var record: SessionRecord? {
        try? SessionExport.decodeRecord(payload)
    }

    func update(from record: SessionRecord) {
        title = record.title
        activeSeconds = record.activeSeconds
        distanceMeters = record.distanceMeters
        avgHR = record.avgHR
        steps = record.steps
        interrupted = record.interrupted
        healthLabel = record.healthStatus.label
        payload = (try? SessionExport.encodeRecord(record)) ?? payload
    }
}

/// Accès aux données hors des vues (sauvegarde idempotente par identifiant).
final class DataStore {
    let context: ModelContext
    /// Appelés après chaque enregistrement / suppression **réussi** de séance (partage avec Rythme).
    var onSessionSaved: ((SessionRecord) -> Void)?
    var onSessionDeleted: ((UUID) -> Void)?
    /// Échec d'enregistrement : à montrer à l'utilisateur (rien n'est enregistré en silence).
    var onSaveError: ((String) -> Void)?

    /// Utiliser le `mainContext` du conteneur pour que les vues (@Query) voient les changements.
    init(context: ModelContext) {
        self.context = context
    }

    /// Enregistre ; en cas d'échec, annule les modifications en attente (l'écran ne montre pas
    /// une donnée absente de la base) et signale l'erreur.
    private func save(_ what: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            onSaveError?("\(what) : \(error.localizedDescription)")
            return false
        }
    }

    private func failed(_ what: String, _ error: Error) -> Bool {
        onSaveError?("\(what) : \(error.localizedDescription)")
        return false
    }

    @discardableResult
    func upsert(_ record: SessionRecord) -> Bool {
        let id = record.id
        let existing: [SessionEntity]
        do {
            existing = try context.fetch(FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.id == id }))
        } catch {
            // Lecture impossible : insérer créerait un doublon.
            return failed("Séance « \(record.title) » non enregistrée", error)
        }
        if let e = existing.first {
            e.update(from: record)
        } else {
            context.insert(SessionEntity(record: record))
        }
        guard save("Séance « \(record.title) » non enregistrée") else { return false }
        onSessionSaved?(record)
        return true
    }

    /// Séances pour le partage avec Rythme. nil si la base n'a pas pu être lue (rien ne doit
    /// alors être supprimé du dossier commun). Les séances illisibles sont listées à part, pour
    /// garder leur fichier.
    func sessionsForSharing() -> (records: [SessionRecord], undecodable: Set<UUID>)? {
        let d = FetchDescriptor<SessionEntity>(sortBy: [SortDescriptor(\.startDate)])
        guard let entities = try? context.fetch(d) else { return nil }
        var records: [SessionRecord] = []
        var undecodable = Set<UUID>()
        for e in entities {
            if let r = e.record { records.append(r) } else { undecodable.insert(e.id) }
        }
        return (records, undecodable)
    }

    @discardableResult
    func upsert(_ program: WorkoutProgram) -> Bool {
        let id = program.id
        let existing: [ProgramEntity]
        do {
            existing = try context.fetch(FetchDescriptor<ProgramEntity>(predicate: #Predicate { $0.id == id }))
        } catch {
            return failed("Programme « \(program.name) » non enregistré", error)
        }
        if let e = existing.first {
            e.update(from: program)
        } else {
            let count = (try? context.fetchCount(FetchDescriptor<ProgramEntity>())) ?? 0
            context.insert(ProgramEntity(program: program, sortIndex: count))
        }
        return save("Programme « \(program.name) » non enregistré")
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let d = FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.id == id })
        do {
            for e in try context.fetch(d) { context.delete(e) }
        } catch {
            return failed("Séance non supprimée", error)
        }
        guard save("Séance non supprimée") else { return false }
        onSessionDeleted?(id)
        return true
    }

    func deleteProgram(id: UUID) {
        let d = FetchDescriptor<ProgramEntity>(predicate: #Predicate { $0.id == id })
        for e in (try? context.fetch(d)) ?? [] { context.delete(e) }
        _ = save("Programme non supprimé")
    }

    func record(id: UUID) -> SessionRecord? {
        let d = FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(d))?.first?.record
    }

    /// Empreinte légère de la liste des programmes (sans décoder leur contenu).
    func programsFingerprint() -> String {
        let d = FetchDescriptor<ProgramEntity>(sortBy: [SortDescriptor(\.sortIndex)])
        return ((try? context.fetch(d)) ?? []).map { "\($0.id)|\($0.updatedAt.timeIntervalSince1970)|\($0.sortIndex)|\($0.payload.count)" }
            .joined(separator: ";")
    }

    func allPrograms() -> [WorkoutProgram] {
        let d = FetchDescriptor<ProgramEntity>(sortBy: [SortDescriptor(\.sortIndex)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.program)
    }
}
