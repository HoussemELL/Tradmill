import SwiftUI
import SwiftData
import TreadCore

@main
struct FouleeApp: App {
    let container: ModelContainer
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: ProgramEntity.self, SessionEntity.self)
        } catch {
            // Dernier recours : stockage en mémoire pour que l'app reste utilisable.
            container = try! ModelContainer(for: ProgramEntity.self, SessionEntity.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        self.container = container
        _model = State(initialValue: AppModel(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance == .dark ? .dark : nil)
                .tint(Theme.accent)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.appDidEnterBackground() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            SessionView()
                .tabItem { Label("Séance", systemImage: "figure.walk.motion") }
                .tag(0)
            ProgramListView()
                .tabItem { Label("Programmes", systemImage: "list.bullet.rectangle") }
                .tag(1)
            HistoryListView()
                .tabItem { Label("Historique", systemImage: "clock.arrow.circlepath") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
                .tag(3)
        }
        .onAppear { model.connectRememberedDevices() }
        .task { await model.prepareHealth() }
        .alert("Séance récupérée", isPresented: Binding(get: { model.recoveredNotice != nil },
                                                         set: { if !$0 { model.dismissRecoveredNotice() } })) {
            Button("OK") { model.dismissRecoveredNotice() }
        } message: {
            Text(model.recoveredNotice ?? "")
        }
    }
}
