import SwiftUI
import Charts
import TreadCore

/// Aperçu d'un programme : profil d'intensité en barres (même dessin que les cartes), repères
/// de durée et de vitesse, légende des types d'étape présents.
struct ProgramProfile: View {
    let program: WorkoutProgram

    private var kinds: [PhaseKind] {
        let present = Set(program.schedule.map(\.phase.kind))
        return PhaseKind.allCases.filter(present.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("jusqu'à \(Format.speed(program.maxSpeedKmh)) km/h")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            IntensityProfile(program: program).frame(height: 64)
            HStack {
                Text("0")
                Spacer()
                Text("\(Int((Double(program.totalDurationSeconds) / 60).rounded())) min")
            }
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(kinds, id: \.self) { k in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.phaseColor(k)).frame(width: 7, height: 7)
                        Text(k.label).lineLimit(1)
                    }
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profil du programme : \(ProgramStyle.summary(program))")
    }
}

/// Méthode de zones appliquée à une séance affichée : toujours les réglages actuels, avec la
/// méthode d'origine si la séance a été enregistrée avec d'autres bornes.
struct ZoneMethodNote: View {
    /// Séance telle qu'enregistrée (avant recalcul).
    let record: SessionRecord
    let zones: HeartZoneSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(zones.methodDescription)
            if record.zonesDiffer(from: zones) {
                Label("Zones recalculées depuis la FC enregistrée avec vos réglages actuels"
                      + (record.zoneSettings.map { " (séance faite avec : \($0.effectiveMethod.label), FC max \($0.maxHR))" } ?? "") + ".",
                      systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Barres de temps passé par zone.
struct ZoneBars: View {
    let seconds: [Double]

    var body: some View {
        let total = max(seconds.reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 6) {
            Text("Temps par zone").font(.headline)
            ForEach((0..<min(seconds.count, 6)).reversed(), id: \.self) { z in
                HStack {
                    Text(Theme.zoneName(z)).font(.caption.bold()).frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.zoneColor(z))
                            .frame(width: max(2, geo.size.width * seconds[z] / total))
                    }
                    .frame(height: 14)
                    Text(Format.duration(seconds[z])).font(.caption).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Courbe temporelle d'une séance enregistrée.
struct SessionSeriesChart: View {
    enum Metric { case heartRate, speed, incline }
    let record: SessionRecord
    let metric: Metric

    private struct P: Identifiable { let id: Int; let minute: Double; let value: Double; let target: Double? }

    private var points: [P] {
        record.samples.enumerated().compactMap { i, s in
            let v: Double?
            let t: Double?
            switch metric {
            case .heartRate: v = s.hr.map(Double.init); t = nil
            case .speed: v = s.speed; t = s.targetSpeed
            case .incline: v = s.incline; t = s.targetIncline
            }
            guard let v else { return nil }
            return P(id: i, minute: s.t / 60, value: v, target: t)
        }
    }

    private var color: Color {
        switch metric {
        case .heartRate: return Theme.heart
        case .speed: return Theme.speed
        case .incline: return Theme.incline
        }
    }

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Minute", p.minute), y: .value("Mesure", p.value), series: .value("Série", "Mesure"))
                    .foregroundStyle(color)
                if let t = p.target {
                    LineMark(x: .value("Minute", p.minute), y: .value("Cible", t), series: .value("Série", "Cible"))
                        .foregroundStyle(.gray)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartXAxisLabel("min")
        .chartLegend(.hidden)
    }
}

/// Frise du programme : phases colorées par type, position actuelle.
struct ProgramTimeline: View {
    let program: WorkoutProgram
    /// Secondes de programme écoulées.
    let elapsed: Double

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(program.totalDurationSeconds, 1))
            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    ForEach(program.schedule) { sp in
                        Rectangle()
                            .fill(Theme.phaseColor(sp.phase.kind).opacity(Double(sp.end) <= elapsed ? 0.35 : 1))
                            .frame(width: max(1, geo.size.width * Double(sp.phase.durationSeconds) / total - 1))
                    }
                }
                .clipShape(Capsule())
                Capsule().fill(Color.primary)
                    .frame(width: 3, height: geo.size.height + 6)
                    .offset(x: min(max(0, geo.size.width * elapsed / total - 1.5), geo.size.width - 3))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progression du programme")
        .accessibilityValue("\(Int(elapsed / Double(max(program.totalDurationSeconds, 1)) * 100)) %")
    }
}
