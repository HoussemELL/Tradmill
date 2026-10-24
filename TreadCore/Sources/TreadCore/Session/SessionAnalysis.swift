import Foundation

/// Statistiques d'une phase exécutée (intervalle).
public struct PhaseStats: Equatable, Sendable, Identifiable {
    public var index: Int
    public var name: String
    public var kind: PhaseKind
    /// Secondes depuis le début de la séance.
    public var start: Double
    public var end: Double
    public var targetSpeedKmh: Double
    public var endSpeedKmh: Double?
    public var auto: Bool
    public var targetZone: Int?
    public var avgSpeed: Double?
    public var maxSpeed: Double?
    public var avgHR: Int?
    public var maxHR: Int?
    public var hrAtEnd: Int?
    /// Baisse de FC dans les 60 s qui suivent la fin de la phase, quand la suivante est plus lente
    /// (récupération après un effort) ou que la séance s'arrête.
    public var recoveryDrop60: Int?
    /// Temps passé dans la zone cible (si la phase en a une).
    public var secondsInTargetZone: Double?
    public var secondsWithHR: Double

    public var id: Int { index }
    public var duration: Double { max(0, end - start) }
}

/// FC de récupération après l'arrêt de la bande (mesures de la ceinture/du brassard).
public struct PostStopRecovery: Equatable, Sendable {
    public var hrAtStop: Int
    public var hrAfter60: Int?
    public var hrAfter120: Int?
    public var drop60: Int? { hrAfter60.map { hrAtStop - $0 } }
    public var drop120: Int? { hrAfter120.map { hrAtStop - $0 } }
}

/// Bilan d'une séance visant une zone (programme « Zone 2 auto »).
public struct ZoneFocusSummary: Equatable, Sendable {
    public var zone: Int
    /// Part du temps actif avec FC passé dans la zone, sur toute la séance (0…1).
    public var sessionFraction: Double?
    /// Part du temps de la phase pilotée passé dans la zone (0…1).
    public var autoPhaseFraction: Double?
    public var autoPhaseSeconds: Double
    /// Vitesse moyenne mesurée pendant que la FC était dans la zone (phase pilotée) :
    /// la vitesse « nécessaire » pour rester dans la zone.
    public var speedInZone: Double?
    public var adjustments: Int
    public var increases: Int
    public var decreases: Int
    public var safetySteps: Int
}

public enum SessionAnalysis {
    /// FC la plus proche de l'instant `t` (± `tolerance` s) : mesures horodatées si présentes,
    /// sinon échantillons 1 Hz.
    public static func heartRate(at t: Double, in r: SessionRecord, tolerance: Double = 5) -> Int? {
        if let readings = r.heartRateReadings, !readings.isEmpty {
            let best = readings.min { abs($0.t - t) < abs($1.t - t) }
            if let b = best, abs(b.t - t) <= tolerance { return b.bpm }
            return nil
        }
        let best = r.samples.filter { $0.hr != nil }.min { abs($0.t - t) < abs($1.t - t) }
        guard let b = best, abs(b.t - t) <= tolerance else { return nil }
        return b.hr
    }

    // MARK: - Temps par zone (règle commune Foulée / Rythme, docs/ZONES.md)

    /// Durée maximale attribuée à une mesure de FC (au-delà : trou, non compté).
    public static let zoneHoldSeconds: Double = 10
    /// Identifiant de la règle, exporté avec les zones.
    public static let zoneRuleID = "foulee.zones.v1: heartRate[] tenue jusqu'à la mesure suivante (max 10 s), bande en mouvement hors pauses"

    /// Périodes où la bande tournait (s depuis `startDate`) : démarrage réel → arrêt réel,
    /// pauses exclues. Ni le compte à rebours ni la récupération après l'arrêt n'en font partie.
    public static func activeIntervals(_ r: SessionRecord) -> [(start: Double, end: Double)] {
        let firstActive = r.samples.first { !$0.paused }?.t
        guard let start = r.beltStartDate.map({ $0.timeIntervalSince(r.startDate) }) ?? firstActive else { return [] }
        let lastActive = r.samples.last { !$0.paused }?.t
        guard let end = r.beltStopDate.map({ $0.timeIntervalSince(r.startDate) }) ?? lastActive, end > start else { return [] }
        var out: [(start: Double, end: Double)] = []
        var from: Double? = start
        for e in r.events where e.t > start && e.t < end {
            switch e.kind {
            case .pause:
                if let f = from { if e.t > f { out.append((f, e.t)) }; from = nil }
            case .resume:
                if from == nil { from = e.t }
            default:
                break
            }
        }
        if let f = from, end > f { out.append((f, end)) }
        return out
    }

    /// Temps par zone (index 0 = sous Z1, 1…5), règle reproductible depuis l'export :
    /// chaque mesure de FC horodatée (`heartRate[]`) compte jusqu'à la mesure suivante, au plus
    /// `zoneHoldSeconds`, dans la zone de sa valeur, et seulement sur les périodes où la bande
    /// tournait (`activeIntervals`). Sans mesures horodatées (anciennes séances) : échantillons 1 Hz.
    public static func zoneSeconds(_ r: SessionRecord, zones: HeartZoneSettings) -> [Double] {
        var out = Array(repeating: 0.0, count: 6)
        let active = activeIntervals(r)
        guard let readings = r.heartRateReadings?.sorted(by: { $0.t < $1.t }), !readings.isEmpty else {
            var time = ZoneTimeAccumulator()
            for s in r.samples {
                if s.paused { time.interrupt() } else { time.add(zone: s.hr.map { zones.zone(for: $0) }, at: s.t) }
            }
            return time.seconds
        }
        for (i, h) in readings.enumerated() {
            let next = i + 1 < readings.count ? readings[i + 1].t : h.t + zoneHoldSeconds
            let a = h.t, b = min(next, h.t + zoneHoldSeconds)
            guard b > a else { continue }
            var covered = 0.0
            for iv in active {
                let lo = max(a, iv.start), hi = min(b, iv.end)
                if hi > lo { covered += hi - lo }
            }
            let z = zones.zone(for: h.bpm)
            if covered > 0, out.indices.contains(z) { out[z] += covered }
        }
        return out
    }

    private static func zone(of bpm: Int, in r: SessionRecord) -> Int? {
        r.zoneSettings?.zone(for: bpm)
    }

    /// Statistiques par phase, dans l'ordre d'exécution.
    public static func phaseStats(_ r: SessionRecord) -> [PhaseStats] {
        guard let spans = r.phaseSpans, !spans.isEmpty else { return [] }
        let sessionEnd = r.samples.last?.t ?? 0
        var out: [PhaseStats] = []
        for (i, span) in spans.enumerated() {
            let end = span.end ?? (i + 1 < spans.count ? spans[i + 1].start : sessionEnd)
            var st = PhaseStats(index: span.index, name: span.name, kind: span.kind, start: span.start, end: end,
                                targetSpeedKmh: span.targetSpeedKmh, endSpeedKmh: span.endSpeedKmh, auto: span.auto ?? false,
                                targetZone: span.targetZone, secondsWithHR: 0)
            var sSum = 0.0, sTime = 0.0, hSum = 0.0, hTime = 0.0, inZone = 0.0
            var mxS: Double?, mxH: Int?
            for (k, s) in r.samples.enumerated() where s.t >= span.start && s.t < end && !s.paused {
                let dt = k + 1 < r.samples.count ? max(0, min(r.samples[k + 1].t - s.t, 5)) : 1
                if let v = s.speed { sSum += v * dt; sTime += dt; mxS = max(mxS ?? v, v) }
                if let h = s.hr {
                    hSum += Double(h) * dt
                    hTime += dt
                    mxH = max(mxH ?? h, h)
                    if let tz = span.targetZone, (s.zone ?? zone(of: h, in: r)) == tz { inZone += dt }
                }
            }
            st.avgSpeed = sTime > 0 ? sSum / sTime : nil
            st.maxSpeed = mxS
            st.avgHR = hTime > 0 ? Int((hSum / hTime).rounded()) : nil
            st.maxHR = mxH
            st.secondsWithHR = hTime
            st.secondsInTargetZone = span.targetZone != nil && hTime > 0 ? inZone : nil
            st.hrAtEnd = heartRate(at: end - 1, in: r)
            let nextSlower = i + 1 < spans.count ? spans[i + 1].targetSpeedKmh < span.targetSpeedKmh - 0.05 : true
            if nextSlower, let h0 = st.hrAtEnd, let h60 = heartRate(at: end + 60, in: r) {
                st.recoveryDrop60 = h0 - h60
            }
            out.append(st)
        }
        return out
    }

    /// FC à l'arrêt de la bande, puis 60 et 120 s après.
    public static func postStopRecovery(_ r: SessionRecord) -> PostStopRecovery? {
        guard let stop = r.beltStopDate, let readings = r.heartRateReadings, !readings.isEmpty else { return nil }
        let t0 = stop.timeIntervalSince(r.startDate)
        guard let h0 = heartRate(at: t0, in: r) else { return nil }
        return PostStopRecovery(hrAtStop: h0, hrAfter60: heartRate(at: t0 + 60, in: r), hrAfter120: heartRate(at: t0 + 120, in: r, tolerance: 8))
    }

    /// Vitesse de départ apprise pour la phase pilotée d'un programme : vitesse mesurée pendant
    /// que la FC était dans la zone visée, lors de la séance la plus récente du même programme
    /// (même `templateID`, ou même programme personnel) qui y a passé au moins 2 minutes.
    /// `records` doivent avoir les zones à jour (réglages actuels).
    public static func learnedAutoStart(for program: WorkoutProgram, records: [SessionRecord]) -> Double? {
        guard let zone = program.schedule.first(where: { $0.phase.isAuto })?.phase.autoSpeed?.targetZone else { return nil }
        let same = records.filter { r in
            guard !r.simulated, let p = r.program, p.hasAutoSpeed else { return false }
            if let t = program.templateID { return (r.templateID ?? p.templateID) == t }
            return p.id == program.id
        }
        for r in same.sorted(by: { $0.startDate > $1.startDate }) {
            let f = zoneFocus(r, zone: zone)
            guard let v = f.speedInZone, let frac = f.autoPhaseFraction, frac * f.autoPhaseSeconds >= 120 else { continue }
            return (v * 10).rounded() / 10
        }
        return nil
    }

    /// Bilan « zone visée » : part de temps en zone, vitesse nécessaire, ajustements.
    public static func zoneFocus(_ r: SessionRecord, zone: Int) -> ZoneFocusSummary {
        let total = r.zoneSeconds.reduce(0, +)
        let sessionFraction = total > 0 && zone < r.zoneSeconds.count ? r.zoneSeconds[zone] / total : nil
        let autoSpans = (r.phaseSpans ?? []).filter { $0.auto == true }
        let sessionEnd = r.samples.last?.t ?? 0
        var autoHR = 0.0, autoIn = 0.0, autoTime = 0.0, spSum = 0.0, spTime = 0.0
        for (k, s) in r.samples.enumerated() where !s.paused {
            guard autoSpans.contains(where: { s.t >= $0.start && s.t < ($0.end ?? sessionEnd) }) else { continue }
            let dt = k + 1 < r.samples.count ? max(0, min(r.samples[k + 1].t - s.t, 5)) : 1
            autoTime += dt
            guard let h = s.hr else { continue }
            autoHR += dt
            if (s.zone ?? self.zone(of: h, in: r)) == zone {
                autoIn += dt
                if let v = s.speed { spSum += v * dt; spTime += dt }
            }
        }
        let adj = r.autoAdjustments ?? []
        return ZoneFocusSummary(zone: zone, sessionFraction: sessionFraction,
                                autoPhaseFraction: autoHR > 0 ? autoIn / autoHR : nil, autoPhaseSeconds: autoTime,
                                speedInZone: spTime > 0 ? spSum / spTime : nil,
                                adjustments: adj.count,
                                increases: adj.filter { $0.kind == .increase }.count,
                                decreases: adj.filter { $0.kind == .decrease }.count,
                                safetySteps: adj.filter { $0.kind == .safety }.count)
    }
}

// MARK: - Comparaison dans le temps

/// Une séance vue pour la comparaison entre séances du même protocole.
public struct ProgressEntry: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var programName: String
    public var signature: String
    public var isAuto: Bool
    /// Séance utilisable pour mesurer une progression (protocole respecté).
    public var comparable: Bool
    public var notComparableReasons: [String]
    public var avgHR: Int?
    public var maxHR: Int?
    /// Programmes à vitesse fixe : FC moyenne sur la fin de la phase principale (régime stable).
    public var referenceHR: Int?
    public var referenceLabel: String?
    public var avgSpeed: Double?
    public var maxSpeed: Double?
    /// Programmes pilotés : part du temps en zone visée et vitesse nécessaire pour y rester.
    public var targetZone: Int?
    public var zoneFraction: Double?
    public var speedInZone: Double?
    public var autoAdjustments: Int?
    /// Baisse de FC 60 s après l'arrêt de la bande.
    public var recoveryDrop60: Int?
}

/// Séances d'un même protocole (même empreinte), de la plus ancienne à la plus récente.
public struct ProgressGroup: Equatable, Sendable, Identifiable {
    public var signature: String
    public var name: String
    public var isAuto: Bool
    public var entries: [ProgressEntry]
    public var id: String { signature }

    public var comparableEntries: [ProgressEntry] { entries.filter(\.comparable) }

    /// Tendance lisible : dernière séance comparable contre la moyenne des (au plus) 3 précédentes.
    public var trend: String? {
        let c = comparableEntries
        guard c.count >= 2, let last = c.last else { return nil }
        let previous = c.dropLast().suffix(3)
        if isAuto {
            let prev = previous.compactMap(\.speedInZone)
            guard let v = last.speedInZone, !prev.isEmpty else { return nil }
            let d = v - prev.reduce(0, +) / Double(prev.count)
            let verdict = d > 0.05 ? "plus rapide à même intensité : progression" : d < -0.05 ? "plus lente qu'avant" : "stable"
            return String(format: "Vitesse en zone %d : %.1f km/h (%+.1f vs les %d précédentes) — %@",
                          last.targetZone ?? 2, v, d, prev.count, verdict)
        }
        let prev = previous.compactMap(\.referenceHR)
        guard let h = last.referenceHR, !prev.isEmpty else { return nil }
        let d = Double(h) - Double(prev.reduce(0, +)) / Double(prev.count)
        let verdict = d < -1 ? "FC plus basse à effort identique : progression" : d > 1 ? "FC plus haute qu'avant (fatigue, chaleur, sommeil ?)" : "stable"
        return String(format: "FC de référence : %d bpm (%+.0f vs les %d précédentes) — %@", h, d, prev.count, verdict)
    }
}

public enum ProgressAnalysis {
    /// Durée de la fenêtre de référence (fin de la phase principale).
    public static let referenceWindow: Double = 600

    public static func entry(for r: SessionRecord) -> ProgressEntry? {
        guard let sig = r.programSignature, let program = r.program else { return nil }
        let isAuto = program.hasAutoSpeed
        var reasons: [String] = []
        if r.simulated { reasons.append("simulée") }
        if r.interrupted { reasons.append("interrompue") }
        if (r.manualChanges ?? 0) > 0 { reasons.append("consignes modifiées pendant la séance") }
        if (r.skippedPhases ?? 0) > 0 { reasons.append("phase passée") }
        if r.activeSeconds < Double(program.totalDurationSeconds) * 0.95 { reasons.append("séance incomplète") }

        var e = ProgressEntry(id: r.id, date: r.beltStartDate ?? r.startDate, programName: r.title, signature: sig,
                              isAuto: isAuto, comparable: true, notComparableReasons: [], avgHR: r.avgHR, maxHR: r.maxHR,
                              avgSpeed: r.avgSpeed, maxSpeed: r.maxSpeed,
                              recoveryDrop60: SessionAnalysis.postStopRecovery(r)?.drop60)
        if isAuto {
            let zone = program.schedule.first { $0.phase.isAuto }?.phase.autoSpeed?.targetZone ?? 2
            let f = SessionAnalysis.zoneFocus(r, zone: zone)
            e.targetZone = zone
            e.zoneFraction = f.autoPhaseFraction
            e.speedInZone = f.speedInZone
            e.autoAdjustments = f.adjustments
            if f.speedInZone == nil { reasons.append("pas assez de FC en zone") }
        } else if let ref = referenceHR(r) {
            e.referenceHR = ref.bpm
            e.referenceLabel = ref.label
        } else {
            reasons.append("FC insuffisante sur la phase principale")
        }
        e.notComparableReasons = reasons
        e.comparable = reasons.isEmpty
        return e
    }

    /// FC moyenne sur les 10 dernières minutes (au plus la moitié) de la phase principale :
    /// la plus longue phase à vitesse fixe.
    static func referenceHR(_ r: SessionRecord) -> (bpm: Int, label: String)? {
        let stats = SessionAnalysis.phaseStats(r).filter { !$0.auto && $0.endSpeedKmh == nil }
        guard let main = stats.max(by: { $0.duration < $1.duration }), main.duration >= 120 else { return nil }
        let window = min(referenceWindow, main.duration / 2)
        let from = main.end - window
        var sum = 0.0, time = 0.0
        for (k, s) in r.samples.enumerated() where s.t >= from && s.t < main.end && !s.paused {
            guard let h = s.hr else { continue }
            let dt = k + 1 < r.samples.count ? max(0, min(r.samples[k + 1].t - s.t, 5)) : 1
            sum += Double(h) * dt
            time += dt
        }
        guard time >= window * 0.8 else { return nil }
        let label = String(format: "FC moyenne des %d dernières min de « %@ » (%.1f km/h)",
                           Int((window / 60).rounded()), main.name, main.targetSpeedKmh)
        return (Int((sum / time).rounded()), label)
    }

    /// Regroupe les séances par protocole ; groupes triés par séance la plus récente.
    public static func groups(_ records: [SessionRecord]) -> [ProgressGroup] {
        var bySig: [String: [ProgressEntry]] = [:]
        for r in records {
            guard let e = entry(for: r) else { continue }
            bySig[e.signature, default: []].append(e)
        }
        return bySig.map { sig, list in
            let sorted = list.sorted { $0.date < $1.date }
            return ProgressGroup(signature: sig, name: sorted.last?.programName ?? "Programme",
                                 isAuto: sorted.last?.isAuto ?? false, entries: sorted)
        }
        .sorted { ($0.entries.last?.date ?? .distantPast) > ($1.entries.last?.date ?? .distantPast) }
    }
}
