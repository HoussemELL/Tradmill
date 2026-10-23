import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import TreadCore

struct HistoryListView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SessionEntity.startDate, order: .reverse) private var sessions: [SessionEntity]
    @State private var exportDoc: ExportDocument?
    @State private var pendingDelete: SessionRecord?
    @State private var deleteMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { s in
                    NavigationLink(value: s.id) {
                        HistoryRow(entity: s)
                    }
                }
                .onDelete { idx in
                    pendingDelete = idx.first.flatMap { sessions[$0].record }
                }
                if sessions.isEmpty {
                    Text("Aucune séance enregistrée.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Historique")
            .confirmationDialog("Supprimer cette séance ?", isPresented: Binding(get: { pendingDelete != nil },
                                                                                set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer (Foulée et Santé)", role: .destructive) {
                    if let r = pendingDelete {
                        Task { deleteMessage = await model.delete(r) }
                    }
                    pendingDelete = nil
                }
                Button("Annuler", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("La séance et ses échantillons sont aussi supprimés d'Apple Santé si Foulée les y a enregistrés.")
            }
            .alert("Suppression", isPresented: Binding(get: { deleteMessage != nil }, set: { if !$0 { deleteMessage = nil } })) {
                Button("OK") { deleteMessage = nil }
            } message: { Text(deleteMessage ?? "") }
            .navigationDestination(for: UUID.self) { id in
                if let e = sessions.first(where: { $0.id == id }) { HistoryDetailView(entity: e) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ProgressListView()
                    } label: {
                        Label("Progression", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
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

struct HistoryRow: View {
    let entity: SessionEntity

    private var summary: String {
        var parts: [String] = [Format.duration(entity.activeSeconds), Format.distance(entity.distanceMeters)]
        if let hr = entity.avgHR { parts.append("\(hr) bpm moy.") }
        if let steps = entity.steps { parts.append("\(steps) pas") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entity.title).font(.headline)
                if entity.simulated {
                    StatusPill(text: "Simulé", systemImage: "cpu", color: .purple)
                }
                if entity.interrupted {
                    StatusPill(text: "Interrompue", systemImage: "exclamationmark.triangle", color: Theme.warning)
                }
            }
            Text(Format.shortDate(entity.startDate)).font(.caption).foregroundStyle(.secondary)
            Text(summary).font(.subheadline).monospacedDigit()
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
    @State private var showReport = false
    @State private var editing = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

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
                    MetricTile(title: "Inclinaison", value: Format.incline(r.avgIncline), unit: "%", detail: "max \(Format.incline(r.maxIncline))")
                    MetricTile(title: "Source FC", value: r.hrSources.first?.shortLabel ?? "—", detail: hrDetail(r))
                    MetricTile(title: "Pas", value: r.steps.map { "\($0)" } ?? "—", detail: r.stepsSource.label)
                }
                SessionInsightsView(record: r)
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
                healthCard(r)
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
                    Button("Corriger la séance…") { editing = true }
                    if let rep = r.healthReport {
                        Button("Exporter le rapport Santé") {
                            exportDoc = ExportDocument(data: Data(rep.text.utf8), contentType: .plainText,
                                                       filename: SessionExport.fileName(for: r, ext: "sante.txt"))
                        }
                    }
                    Button("Supprimer la séance", role: .destructive) { confirmDelete = true }
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
        .sheet(isPresented: $editing) {
            SessionCorrectionView(record: r) { title, type, minutes in
                Task {
                    let updated = await model.correct(r, title: title, activityType: type, endAfterMinutes: minutes)
                    message = "Révision \(updated.revision ?? 2) enregistrée · \(updated.healthStatus.label)"
                }
            }
        }
        .confirmationDialog("Supprimer cette séance ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer (Foulée et Santé)", role: .destructive) {
                Task {
                    _ = await model.delete(r)
                    dismiss()
                }
            }
        } message: {
            Text("La séance et ses échantillons sont aussi supprimés d'Apple Santé si Foulée les y a enregistrés.")
        }
    }

    private func healthCard(_ r: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(r.healthStatus.label, systemImage: "heart.text.square").font(.headline)
            if let v = r.healthSyncVersion {
                Text("Version Santé : \(v)" + (r.revision.map { " · révision Foulée \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let rep = r.healthReport {
                DisclosureGroup("Ce qui a été écrit dans Santé", isExpanded: $showReport) {
                    Text(rep.text).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
    }

    private func hrDetail(_ r: SessionRecord) -> String {
        let maxText = r.maxHR.map { String($0) } ?? "—"
        let sources = r.hrSources.map { $0.shortLabel }.joined(separator: ", ")
        return "max \(maxText) · \(sources)"
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
        guard model.health.isAvailable, model.settings.health.enabled, !r.simulated else { return false }
        switch r.healthStatus {
        case .saved, .ownedByWatch: return false
        default: return true
        }
    }

    private func saveToHealth(_ r: SessionRecord) {
        savingHealth = true
        Task {
            let updated = await model.writeToHealth(r)
            model.dataStore.upsert(updated)
            message = updated.healthStatus.label
            savingHealth = false
        }
    }
}

/// Correction d'une séance : nom du programme, type d'activité, fin de séance.
/// Chaque correction crée une révision ; si Foulée avait écrit la séance dans Santé, elle y
/// est réécrite avec la même HKMetadataKeySyncIdentifier et une HKMetadataKeySyncVersion plus grande.
struct SessionCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    let record: SessionRecord
    let onSave: (String, HealthActivityType?, Double?) -> Void
    @State private var title: String
    @State private var type: HealthActivityType?
    @State private var trim = false
    @State private var minutes: Double

    init(record: SessionRecord, onSave: @escaping (String, HealthActivityType?, Double?) -> Void) {
        self.record = record
        self.onSave = onSave
        _title = State(initialValue: record.title)
        _type = State(initialValue: record.activityTypeOverride)
        let start = record.beltStartDate ?? record.startDate
        let end = record.beltStopDate ?? record.endDate ?? start
        _minutes = State(initialValue: max(1, (end.timeIntervalSince(start) / 60).rounded(.down)))
    }

    private var maxMinutes: Double {
        let start = record.beltStartDate ?? record.startDate
        let end = record.beltStopDate ?? record.endDate ?? start
        return max(1, (end.timeIntervalSince(start) / 60).rounded(.down))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Programme") {
                    TextField("Nom", text: $title)
                }
                Section {
                    Picker("Type d'activité", selection: $type) {
                        Text("Automatique (\(HealthWritePlan.activityType(record).label))").tag(HealthActivityType?.none)
                        ForEach(HealthActivityType.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                } footer: {
                    Text("Automatique : intervalles → HIIT, sinon course si la vitesse est ≥ 6,5 km/h la plupart du temps, sinon marche.")
                }
                Section {
                    Toggle("Raccourcir la séance", isOn: $trim)
                    if trim {
                        Stepper("Fin après \(Int(minutes)) min", value: $minutes, in: 1...maxMinutes)
                    }
                } footer: {
                    Text("Utile si la séance a été arrêtée trop tard. Les données après cette durée sont retirées.")
                }
                Section {
                    Text("Révision actuelle : \(record.revision ?? 1). La correction crée la révision \((record.revision ?? 1) + 1).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Corriger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        onSave(title, type, trim ? minutes : nil)
                        dismiss()
                    }
                }
            }
        }
    }
}
