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

struct LiveView: View {
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "heart.fill").foregroundStyle(.red)
                        Text(heartText(now: context.date))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("bpm").font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Text(elapsed(now: context.date)).font(.title3.monospacedDigit())
                    if let s = manager.steps { Text("\(Int(s)) pas").font(.footnote) }
                    Label(manager.mirroring ? "iPhone (miroir)" : "iPhone (WatchConnectivity)",
                          systemImage: "iphone.radiowaves.left.and.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let t = manager.linkedTitle { Text(t).font(.caption2).foregroundStyle(.secondary) }
                    HStack {
                        if manager.phase == .paused {
                            Button { manager.resume() } label: { Image(systemName: "play.fill") }
                                .accessibilityLabel("Reprendre")
                        } else {
                            Button { manager.pause() } label: { Image(systemName: "pause.fill") }
                                .accessibilityLabel("Pause")
                        }
                        Button(role: .destructive) { manager.end() } label: { Image(systemName: "stop.fill") }
                            .accessibilityLabel("Terminer l'exercice")
                    }
                }
            }
        }
    }

    private func heartText(now: Date) -> String {
        guard let bpm = manager.heartRate, let d = manager.heartRateDate, now.timeIntervalSince(d) < 15 else { return "—" }
        return "\(Int(bpm.rounded()))"
    }

    private func elapsed(now: Date) -> String {
        guard let s = manager.startDate else { return "00:00" }
        let t = Int(now.timeIntervalSince(s))
        return String(format: "%02d:%02d", t / 60, t % 60)
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
