import SwiftUI
import Charts
import TreadCore

/// Prévisualisation vitesse (aires) et inclinaison (ligne) d'un programme.
struct ProgramChart: View {
    let program: WorkoutProgram

    private struct Point: Identifiable {
        let id: Int
        let minute: Double
        let speed: Double
        let incline: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        for sp in program.schedule {
            let a = Double(sp.start) / 60, b = Double(sp.end) / 60
            out.append(Point(id: out.count, minute: a, speed: sp.phase.speedKmh, incline: sp.phase.inclinePercent))
            out.append(Point(id: out.count, minute: b, speed: sp.phase.speedKmh, incline: sp.phase.inclinePercent))
        }
        return out
    }

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Minute", p.minute), y: .value("Vitesse", p.speed))
                    .foregroundStyle(Theme.speed.opacity(0.35))
                    .interpolationMethod(.linear)
                LineMark(x: .value("Minute", p.minute), y: .value("Vitesse", p.speed), series: .value("Série", "Vitesse"))
                    .foregroundStyle(Theme.speed)
                LineMark(x: .value("Minute", p.minute), y: .value("Inclinaison", p.incline), series: .value("Série", "Inclinaison"))
                    .foregroundStyle(Theme.incline)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        .chartXAxisLabel("min")
        .chartLegend(.hidden)
        .accessibilityLabel("Graphique du programme : vitesse en bleu, inclinaison en jaune")
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
