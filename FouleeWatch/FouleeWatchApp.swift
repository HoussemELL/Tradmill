import SwiftUI
import HealthKit
import WatchKit
import TreadCore

@main
struct FouleeWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(WorkoutManager.shared)
                .onAppear { WatchScenario.start(WorkoutManager.shared) }
        }
    }
}

/// Reçoit la configuration d'exercice envoyée par l'iPhone (`startWatchApp(with:)`) quand une
/// séance est lancée sur l'iPhone.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        let activity = workoutConfiguration.activityType
        Task { @MainActor in
            await WorkoutManager.shared.start(activity: activity)
        }
    }
}

struct WatchRootView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        switch manager.phase {
        case .ended:
            EndedView()
        case .starting, .running, .paused, .ending:
            LiveView()
        case .idle, .failed:
            HomeView()
        }
    }
}

// MARK: - Style commun (mêmes couleurs que l'iPhone)

enum WatchStyle {
    static let accent = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let speed = Color(red: 0.22, green: 0.74, blue: 0.97)
    static let incline = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let heart = Color(red: 0.96, green: 0.30, blue: 0.40)

    static func zoneColor(_ zone: Int?) -> Color {
        switch zone {
        case 1: return Color(red: 0.55, green: 0.62, blue: 0.70)
        case 2: return Color(red: 0.22, green: 0.62, blue: 0.95)
        case 3: return Color(red: 0.20, green: 0.80, blue: 0.45)
        case 4: return Color(red: 0.98, green: 0.62, blue: 0.10)
        case 5: return Color(red: 0.94, green: 0.25, blue: 0.30)
        default: return Color(white: 0.45)
        }
    }

    static func phaseColor(_ kind: PhaseKind) -> Color {
        switch kind {
        case .warmup: return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .work: return Color(red: 0.94, green: 0.33, blue: 0.31)
        case .recovery: return Color(red: 0.22, green: 0.62, blue: 0.95)
        case .cooldown: return Color(red: 0.55, green: 0.50, blue: 0.95)
        case .steady: return accent
        }
    }

    static func zoneName(_ zone: Int?) -> String {
        switch zone {
        case 0: return "Sous Z1"
        case let z?: return "Zone \(z)"
        default: return "—"
        }
    }

    static func duration(_ t: Double?) -> String {
        guard let t, t.isFinite else { return "—" }
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func minutes(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func speed(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
    static func incline(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
}

// MARK: - Accueil : Mes programmes

struct HomeView: View {
    @Environment(WorkoutManager.self) private var manager
    @State private var path: [WatchProgramSummary] = []
    @State private var confirmFree = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { PhoneStatusRow() }
                launchSection
                if let follow = manager.phoneSessionToFollow {
                    Section {
                        Button {
                            manager.followPhoneSession()
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text("Séance en cours").font(.headline)
                                    Text("\(follow.name) · suivre ici").font(.caption2).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "figure.walk.motion").foregroundStyle(WatchStyle.accent)
                            }
                        }
                    }
                }
                Section {
                    if manager.programs.isEmpty {
                        Text(manager.context == nil
                             ? "Ouvrez Foulée sur l'iPhone pour recevoir vos programmes."
                             : "Aucun programme sur l'iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(manager.programs) { p in
                        NavigationLink(value: p) { ProgramRow(program: p) }
                    }
                } header: {
                    Text("Mes programmes")
                }
                Section {
                    Button { confirmFree = true } label: {
                        Label("Séance libre sur le tapis", systemImage: "speedometer")
                    }
                    .disabled(!canStart)
                    NavigationLink {
                        FreeWorkoutView()
                    } label: {
                        Label("Exercice sans tapis", systemImage: "heart.text.square")
                    }
                } header: {
                    Text("Autres")
                }
            }
            .navigationTitle("Foulée")
            .navigationDestination(for: WatchProgramSummary.self) { p in
                ProgramDetailView(program: p) { path.removeAll() }
            }
            .confirmationDialog("Démarrer le tapis ?", isPresented: $confirmFree, titleVisibility: .visible) {
                Button("Démarrer") { manager.startProgram(nil) }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Séance libre à la vitesse de départ réglée sur l'iPhone.")
            }
            .onAppear {
                manager.requestContext()
                if let name = WatchScenario.value("-FouleeOpen"), let p = manager.programs.first(where: { $0.name == name }), path.isEmpty {
                    path = [p]
                }
            }
        }
    }

    private var canStart: Bool {
        (manager.context?.treadmill.ready ?? false) && manager.phoneReachable && manager.context?.activeSessionID == nil
    }

    @ViewBuilder private var launchSection: some View {
        switch manager.launch {
        case let .requesting(name):
            Section {
                HStack(spacing: 8) {
                    ProgressView().frame(width: 24)
                    VStack(alignment: .leading) {
                        Text("Démarrage…").font(.headline)
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        case let .refused(why):
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Non démarré", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(why).font(.caption2)
                    Button("OK") { manager.dismissLaunchMessage() }
                }
            }
        case .none:
            EmptyView()
        }
    }
}

/// iPhone joignable et état du tapis.
struct PhoneStatusRow: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        let t = manager.context?.treadmill
        let ready = (t?.ready ?? false) && manager.phoneReachable
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? WatchStyle.accent : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(t)).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(detail(t)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func title(_ t: WatchTreadmillBrief?) -> String {
        guard manager.phoneReachable else { return "iPhone injoignable" }
        guard let t else { return "iPhone relié" }
        return t.ready ? (t.name ?? "Tapis") + " prêt" : "Tapis non connecté"
    }

    private func detail(_ t: WatchTreadmillBrief?) -> String {
        guard manager.phoneReachable else { return "Ouvrez Foulée sur l'iPhone, à proximité." }
        guard let t else { return "En attente des programmes…" }
        if t.ready { return t.simulated ? "Simulateur (aucun vrai tapis)" : "Prêt à démarrer depuis la montre" }
        return "Connectez le tapis dans Foulée sur l'iPhone."
    }
}

struct ProgramRow: View {
    let program: WatchProgramSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(program.name).font(.headline).lineLimit(2)
                if program.isAuto { Image(systemName: "heart.circle.fill").foregroundStyle(WatchStyle.accent).font(.caption) }
                if program.isLocked { Image(systemName: "lock.fill").foregroundStyle(.orange).font(.caption2) }
            }
            Text("\(WatchStyle.minutes(program.totalSeconds)) · max \(WatchStyle.speed(program.maxSpeedKmh)) km/h")
                .font(.caption2).foregroundStyle(.secondary)
            StepStrip(program: program).frame(height: 5)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(program.name), \(program.totalSeconds / 60) minutes\(program.isAuto ? ", vitesse pilotée par la fréquence cardiaque" : "")")
    }
}

/// Bande colorée des étapes, proportionnelle à leur durée.
struct StepStrip: View {
    let program: WatchProgramSummary

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(flat.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(WatchStyle.phaseColor(s.kind))
                        .frame(width: max(1, geo.size.width * Double(s.seconds) / Double(max(program.totalSeconds, 1)) - 1))
                }
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var flat: [WatchProgramStep] {
        program.groups.flatMap { g in (0..<max(g.repeatCount, 1)).flatMap { _ in g.steps } }
    }
}

// MARK: - Détail d'un programme

struct ProgramDetailView: View {
    @Environment(WorkoutManager.self) private var manager
    let program: WatchProgramSummary
    let onStart: () -> Void
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(program.name).font(.title3.bold())
                HStack(spacing: 10) {
                    stat(WatchStyle.minutes(program.totalSeconds), "durée")
                    stat(WatchStyle.speed(program.maxSpeedKmh), "km/h max")
                    stat("\(WatchStyle.incline(program.maxInclinePercent)) %", "incl. max")
                }
                StepStrip(program: program).frame(height: 6)
                startButton
                if program.isAuto {
                    Label("Vitesse réglée par votre FC pour rester en zone 2.", systemImage: "heart.circle")
                        .font(.caption2).foregroundStyle(WatchStyle.accent)
                }
                Text("Étapes").font(.headline).padding(.top, 4)
                ForEach(Array(program.groups.enumerated()), id: \.offset) { _, g in
                    if g.isBlock {
                        Text("Répéter \(g.repeatCount) ×").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                    ForEach(Array(g.steps.enumerated()), id: \.offset) { _, s in
                        StepRow(step: s).padding(.leading, g.isBlock ? 8 : 0)
                    }
                }
                if !program.notes.isEmpty {
                    Text(program.notes).font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
        .navigationTitle("Programme")
        .confirmationDialog("Démarrer le tapis ?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Démarrer") {
                manager.startProgram(program)
                onStart()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le tapis démarre lentement puis suit « \(program.name) ». Gardez la clé de sécurité attachée.")
        }
    }

    private var ready: Bool {
        (manager.context?.treadmill.ready ?? false) && manager.phoneReachable && manager.context?.activeSessionID == nil
    }

    @ViewBuilder private var startButton: some View {
        Button { confirm = true } label: {
            Label("Démarrer", systemImage: "play.fill").frame(maxWidth: .infinity)
        }
        .tint(WatchStyle.accent)
        .disabled(!ready)
        if !ready {
            Text(notReadyReason).font(.caption2).foregroundStyle(.orange)
        }
    }

    private var notReadyReason: String {
        if !manager.phoneReachable { return "iPhone injoignable." }
        if manager.context?.activeSessionID != nil { return "Une séance est déjà en cours." }
        return "Tapis non connecté à l'iPhone."
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.system(.body, design: .rounded).bold()).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StepRow: View {
    let step: WatchProgramStep

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(WatchStyle.phaseColor(step.kind)).frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(step.name).font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(WatchStyle.minutes(step.seconds)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                Text("\(step.speedText) · \(WatchStyle.incline(step.inclinePercent)) %")
                    .font(.caption2).foregroundStyle(step.autoRange != nil ? WatchStyle.accent : .secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Exercice sans tapis (FC seulement) : option secondaire.
struct FreeWorkoutView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        List {
            Section {
                Button { Task { await manager.start(activity: .walking) } } label: { Label("Marche", systemImage: "figure.walk") }
                Button { Task { await manager.start(activity: .running) } } label: { Label("Course", systemImage: "figure.run") }
            } footer: {
                Text("Mesure la FC sans piloter le tapis. Pour suivre un programme, choisissez-le dans Mes programmes.")
            }
            if case let .failed(m) = manager.phase {
                Text(m).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("Sans tapis")
    }
}

// MARK: - Séance en cours

/// Pages horizontales, comme l'app Exercice : commandes à gauche, mesures au centre,
/// programme puis temps par zone à droite.
struct LiveView: View {
    @Environment(WorkoutManager.self) private var manager
    @State private var page = WatchScenario.intValue("-FouleePage") ?? 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TabView(selection: $page) {
                ControlsPage(now: context.date).tag(0)
                MetricsPage(now: context.date).tag(1)
                ProgramPage(now: context.date).tag(2)
                ZoneTimePage().tag(3)
            }
            .tabViewStyle(.page)
        }
    }
}

/// FC, zone, phase et tapis : l'essentiel d'un coup d'œil.
struct MetricsPage: View {
    @Environment(WorkoutManager.self) private var manager
    let now: Date

    private var bpm: Int? {
        guard let hr = manager.heartRate, let d = manager.heartRateDate, now.timeIntervalSince(d) < 15 else { return nil }
        return Int(hr.rounded())
    }

    var body: some View {
        let linked = manager.isPhoneLinked(now: now)
        let l = linked ? manager.live : nil
        let zone = bpm.flatMap { WatchLiveStatus.zone(for: $0, bounds: manager.zoneBounds) }
        let color = WatchStyle.zoneColor(zone)
        VStack(alignment: .leading, spacing: 3) {
            if let l {
                statusLine(l)
            } else {
                Text(manager.phase == .paused ? "En pause" : "iPhone non relié").font(.caption2).foregroundStyle(.orange)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(bpm.map(String.init) ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(bpm == nil ? Color.secondary : Color.primary)
                Image(systemName: "heart.fill").font(.footnote).foregroundStyle(WatchStyle.heart)
                Spacer(minLength: 0)
                ZoneBadge(zone: zone, bounds: manager.zoneBounds)
            }
            if let z = zone, let b = bpm {
                ProgressView(value: WatchLiveStatus.progress(of: b, in: z, bounds: manager.zoneBounds) ?? 0)
                    .tint(color)
                    .accessibilityLabel("Position dans la zone \(z)")
            }
            if let l {
                HStack {
                    metric(WatchStyle.speed(l.speedKmh), "km/h", WatchStyle.speed)
                    Spacer()
                    metric(WatchStyle.incline(l.inclinePercent ?? l.targetInclinePercent), "%", WatchStyle.incline)
                    Spacer()
                    metric(WatchStyle.duration(l.activeSeconds), "", .primary)
                }
            } else {
                Text(WatchStyle.duration(manager.startDate.map { now.timeIntervalSince($0) })).font(.title3.monospacedDigit())
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private func statusLine(_ l: WatchLiveStatus) -> some View {
        if l.treadmillLinkLost == true {
            Text("Tapis déconnecté").font(.caption2.bold()).foregroundStyle(.red)
        } else if let a = l.alert, a.hasPrefix("Reprise impossible") {
            Text("Reprise impossible").font(.caption2.bold()).foregroundStyle(.orange)
        } else if l.state == .paused {
            Text(l.stateLabel).font(.caption2.bold()).foregroundStyle(.orange).lineLimit(1)
        } else if let name = l.phaseName {
            HStack {
                Text(name).font(.caption2.bold()).lineLimit(1)
                Spacer(minLength: 2)
                Text(WatchStyle.duration(l.phaseRemaining)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text(l.stateLabel).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func metric(_ v: String, _ unit: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(v).font(.system(.title3, design: .rounded).bold()).monospacedDigit().foregroundStyle(color)
            if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ZoneBadge: View {
    let zone: Int?
    let bounds: [Int]

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(zone.map { "Z\($0)" } ?? "—").font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(WatchStyle.zoneColor(zone))
            if let z = zone, let r = WatchLiveStatus.range(of: z, bounds: bounds) {
                Text(r.lower == 0 ? "<\(r.upper)" : "\(r.lower)–\(r.upper)").font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(zone.map { "Zone \($0)" } ?? "Zone inconnue")
    }
}

/// Étape en cours, temps restant, étape suivante, pilotage FC.
struct ProgramPage: View {
    @Environment(WorkoutManager.self) private var manager
    let now: Date

    var body: some View {
        ScrollView {
            if let l = manager.live, manager.isPhoneLinked(now: now) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l.programName ?? "Séance libre").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let name = l.phaseName {
                        Text(name).font(.headline).lineLimit(2)
                        HStack {
                            Text("reste \(WatchStyle.duration(l.phaseRemaining))").monospacedDigit()
                            Spacer()
                            if let i = l.phaseIndex { Text("\(i + 1)/\(l.phaseCount)").foregroundStyle(.secondary) }
                        }
                        .font(.footnote)
                        if let rem = l.programRemaining {
                            ProgressView(value: l.activeSeconds, total: max(l.activeSeconds + rem, 1)).tint(WatchStyle.accent)
                            Text("Programme : reste \(WatchStyle.duration(rem))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(String(format: "Consigne %.1f km/h · %.0f %%", l.targetSpeedKmh, l.targetInclinePercent))
                        .font(.caption2)
                    if let next = l.nextPhaseName {
                        Label(next, systemImage: "arrow.right.circle").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let a = l.autopilotStatus {
                        Label(a, systemImage: "heart.circle").font(.caption2).foregroundStyle(WatchStyle.accent)
                    }
                    if let alert = l.alert {
                        Text(alert).font(.caption2).foregroundStyle(.orange)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "iphone.slash").font(.title2).foregroundStyle(.secondary)
                    Text("iPhone non relié").font(.headline)
                    Text("Le programme s'affiche quand Foulée tourne sur l'iPhone à proximité.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }
}

/// Temps passé dans chaque zone.
struct ZoneTimePage: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        let secs = manager.zoneSeconds
        let total = max(secs.reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 3) {
            Text("Temps par zone").font(.headline)
            ForEach((1...5).reversed(), id: \.self) { z in
                HStack(spacing: 4) {
                    Text("Z\(z)").font(.caption2.bold()).frame(width: 22, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(WatchStyle.zoneColor(z))
                            .frame(width: max(2, geo.size.width * (z < secs.count ? secs[z] : 0) / total))
                    }
                    .frame(height: 10)
                    Text(WatchStyle.duration(z < secs.count ? secs[z] : 0)).font(.caption2.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Zone \(z) : \(Int((z < secs.count ? secs[z] : 0) / 60)) minutes")
            }
        }
    }
}

/// Arrêter, Pause/Reprendre, Pilotage FC.
struct ControlsPage: View {
    @Environment(WorkoutManager.self) private var manager
    let now: Date

    private var paused: Bool {
        if manager.isPhoneLinked(now: now), let l = manager.live { return l.state == .paused }
        return manager.phase == .paused
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button(role: .destructive) {
                    manager.requestStop()
                } label: {
                    Label(manager.stopRequestedAt == nil ? "Arrêter" : "Arrêt en cours…", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .accessibilityHint("Arrête le tapis et termine la séance")
                if paused {
                    Button { manager.requestResume() } label: {
                        Label("Reprendre", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .tint(WatchStyle.accent)
                } else {
                    Button { manager.requestPause() } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.orange)
                }
                if manager.live?.autopilotManual == true, manager.isPhoneLinked(now: now) {
                    Button { manager.requestAutopilot() } label: {
                        Label("Pilotage FC", systemImage: "heart.circle").frame(maxWidth: .infinity)
                    }
                }
                Label(manager.isPhoneLinked(now: now) ? "Tapis piloté par l'iPhone" : "iPhone non relié : exercice seulement",
                      systemImage: manager.isPhoneLinked(now: now) ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    .font(.caption2).foregroundStyle(.secondary)
                if let w = manager.warning { Text(w).font(.caption2).foregroundStyle(.red) }
                if manager.isPhoneLinked(now: now), let a = manager.live?.alert {
                    Text(a).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct EndedView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(WatchStyle.accent)
                Text("Séance terminée").font(.headline)
                if let t = manager.linkedTitle { Text(t).font(.footnote).foregroundStyle(.secondary) }
                if case let .ended(saved) = manager.phase {
                    Text(saved ? "Enregistrée dans Santé" : (manager.simulated ? "Exercice simulé (non enregistré)" : "Non enregistrée dans Santé"))
                        .font(.caption2).multilineTextAlignment(.center)
                }
                if let w = manager.warning { Text(w).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center) }
                Button("OK") { manager.reset() }
            }
        }
    }
}
