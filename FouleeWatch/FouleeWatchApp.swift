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
        }
    }
}

/// Reçoit la configuration d'exercice envoyée par l'iPhone (`startWatchApp(with:)`).
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
        case .idle, .failed:
            StartView()
        case .ended:
            EndedView()
        default:
            LiveView()
        }
    }
}

struct StartView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "figure.walk.motion").font(.largeTitle).foregroundStyle(.green)
                Text("Cardio pour le tapis").font(.headline).multilineTextAlignment(.center)
                Button {
                    Task { await manager.start(activity: .walking) }
                } label: { Label("Marche", systemImage: "figure.walk") }
                Button {
                    Task { await manager.start(activity: .running) }
                } label: { Label("Course", systemImage: "figure.run") }
                if case let .failed(m) = manager.phase {
                    Text(m).font(.footnote).foregroundStyle(.red)
                }
                Text("Les mesures sont envoyées en direct à l'iPhone. L'exercice est enregistré dans Santé par la Watch.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

/// Séance en cours : pages verticales (cardio et zone, tapis et étape, temps par zone, commandes).
struct LiveView: View {
    @Environment(WorkoutManager.self) private var manager
    @State private var page = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TabView(selection: $page) {
                HeartPage(now: context.date).tag(0)
                TreadmillPage(now: context.date).tag(1)
                ZoneTimePage().tag(2)
                ControlsPage(now: context.date).tag(3)
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

enum WatchStyle {
    /// Mêmes couleurs que l'iPhone : zones 0 (sous Z1) à 5.
    static func zoneColor(_ zone: Int?) -> Color {
        switch zone {
        case 1: return Color(red: 0.55, green: 0.62, blue: 0.70)
        case 2: return Color(red: 0.22, green: 0.62, blue: 0.95)
        case 3: return Color(red: 0.20, green: 0.80, blue: 0.45)
        case 4: return Color(red: 0.98, green: 0.62, blue: 0.10)
        case 5: return Color(red: 0.94, green: 0.25, blue: 0.30)
        default: return Color(white: 0.35)
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

    static func speed(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
}

/// FC actuelle, zone colorée, bornes de la zone et position dans la zone.
struct HeartPage: View {
    @Environment(WorkoutManager.self) private var manager
    let now: Date

    private var bpm: Int? {
        guard let hr = manager.heartRate, let d = manager.heartRateDate, now.timeIntervalSince(d) < 15 else { return nil }
        return Int(hr.rounded())
    }

    var body: some View {
        let zone = bpm.flatMap { WatchLiveStatus.zone(for: $0, bounds: manager.zoneBounds) }
        let color = WatchStyle.zoneColor(zone)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text(bpm.map(String.init) ?? "—")
                    .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                Text("bpm").font(.footnote).foregroundStyle(.secondary)
            }
            Text(WatchStyle.zoneName(zone)).font(.title3.bold()).foregroundStyle(color)
            if let z = zone, let r = WatchLiveStatus.range(of: z, bounds: manager.zoneBounds), let b = bpm {
                Text(r.lower == 0 ? "< \(r.upper) bpm" : "\(r.lower)–\(r.upper) bpm").font(.footnote).monospacedDigit()
                ProgressView(value: WatchLiveStatus.progress(of: b, in: z, bounds: manager.zoneBounds) ?? 0)
                    .tint(color)
                    .accessibilityLabel("Position dans la zone")
            }
            if let t = manager.live?.targetZone, manager.isPhoneLinked(now: now) {
                Text(targetHint(target: t, zone: zone)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(WatchStyle.duration(elapsed)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var elapsed: Double? {
        if manager.isPhoneLinked(now: now), let l = manager.live { return l.activeSeconds }
        return manager.startDate.map { now.timeIntervalSince($0) }
    }

    private func targetHint(target: Int, zone: Int?) -> String {
        guard let z = zone else { return "Cible : zone \(target)" }
        if z < target { return "Cible zone \(target) : en dessous" }
        if z > target { return "Cible zone \(target) : au-dessus" }
        return "Dans la zone cible"
    }
}

/// Durée, vitesse et inclinaison du tapis, étape en cours et temps restant.
struct TreadmillPage: View {
    @Environment(WorkoutManager.self) private var manager
    let now: Date

    var body: some View {
        ScrollView {
            if let l = manager.live, manager.isPhoneLinked(now: now) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(WatchStyle.duration(l.activeSeconds)).font(.title3.monospacedDigit().bold())
                        Spacer()
                        Text(l.stateLabel).font(.caption2).foregroundStyle(l.state == .running ? Color.green : Color.orange)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(WatchStyle.speed(l.speedKmh)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.cyan)
                        Text("km/h").font(.footnote)
                        Spacer()
                        Text(String(format: "%.0f %%", l.inclinePercent ?? l.targetInclinePercent)).font(.title3.monospacedDigit())
                            .foregroundStyle(.yellow)
                    }
                    Text(String(format: "Consigne %.1f km/h", l.targetSpeedKmh)).font(.caption2).foregroundStyle(.secondary)
                    if let name = l.phaseName {
                        Divider()
                        Text(name).font(.headline).lineLimit(2)
                        HStack {
                            Text("Reste \(WatchStyle.duration(l.phaseRemaining))").monospacedDigit()
                            Spacer()
                            if let i = l.phaseIndex { Text("\(i + 1)/\(l.phaseCount)").foregroundStyle(.secondary) }
                        }
                        .font(.footnote)
                        if let next = l.nextPhaseName { Text("Ensuite : \(next)").font(.caption2).foregroundStyle(.secondary) }
                        Text("Programme : reste \(WatchStyle.duration(l.programRemaining))").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let a = l.autopilotStatus {
                        Label(a, systemImage: "heart.circle").font(.caption2).foregroundStyle(.green)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "iphone.slash").font(.title2).foregroundStyle(.secondary)
                    Text("iPhone non relié").font(.headline)
                    Text("Vitesse et étapes s'affichent quand une séance Foulée tourne sur l'iPhone à proximité.")
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
            }
        }
    }
}

/// Pause/Reprise et Arrêt (le tapis est arrêté par l'iPhone).
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
                    .tint(.green)
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
                if let t = manager.linkedTitle { Text(t).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

struct EndedView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            if case let .ended(saved) = manager.phase {
                Text(saved ? "Exercice enregistré dans Santé" : "Exercice non enregistré").multilineTextAlignment(.center)
            }
            Button("OK") { manager.reset() }
        }
    }
}
