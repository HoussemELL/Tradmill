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
                ForEach(ProgramCategory.allCases) { cat in
                    let items = entities(in: cat)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { entity in
                                if let p = entity.program {
                                    Button { editing = p } label: { ProgramCardView(program: p) }
                                        .buttonStyle(.plain)
                                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
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
                            }
                            .onMove { move(in: cat, from: $0, to: $1) }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.title).font(.title3.bold()).foregroundStyle(.primary)
                                Text(cat.subtitle).font(.footnote).foregroundStyle(.secondary)
                            }
                            .textCase(nil)
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                if programs.isEmpty {
                    ContentUnavailableView("Aucun programme", systemImage: "list.bullet.rectangle",
                                           description: Text("Créez un programme avec +, ou restaurez les programmes prédéfinis."))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .screenBackground()
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

    private func entities(in cat: ProgramCategory) -> [ProgramEntity] {
        programs.filter { e in e.program.map { ProgramCategory.of($0) == cat } ?? (cat == .personal) }
    }

    /// Réorganisation dans une section ; l'ordre global (iPhone, accueil, Watch) suit les sections.
    private func move(in cat: ProgramCategory, from: IndexSet, to: Int) {
        var section = entities(in: cat)
        section.move(fromOffsets: from, toOffset: to)
        var order: [ProgramEntity] = []
        for c in ProgramCategory.allCases { order += c == cat ? section : entities(in: c) }
        for (i, e) in order.enumerated() { e.sortIndex = i }
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
