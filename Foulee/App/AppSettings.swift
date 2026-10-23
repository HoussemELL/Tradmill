import Foundation
import TreadCore

/// Réglages de l'app, stockés en JSON dans UserDefaults.
struct AppSettings: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable {
        case dark, system
        var label: String { self == .dark ? "Sombre" : "Système" }
    }

    var session = SessionSettings()
    var health = HealthSettings()
    var heartRatePreference: HeartRateSourcePreference = .automatic

    var lastTreadmillID: UUID?
    var lastTreadmillName: String?
    var lastHeartRateSensorID: UUID?
    var lastHeartRateSensorName: String?
    /// nil = profil choisi automatiquement d'après le nom BLE.
    var profileOverrideID: String?
    var simulatorMode = false

    var keepScreenOnDuringPrograms = true
    var keepScreenOnDuringFreeRun = true
    var appearance: Appearance = .dark
    var hapticAlerts = true

    /// Lancer l'exercice Apple Watch quand une séance démarre (cardio en direct).
    var startWatchWorkoutWithSession = true
    /// Terminer l'exercice Watch à la fin de la séance.
    var endWatchWorkoutWithSession = true

    var logRawTelemetry = true
    /// Optionnel pour rester lisible par les réglages enregistrés avant son ajout.
    var didRequestHealthAuthorization: Bool?
    var didSeedTemplates = false
}

final class SettingsStore {
    private let key = "foulee.settings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? CoreJSON.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    func save(_ s: AppSettings) {
        if let data = try? CoreJSON.encode(s) {
            defaults.set(data, forKey: key)
        }
    }
}
