import SwiftUI
import TreadCore

@main
struct FouleeWatchApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Foulée \(WatchWorkoutState.running.rawValue)")
        }
    }
}
