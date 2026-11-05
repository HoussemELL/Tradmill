import SwiftUI
import HealthKit
import SwiftData
import TreadCore

/// L'app Watch peut demander l'accès à Santé depuis la montre ; quand iOS présente cette
/// demande sur l'iPhone, l'app doit la traiter, sinon la montre la redemande à chaque exercice.
final class FouleeAppDelegate: NSObject, UIApplicationDelegate {
    func applicationShouldRequestHealthAuthorization(_ application: UIApplication) {
        HKHealthStore().handleAuthorizationForExtension { _, _ in }
    }
}

@main
struct FouleeApp: App {
    @UIApplicationDelegateAdaptor(FouleeAppDelegate.self) private var appDelegate
    let container: ModelContainer
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Base dans le conteneur privé de l'app (jamais dans le dossier partagé avec Rythme).
        let container = StoreLocation.makeContainer()
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
    @State private var tab = Int(ScenarioRunner.value("-FouleeTab") ?? "") ?? 0

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
        .alert("Historique non enregistré", isPresented: Binding(get: { model.storageWarning != nil },
                                                                 set: { if !$0 { model.storageWarning = nil } })) {
            Button("OK") { model.storageWarning = nil }
        } message: {
            Text(model.storageWarning ?? "")
        }
        .alert("Séance récupérée", isPresented: Binding(get: { model.recoveredNotice != nil },
                                                         set: { if !$0 { model.dismissRecoveredNotice() } })) {
            Button("OK") { model.dismissRecoveredNotice() }
        } message: {
            Text(model.recoveredNotice ?? "")
        }
    }
}
