import SwiftUI
import Charts
import TreadCore

/// Prévisualisation vitesse (aires) et inclinaison (ligne) d'un programme.
struct ProgramChart: View {
    let program: WorkoutProgram
    /// Version miniature (listes) : sans axes.
    var compact = false

    private struct Point: Identifiable {
        let id: Int
        let minute: Double
        let speed: Double
        let incline: Double
    }

    private struct Band: Identifiable {
        let id: Int
        let from: Double
        let to: Double
        let low: Double
        let high: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        for sp in program.schedule {
            let a = Double(sp.start) / 60, b = Double(sp.end) / 60
            out.append(Point(id: out.count, minute: a, speed: sp.phase.speedKmh, incline: sp.phase.inclinePercent))
            out.append(Point(id: out.count, minute: b, speed: sp.phase.endSpeedKmh ?? sp.phase.speedKmh, incline: sp.phase.inclinePercent))
        }
        return out
    }

    /// Plage de vitesse des phases pilotées par la FC.
    private var bands: [Band] {
        program.schedule.compactMap { sp in
            sp.phase.autoSpeed.map { Band(id: sp.index, from: Double(sp.start) / 60, to: Double(sp.end) / 60, low: $0.minKmh, high: $0.maxKmh) }
        }
    }

    var body: some View {
        Chart {
            ForEach(bands) { b in
                RectangleMark(xStart: .value("Début", b.from), xEnd: .value("Fin", b.to),
                              yStart: .value("Min", b.low), yEnd: .value("Max", b.high))
                    .foregroundStyle(Theme.accent.opacity(0.18))
            }
            ForEach(points) { p in
                // yStart/yEnd : pas d'empilement aux changements de phase (deux points à la même minute).
                AreaMark(x: .value("Minute", p.minute), yStart: .value("Base", 0.0), yEnd: .value("Vitesse", p.speed))
                    .foregroundStyle(Theme.speed.opacity(0.3))
                    .interpolationMethod(.linear)
                LineMark(x: .value("Minute", p.minute), y: .value("Vitesse", p.speed), series: .value("Série", "Vitesse"))
                    .foregroundStyle(Theme.speed)
                LineMark(x: .value("Minute", p.minute), y: .value("Inclinaison", p.incline), series: .value("Série", "Inclinaison"))
                    .foregroundStyle(Theme.incline)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(compact ? .hidden : .automatic)
        .chartXAxisLabel(compact ? "" : "min")
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
