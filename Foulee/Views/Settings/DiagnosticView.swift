import SwiftUI
import Combine
import UniformTypeIdentifiers
import TreadCore

/// Diagnostic : état détaillé du lien FTMS, journal exportable et tests actifs explicites.
struct DiagnosticView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [DiagnosticLog.Entry] = []
    @State private var filter: DiagnosticLog.Category?
    @State private var exportDoc: ExportDocument?
    @State private var pendingTest: AppModel.DiagnosticKind?
    @State private var requestControlEachStep = false
    @State private var testError: String?
    @State private var listenUnknown = false
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var tm: TreadmillService { model.treadmill }

    var body: some View {
        @Bindable var model = model
        List {
            Section("Lien FTMS") {
                LabeledContent("Connexion", value: tm.connection.label)
                LabeledContent("Profil", value: tm.profile.name)
                LabeledContent("État tapis", value: tm.beltState.label)
                LabeledContent("Contrôle obtenu", value: tm.hasControl ? "oui" : "non")
                LabeledContent("Paquets reçus", value: "\(tm.telemetry.packetCount) (\(tm.telemetry.malformedCount) anormaux)")
                if let m = tm.lastMessage { Text(m).font(.caption).foregroundStyle(Theme.warning) }
            }
            Section {
                targetRows("Vitesse", tm.speed, observed: tm.telemetry.speedKmh, unit: "km/h")
                targetRows("Inclinaison", tm.incline, observed: tm.telemetry.inclinePercent, unit: "%")
            } header: { Text("Consigne → acquittement → mesure") } footer: {
                Text("« Demandée » = envoyée ou en file ; « acquittée » = réponse succès du Control Point ; « annoncée » = statut du tapis ; « mesurée » = télémétrie. Seule la mesure est affichée comme valeur réelle.")
            }
            Section {
                Button("Explorer les services GATT") { tm.exploreGATT(listenToUnknown: listenUnknown) }
                    .disabled(!tm.canExploreGATT)
                Toggle("Écouter aussi les caractéristiques hors FTMS", isOn: $listenUnknown)
                Toggle("Journaliser chaque paquet de télémétrie", isOn: $model.settings.logRawTelemetry)
            } header: { Text("Diagnostic passif") } footer: {
                Text("Liste et lit les caractéristiques sans rien commander. Utile pour repérer un compteur de pas propriétaire.")
            }
            Section {
                if let d = model.diagnostic {
                    diagnosticResults(d)
                }
                if let testError { Text(testError).foregroundStyle(Theme.danger) }
                Button {
                    pendingTest = .startSequence
                } label: {
                    Label("Test de démarrage (hors du tapis)", systemImage: "play.circle")
                }
                .disabled(!canRunActiveTest)
                Button {
                    pendingTest = .speedResponse(requestControlEachStep: requestControlEachStep)
                } label: {
                    Label("Test de réponse en vitesse (hors du tapis)", systemImage: "speedometer")
                }
                .disabled(!canRunActiveTest)
                Toggle("Request Control avant chaque consigne", isOn: $requestControlEachStep)
                    .font(.subheadline)
                if model.isDiagnosticRunning {
                    Button("Arrêter le test", role: .destructive) { model.abortDiagnostic() }
                }
            } header: { Text("Diagnostic actif") } footer: {
                Text("Démarrage : séquence du profil, +1 km/h, observation 8 s, arrêt. Réponse en vitesse : départ à la vitesse initiale puis trois consignes en marche (+1, +2, +0,5 km/h), avec pour chacune résultat, consigne annoncée par le tapis, mesure et délai — pour départager les hypothèses sur les consignes ignorées. Personne sur le tapis, clé de sécurité en place.")
            }
            Section {
                Picker("Filtre", selection: $filter) {
                    Text("Tout").tag(DiagnosticLog.Category?.none)
                    ForEach(DiagnosticLog.Category.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                ForEach(filtered.suffix(300).reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.date.formatted(date: .omitted, time: .standard)) [\(e.category.rawValue)] \(e.message)")
                            .font(.caption.monospaced())
                        if let hex = e.hex { Text(hex).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    }
                }
            } header: {
                Text("Journal (\(entries.count) entrées)")
            }
        }
        .navigationTitle("Diagnostic")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Exporter le journal (texte)") {
                        let text = model.log.exportText(header: model.diagnosticHeader())
                        exportDoc = ExportDocument(data: Data(text.utf8), contentType: .plainText, filename: "foulee_diagnostic.txt")
                    }
                    Button("Exporter le journal (JSON)") {
                        if let d = try? model.log.exportJSON() {
                            exportDoc = ExportDocument(data: d, contentType: .json, filename: "foulee_diagnostic.json")
                        }
                    }
                    Button("Effacer le journal", role: .destructive) { model.log.clear(); reload() }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .confirmationDialog("Test actif du tapis", isPresented: Binding(get: { pendingTest != nil },
                                                                         set: { if !$0 { pendingTest = nil } }),
                            titleVisibility: .visible) {
            Button("Personne sur le tapis — lancer") {
                if let k = pendingTest { testError = model.startDiagnostic(k) }
                pendingTest = nil
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le tapis va démarrer à basse vitesse. Vérifiez que personne n'est dessus et que la clé de sécurité est en place.")
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: exportDoc?.contentType ?? .plainText,
                      defaultFilename: exportDoc?.filename) { _ in }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    private var filtered: [DiagnosticLog.Entry] {
        guard let filter else { return entries }
        return entries.filter { $0.category == filter }
    }

    private func reload() { entries = model.log.entries }

    private var canRunActiveTest: Bool {
        tm.connection.isReady && !model.hasActiveSession && !model.isDiagnosticRunning
    }

    @ViewBuilder
    private func diagnosticResults(_ d: ActiveDiagnostic) -> some View {
        let _ = model.diagnosticRevision
        Text(d.title).font(.headline)
        switch d.state {
        case let .running(step): Label(step, systemImage: "hourglass")
        case let .finished(ok):
            Label(ok ? "Test réussi" : "Test en échec", systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok ? Theme.accent : Theme.danger)
        case .idle: EmptyView()
        }
        ForEach(d.steps) { s in
            Label("\(s.title) : \(s.detail)", systemImage: s.ok ? "checkmark" : "xmark")
                .font(.caption)
                .foregroundStyle(s.ok ? Color.primary : Theme.danger)
        }
    }

    @ViewBuilder
    private func targetRows(_ title: String, _ t: TargetTracking, observed: Double?, unit: String) -> some View {
        let f: (Double?) -> String = { $0.map { String(format: "%.2f %@", $0, unit) } ?? "—" }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text("Demandée : \(f(t.requested)) · \(statusLabel(t.status))").font(.caption)
            Text("Acquittée : \(f(t.acknowledged)) · sans réponse : \(f(t.unanswered)) · annoncée : \(f(t.machineReported))").font(.caption)
            Text("Mesurée : \(f(observed))").font(.caption.bold())
        }
    }

    private func statusLabel(_ s: TargetTracking.Status) -> String {
        switch s {
        case .none: return "—"
        case .pending: return "envoyée"
        case .acknowledged: return "acquittée, en attente de mesure"
        case .unanswered: return "envoyée SANS RÉPONSE, vérification par la mesure"
        case .reached: return "atteinte"
        case .mismatch: return "ÉCART"
        case let .failed(m): return "échec (\(m))"
        case .deferred: return "en attente du démarrage"
        }
    }
}
