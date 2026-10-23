import SwiftUI
import TreadCore

/// Texte des consignes d'une phase (km/h) : fixe, progressive ou pilotée par la FC.
enum PhaseText {
    static func speed(_ p: ProgramPhase) -> String {
        if let a = p.autoSpeed {
            return "auto Z\(a.targetZone) \(Format.speed(a.minKmh))–\(Format.speed(a.maxKmh)) km/h (départ \(Format.speed(p.speedKmh)))"
        }
        if let e = p.endSpeedKmh, p.isRamp {
            return "\(Format.speed(p.speedKmh)) → \(Format.speed(e)) km/h"
        }
        return "\(Format.speed(p.speedKmh)) km/h"
    }

    static func summary(_ p: ProgramPhase) -> String {
        var s = "\(speed(p)) · \(Format.incline(p.inclinePercent)) %"
        if let z = p.targetZone, p.autoSpeed == nil { s += " · Z\(z)" }
        return s
    }
}

/// Liste exacte des étapes d'un programme (blocs répétés compris).
struct ProgramSegmentsView: View {
    let program: WorkoutProgram

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(program.items) { item in
                switch item {
                case let .phase(p):
                    segmentRow(p, indent: false)
                case let .block(b):
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Répéter \(b.repeatCount) fois · \(Format.duration(TimeInterval(item.durationSeconds)))",
                              systemImage: "repeat")
                            .font(.subheadline.bold())
                        ForEach(b.phases) { p in segmentRow(p, indent: true) }
                    }
                }
            }
        }
    }

    private func segmentRow(_ p: ProgramPhase, indent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.phaseColor(p.kind)).frame(width: 4, height: 14)
            Text(Format.duration(TimeInterval(p.durationSeconds))).monospacedDigit().frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.name).font(.subheadline)
                Text(PhaseText.summary(p)).font(.caption).foregroundStyle(p.isAuto ? Theme.accent : .secondary)
            }
        }
        .padding(.leading, indent ? 16 : 0)
        .accessibilityElement(children: .combine)
    }
}
