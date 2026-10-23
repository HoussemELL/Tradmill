import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import TreadCore

struct ProgramListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \ProgramEntity.sortIndex) private var programs: [ProgramEntity]
    @State private var editing: WorkoutProgram?
    @State private var showImporter = false
    @State private var exportDoc: ExportDocument?
    @State private var alert: String?
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(programs) { entity in
                    Button {
                        editing = entity.program
                    } label: {
                        ProgramRow(entity: entity)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(entity) } label: { Label("Supprimer", systemImage: "trash") }
                        Button { duplicate(entity) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button { duplicate(entity) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
                        Button { export([entity]) } label: { Label("Exporter (JSON)", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { delete(entity) } label: { Label("Supprimer", systemImage: "trash") }
                    }
                }
                .onMove(perform: move)
                if programs.isEmpty {
                    Text("Aucun programme. Créez-en un avec +.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Programmes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = newProgram() } label: { Label("Nouveau programme", systemImage: "plus") }
                        Button { showImporter = true } label: { Label("Importer (JSON)", systemImage: "square.and.arrow.down") }
                        Button { export(programs) } label: { Label("Tout exporter (JSON)", systemImage: "square.and.arrow.up") }
                            .disabled(programs.isEmpty)
                        Divider()
                        Button {
                            let n = model.restoreTemplates(resetExisting: false)
                            alert = n == 0 ? "Tous les programmes prédéfinis sont déjà présents." : "\(n) programme(s) prédéfini(s) restauré(s)."
                        } label: { Label("Restaurer les programmes prédéfinis", systemImage: "arrow.counterclockwise") }
                        Button(role: .destructive) { confirmReset = true } label: {
                            Label("Réinitialiser les programmes prédéfinis", systemImage: "arrow.uturn.backward")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .accessibilityLabel("Ajouter, importer ou exporter")
                }
            }
            .sheet(item: $editing) { p in
                ProgramEditorView(program: p) { saved in
                    model.dataStore.upsert(saved)
                }
            }
            .onAppear {
                if let open = ScenarioRunner.value("-FouleeOpen"), open.hasPrefix("program:"), editing == nil {
                    editing = programs.first { $0.name == String(open.dropFirst(8)) }?.program
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                importFile(result)
            }
            .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                          document: exportDoc, contentType: .json, defaultFilename: exportDoc?.filename) { _ in }
            .confirmationDialog("Remettre les programmes prédéfinis à leur état d'origine ?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("Réinitialiser", role: .destructive) {
                    let n = model.restoreTemplates(resetExisting: true)
                    alert = "\(n) programme(s) prédéfini(s) réinitialisé(s). Vos copies et programmes personnels ne changent pas."
                }
            } message: {
                Text("Vos modifications des programmes prédéfinis seront perdues (Cardio Baseline est reverrouillé).")
            }
            .alert("Programmes", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("OK") { alert = nil }
            } message: { Text(alert ?? "") }
        }
    }

    private func newProgram() -> WorkoutProgram {
        let caps = model.treadmill.capabilities
        let base = caps.snapSpeed(4.0)
        return WorkoutProgram(name: "Nouveau programme", items: [
            .phase(.init(name: "Échauffement", kind: .warmup, durationSeconds: 300, speedKmh: caps.snapSpeed(3.5))),
            .phase(.init(name: "Marche", kind: .steady, durationSeconds: 1200, speedKmh: base)),
            .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 300, speedKmh: caps.snapSpeed(3.0))),
        ])
    }

    private func delete(_ e: ProgramEntity) {
        context.delete(e)
        try? context.save()
    }

    private func duplicate(_ e: ProgramEntity) {
        guard let p = e.program else { return }
        model.dataStore.upsert(p.duplicated())
    }

    private func move(from: IndexSet, to: Int) {
        var list = programs
        list.move(fromOffsets: from, toOffset: to)
        for (i, e) in list.enumerated() { e.sortIndex = i }
        try? context.save()
    }

    private func export(_ entities: [ProgramEntity]) {
        let list = entities.compactMap(\.program)
        guard let data = try? ProgramExchange.export(list) else { alert = "Export impossible"; return }
        let name = list.count == 1 ? "programme_\(list[0].name)" : "programmes_foulee"
        exportDoc = ExportDocument(data: data, contentType: .json, filename: name + ".json")
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case let .failure(e):
            alert = e.localizedDescription
        case let .success(url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let imported = try ProgramExchange.importPrograms(from: data)
                imported.forEach { model.dataStore.upsert($0) }
                let incompatible = imported.filter {
                    !ProgramValidator.validate($0, against: model.treadmill.capabilities).isEmpty
                }.count
                alert = "\(imported.count) programme(s) importé(s)."
                    + (incompatible > 0 ? " \(incompatible) incompatible(s) avec le tapis actuel : à corriger avant lancement." : "")
            } catch let e as ProgramExchangeError {
                alert = e.description
            } catch {
                alert = error.localizedDescription
            }
        }
    }
}

struct ProgramRow: View {
    let entity: ProgramEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entity.name).font(.headline).foregroundStyle(.primary)
                if entity.program?.isLocked == true {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(Theme.warning).accessibilityLabel("verrouillé")
                }
                if entity.program?.hasAutoSpeed == true {
                    StatusPill(text: "FC auto", systemImage: "heart.circle", color: Theme.accent)
                }
            }
            if let p = entity.program { ProgramBadges(program: p) }
            if let p = entity.program {
                Text("\(p.schedule.count) phases · \(Format.duration(TimeInterval(p.totalDurationSeconds))) · max \(Format.speed(p.maxSpeedKmh)) km/h")
                    .font(.caption).foregroundStyle(.secondary)
                ProgramChart(program: p, compact: true).frame(height: 36).allowsHitTesting(false)
            }
        }
        .padding(.vertical, 4)
    }
}
