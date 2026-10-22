import SwiftUI
import TreadCore

@main
struct FouleeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Foulée — \(TreadmillProfile.urtm047.name)")
        }
    }
}
