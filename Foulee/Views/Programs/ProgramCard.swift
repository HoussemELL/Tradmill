import SwiftUI
import TreadCore

/// Catégorie d'affichage d'un programme (bibliothèque classée, pas de liste à plat).
enum ProgramCategory: Int, CaseIterable, Identifiable {
    case endurance, intervals, walking, personal

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .endurance: return "Endurance"
        case .intervals: return "Fractionné"
        case .walking: return "Marche"
        case .personal: return "Mes programmes"
        }
    }

    var subtitle: String {
        switch self {
        case .endurance: return "Zone 2 et test de référence"
        case .intervals: return "Fractionné principal, football, progressions"
        case .walking: return "Marche inclinée et récupération active"
        case .personal: return "Créés, dupliqués ou importés"
        }
    }

    static func of(_ p: WorkoutProgram) -> ProgramCategory {
        switch p.templateID {
        case ProgramTemplateID.zone2Auto?, ProgramTemplateID.cardioBaseline?, ProgramTemplateID.zone2Endurance?:
            return .endurance
        case ProgramTemplateID.intervalRun911?, ProgramTemplateID.hiitRun11?, ProgramTemplateID.footballEndurance1?,
             ProgramTemplateID.footballEndurance2?, ProgramTemplateID.footballEndurance3?:
            return .intervals
        case ProgramTemplateID.inclineWalk?, ProgramTemplateID.postMealWalk?:
            return .walking
        default:
            return .personal
        }
    }
}

/// Icône et teinte propres à chaque programme.
enum ProgramStyle {
    static func icon(_ p: WorkoutProgram) -> String {
        switch p.templateID {
        case ProgramTemplateID.zone2Auto?: return "heart.circle.fill"
        case ProgramTemplateID.cardioBaseline?: return "gauge.with.dots.needle.33percent"
        case ProgramTemplateID.zone2Endurance?: return "figure.walk.motion"
        case ProgramTemplateID.intervalRun911?: return "figure.run"
        case ProgramTemplateID.hiitRun11?: return "bolt.heart.fill"
        case ProgramTemplateID.footballEndurance1?, ProgramTemplateID.footballEndurance2?,
             ProgramTemplateID.footballEndurance3?: return "figure.soccer"
        case ProgramTemplateID.inclineWalk?: return "mountain.2.fill"
        case ProgramTemplateID.postMealWalk?: return "fork.knife"
        default: return p.hasAutoSpeed ? "heart.circle.fill" : (p.maxSpeedKmh >= 8 ? "figure.run" : "figure.walk")
        }
    }

    static func tint(_ p: WorkoutProgram) -> Color {
        if p.isAdvanced { return Theme.warning }
        switch ProgramCategory.of(p) {
        case .endurance: return Theme.accent
        case .intervals: return Theme.heart
        case .walking: return Theme.speed
        case .personal: return Color(uiColor: .systemIndigo)
        }
    }

    /// « 35 min · 4–7 km/h · 1 % »
    static func summary(_ p: WorkoutProgram) -> String {
        let speeds = p.schedule.flatMap { [$0.phase.speedBounds.min, $0.phase.speedBounds.max] }
        let inclines = p.schedule.map(\.phase.inclinePercent)
        let minutes = Int((Double(p.totalDurationSeconds) / 60).rounded())
        var parts = ["\(minutes) min"]
        if let lo = speeds.min(), let hi = speeds.max() {
            parts.append(abs(hi - lo) < 0.05 ? "\(Format.speed(hi)) km/h" : "\(Format.speed(lo))–\(Format.speed(hi)) km/h")
        }
        if let lo = inclines.min(), let hi = inclines.max() {
            parts.append(abs(hi - lo) < 0.05 ? "\(Format.incline(hi)) %" : "\(Format.incline(lo))–\(Format.incline(hi)) %")
        }
        return parts.joined(separator: " · ")
    }
}

/// Carte d'un programme : icône, nom, résumé, badges, profil d'intensité.
struct ProgramCardView: View {
    let program: WorkoutProgram
    var selected = false
    var showChevron = true

    var body: some View {
        let tint = ProgramStyle.tint(program)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: ProgramStyle.icon(program))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(program.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        if program.isLocked {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("verrouillé")
                        }
                    }
                    Text(ProgramStyle.summary(program))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                } else if showChevron {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            IntensityProfile(program: program).frame(height: 30)
            CardBadges(program: program)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Badges discrets : FC auto, niveau, avancé.
struct CardBadges: View {
    let program: WorkoutProgram

    var body: some View {
        let items = badges
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.text) { b in
                    Label(b.text, systemImage: b.icon)
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(b.color.opacity(0.14), in: Capsule())
                        .foregroundStyle(b.color)
                }
            }
        }
    }

    private struct Badge { let text: String; let icon: String; let color: Color }

    private var badges: [Badge] {
        var out: [Badge] = []
        if program.hasAutoSpeed { out.append(Badge(text: "Vitesse pilotée par la FC", icon: "heart.fill", color: Theme.accent)) }
        if let l = program.level {
            out.append(Badge(text: l == 1 ? "Niveau 1" : "Niveau \(l) · progression", icon: "chart.bar.fill", color: Theme.speed))
        }
        if program.isAdvanced { out.append(Badge(text: "Avancé", icon: "exclamationmark.triangle.fill", color: Theme.warning)) }
        return out
    }
}

/// Profil d'intensité : une barre par étape, largeur ∝ durée, hauteur ∝ vitesse, couleur par
/// type d'étape. Phase pilotée par la FC : vitesse de départ pleine, plage automatique en clair.
struct IntensityProfile: View {
    let program: WorkoutProgram

    private struct Bar: Identifiable {
        let id: Int
        let seconds: Double
        let speed: Double
        let ceiling: Double?
        let color: Color
    }

    private var bars: [Bar] {
        var out: [Bar] = []
        for sp in program.schedule {
            let p = sp.phase
            let color = Theme.phaseColor(p.kind)
            if p.isRamp {
                // Rampe : quelques tranches pour suivre la pente.
                let slices = 4
                for k in 0..<slices {
                    let t = (Double(k) + 0.5) / Double(slices) * Double(p.durationSeconds)
                    out.append(Bar(id: out.count, seconds: Double(p.durationSeconds) / Double(slices),
                                   speed: p.plannedSpeed(at: t), ceiling: nil, color: color))
                }
            } else {
                out.append(Bar(id: out.count, seconds: Double(p.durationSeconds), speed: p.speedKmh,
                               ceiling: p.autoSpeed?.maxKmh, color: color))
            }
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(program.totalDurationSeconds), 1)
            let top = max(program.maxSpeedKmh, 8)
            let gap: CGFloat = 1.5
            let usable = geo.size.width - gap * CGFloat(max(bars.count - 1, 0))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(bars) { b in
                    let w = max(2, usable * b.seconds / total)
                    ZStack(alignment: .bottom) {
                        if let c = b.ceiling {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(b.color.opacity(0.25))
                                .frame(height: geo.size.height * min(c / top, 1))
                        }
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(b.color.gradient)
                            .frame(height: max(3, geo.size.height * min(b.speed / top, 1)))
                    }
                    .frame(width: w)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
