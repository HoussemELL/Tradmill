import SwiftUI
import UIKit
import TreadCore

/// Palette adaptative (clair/sombre) : les couleurs vives du mode sombre sont assombries en mode
/// clair pour garder un contraste suffisant sur fond blanc (texte et pictogrammes).
enum Theme {
    static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let accent = adaptive(light: UIColor(red: 0.00, green: 0.55, blue: 0.38, alpha: 1),
                                 dark: UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1))
    /// Fond des écrans (groupé) et des cartes.
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardStrong = Color(uiColor: .tertiarySystemGroupedBackground)
    static let warning = adaptive(light: UIColor(red: 0.80, green: 0.42, blue: 0.00, alpha: 1), dark: .systemOrange)
    static let danger = adaptive(light: UIColor(red: 0.80, green: 0.13, blue: 0.15, alpha: 1),
                                 dark: UIColor(red: 0.95, green: 0.27, blue: 0.27, alpha: 1))
    static let speed = adaptive(light: UIColor(red: 0.00, green: 0.45, blue: 0.80, alpha: 1),
                                dark: UIColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1))
    static let incline = adaptive(light: UIColor(red: 0.70, green: 0.45, blue: 0.00, alpha: 1),
                                  dark: UIColor(red: 0.98, green: 0.75, blue: 0.14, alpha: 1))
    static let heart = adaptive(light: UIColor(red: 0.82, green: 0.12, blue: 0.27, alpha: 1),
                                dark: UIColor(red: 0.96, green: 0.30, blue: 0.40, alpha: 1))

    /// Couleurs des zones 0 (sous Z1) à 5.
    static func zoneColor(_ zone: Int?) -> Color {
        switch zone {
        case 1: return Color(red: 0.55, green: 0.62, blue: 0.70)
        case 2: return Color(red: 0.22, green: 0.62, blue: 0.95)
        case 3: return Color(red: 0.20, green: 0.80, blue: 0.45)
        case 4: return Color(red: 0.98, green: 0.62, blue: 0.10)
        case 5: return Color(red: 0.94, green: 0.25, blue: 0.30)
        case 0: return Color(white: 0.5)
        default: return Color(uiColor: .systemGray)
        }
    }

    static func zoneName(_ zone: Int?) -> String {
        switch zone {
        case 0: return "Sous Z1"
        case let z?: return "Z\(z)"
        default: return "—"
        }
    }

    static func phaseColor(_ kind: PhaseKind?) -> Color {
        switch kind {
        case .warmup: return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .work: return Color(red: 0.94, green: 0.33, blue: 0.31)
        case .recovery: return Color(red: 0.22, green: 0.62, blue: 0.95)
        case .cooldown: return Color(red: 0.55, green: 0.50, blue: 0.95)
        case .steady: return accent
        case nil: return Color(white: 0.4)
        }
    }
}

enum Format {
    static func duration(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite else { return "—" }
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func speed(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }

    static func incline(_ v: Double?) -> String {
        guard let v else { return "—" }
        return abs(v - v.rounded()) < 0.05 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : String(format: "%.0f m", m)
    }

    static func shortDate(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

extension View {
    /// Fond d'écran groupé (les cartes se détachent en clair comme en sombre).
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// Carte standard.
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Titre de section dans un écran défilant.
struct SectionTitle: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.title3.bold())
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
        .padding(.top, 6)
    }
}

/// Carte métrique à gros chiffres, lisible en marchant.
struct MetricTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var detail: String?
    var color: Color = .primary
    var large = false
    var accessibilityValue: String?
    @ScaledMetric(relativeTo: .largeTitle) var largeSize: CGFloat = 64
    @ScaledMetric(relativeTo: .title) var normalSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: large ? largeSize : normalSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit).font(.headline).foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? "\(value) \(unit) \(detail ?? "")")
    }
}

struct StatusPill: View {
    let text: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Banner: View {
    let text: String
    var color: Color = Theme.warning
    var systemImage = "exclamationmark.triangle.fill"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(color)
    }
}
