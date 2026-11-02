import Foundation
import UserNotifications
import TreadCore

/// Fin de validité de la signature de l'app (compte développeur gratuit : 7 jours). La date est
/// lue dans le profil embarqué (`embedded.mobileprovision`) ; une notification est programmée la
/// veille à 9 h pour penser à réinstaller l'app depuis Xcode avant qu'elle ne s'ouvre plus.
/// Rien n'est fait si l'app n'a pas de profil embarqué (simulateur, App Store).
enum SigningExpiry {
    static let notificationID = "foulee.signing-expiry"
    private static let notifiedKey = "foulee.signing-expiry.notified"

    /// Date d'expiration du profil embarqué (nil si absent ou illisible).
    static func expirationDate(bundle: Bundle = .main) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound),
                                                                 format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }

    /// Veille de l'expiration à 9 h (heure locale), ou 2 h avant si la veille à 9 h tombe après.
    static func reminderDate(expiry: Date, calendar: Calendar = .current) -> Date {
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: expiry) ?? expiry
        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore) ?? dayBefore
        return min(nineAM, expiry.addingTimeInterval(-2 * 3600))
    }

    /// Programme (ou reprogramme) le rappel pour la signature actuelle. À appeler au lancement :
    /// une réinstallation depuis Xcode donne une nouvelle date et remplace l'ancien rappel.
    @MainActor
    static func scheduleReminder(log: DiagnosticLog, now: Date = Date()) async {
        guard let expiry = expirationDate(), expiry > now else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            log.log(.warning, "Rappel de fin de signature non programmé : notifications refusées")
            return
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateFormat = "EEEE d MMMM 'à' HH:mm"
        let content = UNMutableNotificationContent()
        content.title = "Foulée expire bientôt"
        content.body = "La signature de Foulée se termine \(df.string(from: expiry)). Réinstallez Foulee puis FouleeWatch depuis Xcode avant, sinon les apps ne s'ouvriront plus."
        content.sound = .default

        var fire = reminderDate(expiry: expiry)
        if fire <= now {
            // Déjà la veille : un seul rappel immédiat pour cette signature.
            let stamp = expiry.timeIntervalSince1970
            guard UserDefaults.standard.double(forKey: notifiedKey) != stamp else { return }
            UserDefaults.standard.set(stamp, forKey: notifiedKey)
            fire = now.addingTimeInterval(60)
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let request = UNNotificationRequest(identifier: notificationID, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        do {
            try await center.add(request)
            log.log(.info, "Rappel de fin de signature programmé le \(df.string(from: fire)) (expiration \(df.string(from: expiry)))")
        } catch {
            log.log(.warning, "Rappel de fin de signature non programmé : \(error.localizedDescription)")
        }
    }
}
