import SwiftUI
import SwiftData
import Charts
import TreadCore

// MARK: - Courbes superposées vitesse / FC

/// Vitesse (axe de gauche, km/h) et FC (axe de droite, bpm) sur le même graphique,
/// avec la bande de la zone visée.
struct SpeedHeartChart: View {
    let record: SessionRecord
    var zone: ZoneRange?

    private struct P: Identifiable {
        let id: Int
        let minute: Double
        let speed: Double?
        let hr: Double?
    }

    private var points: [P] {
        var out: [P] = []
        for (i, s) in record.samples.enumerated() where i % 3 == 0 {
            out.append(P(id: i, minute: s.t / 60, speed: s.speed, hr: s.hr.map(Double.init)))
        }
        return out
    }

    private var speedTop: Double { max((record.maxSpeed ?? 6) * 1.15, 2) }

    private var hrRange: (Double, Double) {
        var lo = Double(record.samples.compactMap(\.hr).min() ?? 80)
        var hi = Double(record.maxHR ?? 160)
        if let z = zone {
            lo = min(lo, Double(max(z.lower, 40)))
            hi = max(hi, Double(z.upper))
        }
        return (max(30, lo - 10), hi + 10)
    }

    private func y(_ bpm: Double) -> Double {
        let (lo, hi) = hrRange
        return (bpm - lo) / max(hi - lo, 1) * speedTop
    }

    private func bpm(_ y: Double) -> Double {
        let (lo, hi) = hrRange
        return lo + y / speedTop * (hi - lo)
    }

    private func hrLabel(_ y: Double?) -> String {
        y.map { "\(Int(bpm($0).rounded()))" } ?? ""
    }

    private var hrTicks: [Double] {
        let (lo, hi) = hrRange
        let step = 20.0
        let first = (lo / step).rounded(.up) * step
        return stride(from: first, through: hi, by: step).map { y($0) }
    }

    var body: some View {
        let lastMinute = (record.samples.last?.t ?? 60) / 60
        Chart {
            if let z = zone {
                RectangleMark(xStart: .value("Début", 0.0), xEnd: .value("Fin", lastMinute),
                              yStart: .value("Bas", y(Double(max(z.lower, 1)))), yEnd: .value("Haut", y(Double(z.upper))))
                    .foregroundStyle(Theme.zoneColor(z.zone).opacity(0.18))
            }
            ForEach(points) { p in
                if let s = p.speed {
                    LineMark(x: .value("Minute", p.minute), y: .value("Vitesse", s), series: .value("Série", "Vitesse"))
                        .foregroundStyle(Theme.speed)
                }
                if let h = p.hr {
                    LineMark(x: .value("Minute", p.minute), y: .value("FC", y(h)), series: .value("Série", "FC"))
                        .foregroundStyle(Theme.heart)
                }
            }
        }
        .chartYScale(domain: 0...speedTop)
        .chartYAxis {
            AxisMarks(position: .leading)
            AxisMarks(position: .trailing, values: hrTicks) { value in
                AxisValueLabel { Text(hrLabel(value.as(Double.self))) }
            }
        }
        .chartXAxisLabel("min")
        .chartLegend(.hidden)
        .accessibilityLabel("Vitesse en bleu (km/h, à gauche) et fréquence cardiaque en rouge (bpm, à droite)")
    }
}

struct ChartLegendRow: View {
    var zone: ZoneRange?

    var body: some View {
        HStack(spacing: 12) {
            Label("Vitesse (km/h)", systemImage: "line.diagonal").foregroundStyle(Theme.speed)
            Label("FC (bpm, à droite)", systemImage: "line.diagonal").foregroundStyle(Theme.heart)
            if let z = zone {
                Label("Z\(z.zone)", systemImage: "rectangle.fill").foregroundStyle(Theme.zoneColor(z.zone))
            }
        }
        .font(.caption)
    }
}

// MARK: - Bilan d'une séance

/// Bilan commun (fin de séance et historique) : FC et vitesse, zone visée, courbes,
/// intervalles, récupération.
struct SessionInsightsView: View {
    let record: SessionRecord

    private var autoZone: Int? {
        record.program?.schedule.first { $0.phase.isAuto }?.phase.autoSpeed?.targetZone
    }

    private var zoneRange: ZoneRange? {
        guard let z = autoZone ?? mainTargetZone else { return nil }
        return record.zoneSettings?.zones.first { $0.zone == z }
    }

    private var mainTargetZone: Int? {
        (record.phaseSpans ?? []).max { ($0.end ?? $0.start) - $0.start < ($1.end ?? $1.start) - $1.start }?.targetZone
    }

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricTile(title: "FC moyenne", value: record.avgHR.map { "\($0)" } ?? "—", unit: "bpm",
                           detail: "max \(record.maxHR.map { "\($0)" } ?? "—")", color: Theme.heart)
                MetricTile(title: "Vitesse moyenne", value: Format.speed(record.avgSpeed), unit: "km/h",
                           detail: "max \(Format.speed(record.maxSpeed))", color: Theme.speed)
            }
            if let z = autoZone {
                ZoneFocusCard(summary: SessionAnalysis.zoneFocus(record, zone: z), range: zoneRange)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Vitesse et FC").font(.headline)
                SpeedHeartChart(record: record, zone: zoneRange).frame(height: 180)
                ChartLegendRow(zone: zoneRange)
            }
            .padding()
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            let stats = SessionAnalysis.phaseStats(record)
            if !stats.isEmpty { IntervalStatsCard(stats: stats) }
            if let rec = SessionAnalysis.postStopRecovery(record) { RecoveryCard(recovery: rec) }
            if let entry = ProgressAnalysis.entry(for: record) { ComparabilityCard(entry: entry) }
        }
    }
}

struct ZoneFocusCard: View {
    let summary: ZoneFocusSummary
    let range: ZoneRange?

    private func pct(_ f: Double?) -> String { f.map { "\(Int(($0 * 100).rounded())) %" } ?? "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Zone \(summary.zone)").font(.headline)
                if let r = range { Text("\(r.lower)–\(r.upper) bpm").font(.subheadline).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricTile(title: "Séance en zone \(summary.zone)", value: pct(summary.sessionFraction),
                           color: Theme.zoneColor(summary.zone))
                MetricTile(title: "Phase pilotée en zone", value: pct(summary.autoPhaseFraction),
                           detail: Format.duration(summary.autoPhaseSeconds), color: Theme.zoneColor(summary.zone))
                MetricTile(title: "Vitesse pour rester en zone", value: Format.speed(summary.speedInZone), unit: "km/h",
                           color: Theme.speed)
                MetricTile(title: "Ajustements auto", value: "\(summary.adjustments)",
                           detail: "+\(summary.increases) · −\(summary.decreases)" + (summary.safetySteps > 0 ? " · sécurité \(summary.safetySteps)" : ""))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// FC moyenne, maximale et récupération par intervalle.
struct IntervalStatsCard: View {
    let stats: [PhaseStats]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Par intervalle").font(.headline)
            ForEach(stats) { st in row(st) }
            Text("Consigne : vitesse demandée par le programme. Mesurée : moyenne réelle de la bande, accélération au départ comprise. Récup. 60 s : baisse de FC dans la minute qui suit la fin de l'intervalle (phase suivante plus lente ou arrêt).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ st: PhaseStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                RoundedRectangle(cornerRadius: 2).fill(Theme.phaseColor(st.kind)).frame(width: 4, height: 14)
                Text(st.name).font(.subheadline.bold()).lineLimit(1)
                if st.auto { Image(systemName: "heart.circle").foregroundStyle(Theme.accent) }
                Spacer()
                Text(Format.duration(st.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(line(st)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func line(_ st: PhaseStats) -> String {
        let target = st.auto ? "pilotée FC"
            : st.endSpeedKmh.map { "\(Format.speed(st.targetSpeedKmh))→\(Format.speed($0)) km/h" } ?? "\(Format.speed(st.targetSpeedKmh)) km/h"
        var parts = ["consigne \(target)", "mesurée \(Format.speed(st.avgSpeed)) moy"]
        parts.append("FC \(st.avgHR.map(String.init) ?? "—") moy · \(st.maxHR.map(String.init) ?? "—") max")
        if let d = st.recoveryDrop60 { parts.append("récup. 60 s −\(d)") }
        if let z = st.targetZone, let s = st.secondsInTargetZone, st.secondsWithHR > 0 {
            parts.append("Z\(z) \(Int((s / st.secondsWithHR * 100).rounded())) %")
        }
        return parts.joined(separator: " · ")
    }
}

struct RecoveryCard: View {
    let recovery: PostStopRecovery

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Récupération après l'arrêt").font(.headline)
            Text("À l'arrêt : \(recovery.hrAtStop) bpm").monospacedDigit()
            Text("Après 1 min : \(recovery.hrAfter60.map { "\($0) bpm (−\(recovery.hrAtStop - $0))" } ?? "—")").monospacedDigit()
            Text("Après 2 min : \(recovery.hrAfter120.map { "\($0) bpm (−\(recovery.hrAtStop - $0))" } ?? "—")").monospacedDigit()
        }
        .font(.subheadline)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ComparabilityCard: View {
    let entry: ProgressEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.comparable ? "Comparable aux séances identiques" : "Non comparable",
                  systemImage: entry.comparable ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(entry.comparable ? Theme.accent : Theme.warning)
            if !entry.comparable {
                Text(entry.notComparableReasons.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            if let h = entry.referenceHR, let label = entry.referenceLabel {
                Text("\(label) : \(h) bpm").font(.subheadline)
            }
            NavigationLink {
                ProgressDetailView(signature: entry.signature)
            } label: {
                Label("Évolution des séances identiques", systemImage: "chart.line.uptrend.xyaxis")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Progression dans le temps

struct ProgressListView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SessionEntity.startDate) private var sessions: [SessionEntity]

    var body: some View {
        let groups = ProgressAnalysis.groups(sessions.compactMap(\.record).map { model.displayRecord($0) })
        List {
            if groups.isEmpty {
                Text("Les séances faites avec un programme apparaîtront ici, regroupées par protocole identique.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { g in
                NavigationLink {
                    ProgressDetailView(signature: g.signature)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.name).font(.headline)
                        Text("\(g.entries.count) séance(s) · \(g.comparableEntries.count) comparable(s)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let t = g.trend { Text(t).font(.caption) }
                    }
                }
            }
        }
        .navigationTitle("Progression")
    }
}

struct ProgressDetailView: View {
    let signature: String
    @Environment(AppModel.self) private var model
    @Query(sort: \SessionEntity.startDate) private var sessions: [SessionEntity]

    private var group: ProgressGroup? {
        ProgressAnalysis.groups(sessions.compactMap(\.record).map { model.displayRecord($0) }).first { $0.signature == signature }
    }

    var body: some View {
        ScrollView {
            if let g = group {
                VStack(alignment: .leading, spacing: 12) {
                    Text(g.isAuto
                         ? "Vitesse moyenne mesurée pendant que la FC était dans la zone visée : plus elle monte, plus vous allez vite pour la même intensité cardiaque."
                         : "FC moyenne sur la fin de la phase principale, à vitesse identique : plus elle baisse, meilleure est la condition.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let t = g.trend { Banner(text: t, color: Theme.accent, systemImage: "chart.line.uptrend.xyaxis") }
                    VStack(alignment: .leading) {
                        Text(g.isAuto ? "Vitesse en zone (km/h)" : "FC de référence (bpm)").font(.headline)
                        ProgressChart(group: g).frame(height: 180)
                        Text("Points pleins : séances comparables · creux : non comparables").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                    ForEach(Array(g.entries.reversed())) { e in entryRow(e, auto: g.isAuto) }
                }
                .padding()
            } else {
                Text("Aucune séance pour ce protocole.").foregroundStyle(.secondary).padding()
            }
        }
        .screenBackground()
        .navigationTitle(group?.name ?? "Progression")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func entryRow(_ e: ProgressEntry, auto: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Format.shortDate(e.date)).font(.subheadline.bold())
                Spacer()
                if !e.comparable { StatusPill(text: "Non comparable", systemImage: "exclamationmark.triangle", color: Theme.warning) }
            }
            Text(values(e, auto: auto)).font(.caption).monospacedDigit()
            if !e.comparable {
                Text(e.notComparableReasons.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func values(_ e: ProgressEntry, auto: Bool) -> String {
        var parts: [String] = []
        if auto {
            parts.append("en zone \(e.targetZone ?? 2) : \(Format.speed(e.speedInZone)) km/h")
            if let f = e.zoneFraction { parts.append("\(Int((f * 100).rounded())) % du temps") }
            if let n = e.autoAdjustments { parts.append("\(n) ajust.") }
        } else {
            parts.append("FC réf. \(e.referenceHR.map(String.init) ?? "—")")
        }
        parts.append("FC \(e.avgHR.map(String.init) ?? "—") moy · \(e.maxHR.map(String.init) ?? "—") max")
        parts.append("\(Format.speed(e.avgSpeed)) km/h moy")
        if let r = e.recoveryDrop60 { parts.append("récup. 1 min −\(r)") }
        return parts.joined(separator: " · ")
    }
}

struct ProgressChart: View {
    let group: ProgressGroup

    private struct P: Identifiable {
        let id: UUID
        let date: Date
        let value: Double
        let comparable: Bool
    }

    private var points: [P] {
        group.entries.compactMap { e in
            let v: Double? = group.isAuto ? e.speedInZone : e.referenceHR.map(Double.init)
            return v.map { P(id: e.id, date: e.date, value: $0, comparable: e.comparable) }
        }
    }

    var body: some View {
        let color = group.isAuto ? Theme.speed : Theme.heart
        Chart {
            ForEach(points.filter(\.comparable)) { p in
                LineMark(x: .value("Date", p.date), y: .value("Valeur", p.value))
                    .foregroundStyle(color)
            }
            ForEach(points) { p in
                PointMark(x: .value("Date", p.date), y: .value("Valeur", p.value))
                    .foregroundStyle(p.comparable ? color : Color.gray)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

// MARK: - Ressenti de l'effort

/// Ressenti de l'effort (échelle CR10 de Borg), saisi après la séance et exporté pour Rythme.
struct PerceivedExertionCard: View {
    @Environment(AppModel.self) private var model
    let recordID: UUID
    @State private var value: Int?

    init(recordID: UUID, initial: Int?) {
        self.recordID = recordID
        _value = State(initialValue: initial)
    }

    static func label(_ v: Int) -> String {
        switch v {
        case 0: return "Repos"
        case 1: return "Très facile"
        case 2: return "Facile"
        case 3: return "Modéré"
        case 4: return "Un peu difficile"
        // Un libellé distinct par valeur (6 et 8 sont des paliers intermédiaires de l'échelle CR10).
        case 5: return "Difficile"
        case 6: return "Vraiment difficile"
        case 7: return "Très difficile"
        case 8: return "Très, très difficile"
        case 9: return "Extrêmement difficile"
        default: return "Maximal"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ressenti de l'effort").font(.headline)
                Text("Échelle 0–10 (Borg CR10)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Ressenti", selection: $value) {
                Text("Non renseigné").tag(Int?.none)
                ForEach(0...10, id: \.self) { v in Text("\(v) · \(Self.label(v))").tag(Optional(v)) }
            }
            .pickerStyle(.menu)
        }
        .card()
        .onChange(of: value) { _, v in model.setPerceivedExertion(v, for: recordID) }
    }
}
