import SwiftUI
import SwiftData
import TreadCore

/// Onglet Séance : préparation, séance en cours (gros indicateurs) et résumé.
struct SessionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let service = model.sessionService, service.snapshot.status != .ready {
                    if service.snapshot.status == .finished {
                        FinishedSessionView(service: service)
                    } else {
                        LiveSessionView(service: service)
                    }
                } else {
                    PrepareSessionView()
                }
            }
            .navigationTitle("Séance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ConnectionPills() }
            }
        }
    }
}

/// Pastilles d'état : tapis, simulateur, source cardio.
struct ConnectionPills: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.treadmill.isSimulated {
                StatusPill(text: "SIMULATEUR", systemImage: "cpu", color: .purple)
            }
            StatusPill(text: treadmillText, systemImage: "antenna.radiowaves.left.and.right", color: treadmillColor)
                .accessibilityLabel("État Bluetooth du tapis : \(model.treadmill.connection.label)")
        }
    }

    private var treadmillText: String {
        switch model.treadmill.connection {
        case .ready: return model.treadmill.beltState == .linkLost ? "Perdu" : "Tapis"
        case .connecting, .discovering: return "…"
        case .reconnecting: return "Reconnexion"
        case .failed: return "Erreur"
        case .none: return "Aucun"
        }
    }

    private var treadmillColor: Color {
        switch model.treadmill.connection {
        case .ready: return Theme.accent
        case .connecting, .discovering, .reconnecting: return Theme.warning
        case .failed: return Theme.danger
        case .none: return .gray
        }
    }
}

// MARK: - Préparation

struct PrepareSessionView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ProgramEntity.sortIndex) private var programs: [ProgramEntity]
    @State private var selectedProgramID: UUID?
    @State private var showDevicePicker = false
    @State private var error: String?

    private var selectedProgram: WorkoutProgram? {
        guard let id = selectedProgramID else { return nil }
        return programs.first { $0.id == id }?.program
    }

    private var issues: [ProgramIssue] {
        guard let p = selectedProgram else { return [] }
        return ProgramValidator.validate(p, against: model.treadmill.capabilities)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                treadmillCard
                programCard
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Programme incompatible avec ce tapis", systemImage: "xmark.octagon.fill")
                            .font(.headline).foregroundStyle(Theme.danger)
                        ForEach(issues) { i in
                            Text("• \(i.phaseName.map { "\($0) : " } ?? "")\(i.message)").font(.subheadline)
                        }
                        Text("Corrigez le programme : aucune valeur n'est modifiée automatiquement.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                }
                if let error { Banner(text: error, color: Theme.danger) }
                startButton
                Label("Le bouton Arrêter de l'app ne remplace pas la clé de sécurité : gardez-la attachée.",
                      systemImage: "key.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .sheet(isPresented: $showDevicePicker) { DevicePickerView(role: .treadmill) }
    }

    private var treadmillCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "figure.walk").font(.title2)
                VStack(alignment: .leading) {
                    Text(model.treadmill.connection.label).font(.headline)
                    Text("Profil : \(model.treadmill.profile.name)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.treadmill.connection == .none ? "Connecter" : "Changer") { showDevicePicker = true }
                    .buttonStyle(.bordered)
            }
            if model.treadmill.isSimulated {
                Banner(text: "Mode simulateur : aucune commande n'est envoyée à un vrai tapis.", color: .purple, systemImage: "cpu")
            }
            if model.treadmill.connection.isReady {
                let c = model.treadmill.capabilities
                Text(String(format: "Vitesse %.1f–%.1f km/h · pas %.1f", c.speed.minKmh, c.speed.maxKmh, c.speed.incrementKmh)
                     + (c.inclination.map { String(format: " · Inclinaison %.0f–%.0f %%", $0.minPercent, $0.maxPercent) } ?? " · Inclinaison non pilotable"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HeartRateLine()
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var programCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Programme").font(.headline)
            Picker("Programme", selection: $selectedProgramID) {
                Text("Séance libre").tag(UUID?.none)
                ForEach(programs) { p in
                    Text("\(p.name) · \(Format.duration(TimeInterval(p.totalSeconds)))").tag(Optional(p.id))
                }
            }
            .pickerStyle(.menu)
            if let p = selectedProgram {
                ProgramChart(program: p).frame(height: 120)
                Text("\(p.schedule.count) phases · \(Format.duration(TimeInterval(p.totalDurationSeconds)))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(String(format: "Départ à %.1f km/h, réglages manuels pendant la séance.", model.settings.session.freeRunStartSpeed))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var startButton: some View {
        Button {
            error = nil
            model.prepareSession(program: selectedProgram)
            if let e = model.startSession() {
                error = e
                model.discardPreparedSession()
            }
        } label: {
            Label("Démarrer le tapis", systemImage: "play.fill")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.treadmill.connection.isReady || !issues.isEmpty || model.hasActiveSession || model.isDiagnosticRunning)
        .accessibilityHint("Démarre le tapis à basse vitesse puis applique la première phase")
    }
}

/// Ligne d'état cardio : source, valeur, ancienneté.
struct HeartRateLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill").foregroundStyle(Theme.heart)
            switch model.heartRate.status {
            case let .live(bpm, source, age):
                Text("\(bpm) bpm · \(source.shortLabel) · il y a \(Int(age)) s")
            case let .stale(bpm, source, age):
                Text("\(source.shortLabel) : dernière mesure \(bpm) bpm il y a \(Int(age)) s (périmée)").foregroundStyle(.secondary)
            case .unavailable:
                Text("Aucune fréquence cardiaque (\(model.settings.heartRatePreference.label))").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
