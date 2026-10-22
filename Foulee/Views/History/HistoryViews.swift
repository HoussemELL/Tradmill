import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import TreadCore

struct HistoryListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SessionEntity.startDate, order: .reverse) private var sessions: [SessionEntity]
    @State private var exportDoc: ExportDocument?

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { s in
                    NavigationLink(value: s.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(s.title).font(.headline)
                                if s.simulated { StatusPill(text: "Simulé", systemImage: "cpu", color: .purple) }
                                if s.interrupted { StatusPill(text: "Interrompue", systemImage: "exclamationmark.triangle", color: Theme.warning) }
                            }
                            Text(Format.shortDate(s.startDate)).font(.caption).foregroundStyle(.secondary)
                            Text("\(Format.duration(s.activeSeconds)) · \(Format.distance(s.distanceMeters))"
                                 + (s.avgHR.map { " · \($0) bpm moy." } ?? "")
                                 + (s.steps.map { " · \($0) pas" } ?? ""))
                                .font(.subheadline).monospacedDigit()
                        }
                    }
                }
                .onDelete { idx in
                    idx.map { sessions[$0] }.forEach { context.delete($0) }
                    try? context.save()
                }
                if sessions.isEmpty {
                    Text("Aucune séance enregistrée.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Historique")
            .navigationDestination(for: UUID.self) { id in
                if let e = sessions.first(where: { $0.id == id }) { HistoryDetailView(entity: e) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let records = sessions.compactMap(\.record)
                        if let data = try? SessionExport.json(records) {
                            exportDoc = ExportDocument(data: data, contentType: .json, filename: "seances_foulee.json")
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(sessions.isEmpty)
                    .accessibilityLabel("Exporter tout l'historique en JSON")
                }
            }
            .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                          document: exportDoc, contentType: exportDoc?.contentType ?? .json,
                          defaultFilename: exportDoc?.filename) { _ in }
        }
    }
}

struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    let entity: SessionEntity
    @State private var exportDoc: ExportDocument?
    @State private var message: String?
    @State private var showEvents = false
    @State private var savingHealth = false

    var body: some View {
        if let r = entity.record {
            content(r)
        } else {
            Text("Séance illisible").foregroundStyle(.secondary)
        }
    }

    private func content(_ r: SessionRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Format.shortDate(r.startDate) + (r.treadmillName.map { " · \($0)" } ?? "") + (r.simulated ? " · SIMULATEUR" : ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                if r.interrupted {
                    Banner(text: "Séance récupérée après une fermeture inattendue : données jusqu'à la dernière sauvegarde.")
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    MetricTile(title: "Temps actif", value: Format.duration(r.activeSeconds), detail: "pauses : \(Format.duration(r.pausedSeconds))")
                    MetricTile(title: "Distance", value: Format.distance(r.distanceMeters), detail: r.distanceSource.label)
                    MetricTile(title: "Vitesse", value: Format.speed(r.avgSpeed), unit: "km/h", detail: "max \(Format.speed(r.maxSpeed))")
                    MetricTile(title: "Inclinaison", value: Format.incline(r.avgIncline), unit: "%", detail: "max \(Format.incline(r.maxIncline))")
                    MetricTile(title: "FC", value: r.avgHR.map { "\($0)" } ?? "—", unit: "bpm",
                               detail: "max \(r.maxHR.map { "\($0)" } ?? "—") · " + r.hrSources.map(\.shortLabel).joined(separator: ", "))
                    MetricTile(title: "Pas", value: r.steps.map { "\($0)" } ?? "—", detail: r.stepsSource.label)
                }
                caloriesCard(r)
                chartCard("Fréquence cardiaque", r, .heartRate)
                chartCard("Vitesse (mesure / cible)", r, .speed)
                chartCard("Inclinaison (mesure / cible)", r, .incline)
                ZoneBars(seconds: r.zoneSeconds)
                if let z = r.zoneSettings {
                    Text(z.methodDescription).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Événements (\(r.events.count))", isExpanded: $showEvents) {
                    ForEach(Array(r.events.enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .top) {
                            Text(Format.duration(e.t)).font(.caption.monospacedDigit()).frame(width: 56, alignment: .leading)
                            Text(e.detail).font(.caption)
                        }
                    }
                }
                .padding()
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Label(r.healthStatus.label, systemImage: "heart.text.square")
                    if canSaveToHealth(r) {
                        Button {
                            saveToHealth(r)
                        } label: {
                            Label(savingHealth ? "Enregistrement…" : "Enregistrer dans Santé", systemImage: "square.and.arrow.down")
                        }
                        .disabled(savingHealth)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                if let message { Banner(text: message, color: Theme.accent, systemImage: "checkmark.circle") }
            }
            .padding()
        }
        .navigationTitle(r.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Exporter en JSON") {
                        if let d = try? SessionExport.json([r]) {
                            exportDoc = ExportDocument(data: d, contentType: .json, filename: SessionExport.fileName(for: r, ext: "json"))
                        }
                    }
                    Button("Exporter en CSV") {
                        exportDoc = ExportDocument(data: Data(SessionExport.csv(r).utf8), contentType: .commaSeparatedText,
                                                   filename: SessionExport.fileName(for: r, ext: "csv"))
                    }
                    Button("Enregistrer comme modèle") {
                        if let p = r.derivedProgram(name: "Modèle — \(r.title)") {
                            model.dataStore.upsert(p)
                            message = "Programme « \(p.name) » créé."
                        } else {
                            message = "Pas assez de données pour créer un modèle."
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: exportDoc?.contentType ?? .json,
                      defaultFilename: exportDoc?.filename) { _ in }
    }

    private func caloriesCard(_ r: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Énergie").font(.headline)
            Text("Tapis : \(r.calories.treadmillKcal.map { String(format: "%.0f kcal", $0) } ?? "—")")
            Text("Apple Watch (actives) : \(r.calories.healthKitActiveKcal.map { String(format: "%.0f kcal", $0) } ?? "—")")
            Text("Estimation : \(r.calories.estimatedKcal.map { String(format: "%.0f kcal (estimée)", $0) } ?? "—")")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func chartCard(_ title: String, _ r: SessionRecord, _ m: SessionSeriesChart.Metric) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            SessionSeriesChart(record: r, metric: m).frame(height: 150)
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func canSaveToHealth(_ r: SessionRecord) -> Bool {
        guard model.health.isAvailable, model.settings.health.enabled else { return false }
        switch r.healthStatus {
        case .saved, .ownedByWatch: return false
        default: return !r.simulated
        }
    }

    private func saveToHealth(_ r: SessionRecord) {
        savingHealth = true
        let plan = HealthSyncPlan.make(record: r, settings: model.settings.health, watchWorkoutUsed: false)
        Task {
            var updated = r
            updated.healthStatus = await model.health.save(r, plan: plan)
            model.dataStore.upsert(updated)
            message = updated.healthStatus.label
            savingHealth = false
        }
    }
}
