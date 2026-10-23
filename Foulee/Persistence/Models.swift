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
    /// Appelés après chaque enregistrement / suppression de séance (partage avec Rythme).
    var onSessionSaved: ((SessionRecord) -> Void)?
    var onSessionDeleted: ((UUID) -> Void)?

    /// Utiliser le `mainContext` du conteneur pour que les vues (@Query) voient les changements.
    init(context: ModelContext) {
        self.context = context
    }

    func upsert(_ record: SessionRecord) {
        let id = record.id
        let existing = try? context.fetch(FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.id == id }))
        if let e = existing?.first {
            e.update(from: record)
        } else {
            context.insert(SessionEntity(record: record))
        }
        try? context.save()
        onSessionSaved?(record)
    }

    func allSessionRecords() -> [SessionRecord] {
        let d = FetchDescriptor<SessionEntity>(sortBy: [SortDescriptor(\.startDate)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.record)
    }

    func upsert(_ program: WorkoutProgram) {
        let id = program.id
        let existing = try? context.fetch(FetchDescriptor<ProgramEntity>(predicate: #Predicate { $0.id == id }))
        if let e = existing?.first {
            e.update(from: program)
        } else {
            let count = (try? context.fetchCount(FetchDescriptor<ProgramEntity>())) ?? 0
            context.insert(ProgramEntity(program: program, sortIndex: count))
        }
        try? context.save()
    }

    func delete(id: UUID) {
        let d = FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.id == id })
        for e in (try? context.fetch(d)) ?? [] { context.delete(e) }
        try? context.save()
        onSessionDeleted?(id)
    }

    func deleteProgram(id: UUID) {
        let d = FetchDescriptor<ProgramEntity>(predicate: #Predicate { $0.id == id })
        for e in (try? context.fetch(d)) ?? [] { context.delete(e) }
        try? context.save()
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
