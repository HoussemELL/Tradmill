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

/// Pastilles d'état : simulateur, tapis, Apple Watch.
struct ConnectionPills: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.treadmill.isSimulated {
                StatusPill(text: "SIMULATEUR", systemImage: "cpu", color: .purple)
            }
            if watchLinked {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Apple Watch reliée")
            }
            StatusPill(text: treadmillText, systemImage: "antenna.radiowaves.left.and.right", color: treadmillColor)
                .accessibilityLabel("État Bluetooth du tapis : \(model.treadmill.connection.label)")
        }
    }

    private var watchLinked: Bool {
        model.watch.linkState == .mirrored || model.watch.isReachable
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
        case .ready: return model.treadmill.beltState == .linkLost ? Theme.danger : Theme.accent
        case .connecting, .discovering, .reconnecting: return Theme.warning
        case .failed: return Theme.danger
        case .none: return .gray
        }
    }
}

// MARK: - Accueil : choisir un programme et démarrer

struct PrepareSessionView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ProgramEntity.sortIndex) private var programs: [ProgramEntity]
    @State private var selectedProgramID: UUID?
    @State private var freeRunSelected = false
    @State private var showDevicePicker = false
    @State private var showSteps = false
    @State private var error: String?

    private var selectedProgram: WorkoutProgram? {
        guard !freeRunSelected, let id = selectedProgramID ?? programs.first?.id else { return nil }
        return programs.first { $0.id == id }?.program
    }

    private var allIssues: [ProgramIssue] {
        guard let p = selectedProgram else { return [] }
        return ProgramValidator.validate(p, against: model.treadmill.capabilities)
    }

    /// Erreurs bloquantes (les avertissements n'empêchent pas le départ).
    private var issues: [ProgramIssue] { allIssues.filter { $0.severity == .error } }
    private var warnings: [ProgramIssue] { allIssues.filter { $0.severity == .warning } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DevicesCard(showDevicePicker: $showDevicePicker)
                SectionTitle(text: "Programmes", trailing: "\(programs.count)")
                VStack(spacing: 8) {
                    ForEach(programs) { e in
                        if let p = e.program {
                            ProgramChoiceRow(program: p, selected: !freeRunSelected && (selectedProgramID ?? programs.first?.id) == p.id) {
                                freeRunSelected = false
                                selectedProgramID = p.id
                            }
                        }
                    }
                    FreeRunChoiceRow(selected: freeRunSelected, startSpeed: model.settings.session.freeRunStartSpeed) {
                        freeRunSelected = true
                    }
                }
                if let p = selectedProgram { selectedDetail(p) }
                ForEach(warnings) { w in
                    Banner(text: "\(w.phaseName.map { "\($0) : " } ?? "")\(w.message)", color: Theme.warning)
                }
                if !issues.isEmpty { issuesCard }
                Label("Le bouton Arrêter de l'app ne remplace pas la clé de sécurité : gardez-la attachée.", systemImage: "key.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .screenBackground()
        .safeAreaInset(edge: .bottom) { startBar }
        .sheet(isPresented: $showDevicePicker) { DevicePickerView(role: .treadmill) }
    }

    private func selectedDetail(_ p: WorkoutProgram) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(p.name).font(.headline)
                Spacer()
                Text(Format.duration(TimeInterval(p.totalDurationSeconds))).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgramChart(program: p).frame(height: 110)
            if p.isLocked {
                Label("Test de référence : gardez-le identique. Modifier la vitesse ou passer une phase rend la séance non comparable.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            if p.hasAutoSpeed {
                Label(autoText(p), systemImage: "heart.circle").font(.caption).foregroundStyle(Theme.accent)
            }
            if !p.notes.isEmpty {
                Text(p.notes).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $showSteps) {
                ProgramSegmentsView(program: p).padding(.top, 6)
            } label: {
                Text("Étapes (\(p.schedule.count))").font(.subheadline.weight(.semibold))
            }
        }
        .card()
    }

    private var issuesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Programme incompatible avec ce tapis", systemImage: "xmark.octagon.fill")
                .font(.headline).foregroundStyle(Theme.danger)
            ForEach(issues) { i in
                Text("• \(i.phaseName.map { "\($0) : " } ?? "")\(i.message)").font(.subheadline)
            }
            Text("Corrigez le programme : aucune valeur n'est modifiée automatiquement.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func autoText(_ p: WorkoutProgram) -> String {
        let hr: String
        switch model.heartRate.status {
        case .live: hr = "FC disponible"
        default: hr = "aucune FC en direct pour l'instant : connectez la ceinture ou lancez l'exercice sur la Watch"
        }
        let z = p.schedule.first { $0.phase.isAuto }?.phase.autoSpeed?.targetZone ?? 2
        let range = model.settings.session.zones.zones.first { $0.zone == z }
        let bounds = range.map { " (\($0.lower)–\($0.upper) bpm)" } ?? ""
        return "Vitesse pilotée par la FC pour rester en zone \(z)\(bounds). \(hr)."
    }

    private var startDisabledReason: String? {
        if model.isDiagnosticRunning { return "Diagnostic en cours" }
        if model.hasActiveSession { return "Une séance est déjà en cours" }
        if !model.treadmill.connection.isReady { return "Connectez le tapis pour démarrer" }
        if !issues.isEmpty { return "Programme incompatible avec ce tapis" }
        return nil
    }

    private var startBar: some View {
        VStack(spacing: 6) {
            if let e = error { Banner(text: e, color: Theme.danger) }
            if let r = startDisabledReason {
                Text(r).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                error = nil
                model.prepareSession(program: selectedProgram)
                if let e = model.startSession() {
                    error = e
                    model.discardPreparedSession()
                }
            } label: {
                Label(selectedProgram.map { "Démarrer · \($0.name)" } ?? "Démarrer · Séance libre", systemImage: "play.fill")
                    .font(.title3.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(startDisabledReason != nil)
            .accessibilityHint("Démarre le tapis à basse vitesse puis applique la première phase")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Tapis, cardio et montre : ce qui conditionne le départ.
struct DevicesCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var showDevicePicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Très grands textes : bouton sous le nom plutôt qu'à côté (pas de mot coupé).
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(spacing: 12) {
                    Image(systemName: "figure.walk.treadmill")
                        .font(.title2)
                        .foregroundStyle(model.treadmill.connection.isReady ? Theme.accent : .secondary)
                        .frame(width: 34)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.treadmill.connection.label).font(.headline).lineLimit(2)
                        Text(capabilitiesText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button(model.treadmill.connection == .none ? "Connecter" : "Changer") { showDevicePicker = true }
                    .buttonStyle(.bordered)
                    .fixedSize()
            }
            Divider()
            HeartRateLine()
            HStack(spacing: 12) {
                Image(systemName: "applewatch").foregroundStyle(watchColor).frame(width: 34)
                Text(watchText).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if model.treadmill.isSimulated {
                Label("Mode simulateur : aucune commande n'est envoyée à un vrai tapis.", systemImage: "cpu")
                    .font(.caption).foregroundStyle(.purple)
            }
        }
        .card()
    }

    private var capabilitiesText: String {
        guard model.treadmill.connection.isReady else { return "Profil : \(model.treadmill.profile.name)" }
        let c = model.treadmill.capabilities
        return String(format: "%.1f–%.1f km/h", c.speed.minKmh, c.speed.maxKmh)
            + (c.inclination.map { String(format: " · %.0f–%.0f %%", $0.minPercent, $0.maxPercent) } ?? " · inclinaison non pilotable")
    }

    private var watchText: String {
        if model.watch.linkState == .mirrored { return "Apple Watch : exercice en miroir" }
        if model.watch.isReachable { return "Apple Watch : app ouverte, programmes synchronisés" }
        if model.watch.isAppInstalled { return "Apple Watch : programmes synchronisés à l'ouverture de l'app" }
        return "Apple Watch : \(model.watch.installationStatus)"
    }

    private var watchColor: Color {
        model.watch.isReachable || model.watch.linkState == .mirrored ? Theme.accent : .secondary
    }
}

/// Ligne de programme sélectionnable.
struct ProgramChoiceRow: View {
    let program: WorkoutProgram
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PhaseStrip(program: program)
                    .frame(width: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(program.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        if program.isLocked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(Theme.warning) }
                        if program.hasAutoSpeed { Image(systemName: "heart.circle.fill").font(.caption).foregroundStyle(Theme.accent) }
                    }
                    Text("\(Format.duration(TimeInterval(program.totalDurationSeconds))) · max \(Format.speed(program.maxSpeedKmh)) km/h")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.accent : Color(uiColor: .tertiaryLabel))
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct FreeRunChoiceRow: View {
    let selected: Bool
    let startSpeed: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "speedometer").font(.title3).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Séance libre").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(String(format: "Départ à %.1f km/h, réglages manuels", startSpeed)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.accent : Color(uiColor: .tertiaryLabel))
            }
            .padding(12)
            .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Bande verticale des phases, couleur par type, hauteur proportionnelle à la durée.
struct PhaseStrip: View {
    let program: WorkoutProgram

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 1) {
                ForEach(program.schedule) { sp in
                    Rectangle().fill(Theme.phaseColor(sp.phase.kind))
                        .frame(height: max(1, geo.size.height * Double(sp.phase.durationSeconds) / Double(max(program.totalDurationSeconds, 1)) - 1))
                }
            }
        }
        .frame(minHeight: 38)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Ligne d'état cardio : source, valeur, ancienneté.
struct HeartRateLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill").foregroundStyle(Theme.heart).frame(width: 34).accessibilityHidden(true)
            switch model.heartRate.status {
            case let .live(bpm, source, age):
                Text("\(bpm) bpm · \(source.shortLabel) · il y a \(Int(age)) s")
            case let .stale(bpm, source, age):
                Text("\(source.shortLabel) : dernière mesure \(bpm) bpm il y a \(Int(age)) s (périmée)").foregroundStyle(.secondary)
            case .unavailable:
                Text("Pas de FC : connectez une ceinture ou ouvrez Foulée sur l'Apple Watch").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
