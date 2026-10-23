import Foundation
import TreadCore

/// Scénarios de test dans le simulateur, pilotés par les arguments de lancement (scripts/sim).
/// Sans `-FouleeScenario`, rien ne change dans l'app.
///
/// - `-FouleeTestPrograms` : ajoute des programmes courts (« Test Zone 2 Auto », « Test enchaînement ») ;
/// - `-FouleeSimHR` : FC simulée (dépend de la vitesse du tapis simulé), comme une ceinture ;
/// - `-FouleeStartProgram <nom>` : démarre ce programme dès que le tapis simulé est prêt ;
/// - `-FouleeScript "pause@40,resume@55,linkloss@60,reconnect@75,manual@90,autopilot@100,hrgap@120-160,stop@200"` ;
/// - `-FouleeTab <n>` / `-FouleeOpen program:<nom> | history:last | progress` : écran à afficher ;
/// - `-FouleeAppearance system|dark`.
///
/// Un rapport est écrit chaque seconde dans Documents/scenario/phone.json.
final class ScenarioRunner {
    private static let storedKey = "foulee.scenario.args"
    private static let storedAtKey = "foulee.scenario.at"

    /// Arguments du scénario. Une relance de l'app par iOS (message de la montre, arrière-plan)
    /// n'a pas d'arguments : on reprend alors ceux du dernier lancement de test, pendant 20 min.
    static let args: [String] = {
        let launch = ProcessInfo.processInfo.arguments
        let d = UserDefaults.standard
        if launch.contains("-FouleeScenario") {
            d.set(launch, forKey: storedKey)
            d.set(Date(), forKey: storedAtKey)
            return launch
        }
        if let stored = d.array(forKey: storedKey) as? [String], let at = d.object(forKey: storedAtKey) as? Date,
           Date().timeIntervalSince(at) < 20 * 60 {
            return stored + ["-FouleeRelaunched"]
        }
        return launch
    }()
    static var isActive: Bool { args.contains("-FouleeScenario") }

    static func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    struct Report: Encodable {
        struct Adjustment: Encodable { var t: Double; var from: Double; var to: Double; var kind: String; var bpm: Int? }
        struct Final: Encodable {
            var title: String
            var activeSeconds: Double
            var phaseSpans: Int
            var autoAdjustments: Int
            var manualChanges: Int
            var avgHR: Int?
            var hrSources: [String]
            var zoneSeconds: [Double]
            var comparable: Bool?
        }
        var scenario: String
        var statuses: [String] = []
        var phases: [String] = []
        var requestedSpeeds: [Double] = []
        var maxBeltSpeed = 0.0
        var autopilotModes: [String] = []
        var adjustments: [Adjustment] = []
        var alerts: [String] = []
        var watchStartRequests = 0
        var watchControls: [String] = []
        var watchHeartRates = 0
        var simulatedHeartRates = 0
        var hrSources: [String] = []
        var linkLossPaused: Bool?
        var requestedSpeedIncreasedWhileLinkLost = false
        var startCommandsAfterLinkLoss = 0
        var statusAfterReconnect: String?
        var finished: Final?
        var watchPaired = false
        var watchAppInstalled = false
        var watchReachable = false
        /// Lancements de l'app pendant le scénario (relance par iOS comprise).
        var launches: [String] = []
        var log: [String] = []
        var updatedAt = Date()
    }

    private unowned let model: AppModel
    private var report: Report
    private var timer: Timer?
    private var startedAt: Date?
    private var script: [(action: String, t: Double, arg: String?)] = []
    private var done = Set<Int>()
    /// 5,8 km/h → 131 bpm (sous Z2), 6,2 → 137 (dans Z2 = 135–148).
    private var heart = SimulatedHeartModel(restBPM: 38)
    private var hrGap: ClosedRange<Double>?
    private var lastWatchHR: TimeInterval?
    private var linkLostAt: Date?
    private var speedAtLinkLoss: Double?
    private var startRequested = false

    init(model: AppModel) {
        self.model = model
        report = Report(scenario: Self.value("-FouleeScenario") ?? "?")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("scenario/phone.json")
        if Self.args.contains("-FouleeRelaunched"), let url = dir, let data = try? Data(contentsOf: url),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let launches = old["launches"] as? [String], old["scenario"] as? String == report.scenario {
            report.launches = launches
        }
        report.launches.append("\(ISO8601DateFormatter().string(from: Date())) pid \(ProcessInfo.processInfo.processIdentifier)"
                               + (Self.args.contains("-FouleeRelaunched") ? " (relance par iOS, sans arguments)" : ""))
        model.log.onAppend = { [weak self] e in
            guard let self else { return }
            if e.category == .tx, e.message.hasPrefix("Start"), self.linkLostAt != nil { self.report.startCommandsAfterLinkLoss += 1 }
            if e.category == .watch || e.category == .session || e.category == .warning || e.category == .error {
                self.report.log.append("\(Int(e.date.timeIntervalSince1970)) [\(e.category.rawValue)] \(e.message)")
                if e.message.contains("Démarrage demandé depuis la Watch") { self.report.watchStartRequests += 1 }
                if e.message.hasPrefix("Commande depuis la Watch") { self.report.watchControls.append(e.message) }
            }
        }
        if let s = Self.value("-FouleeScript") {
            script = s.split(separator: ",").compactMap { item -> (action: String, t: Double, arg: String?)? in
                let p = item.split(separator: "@", maxSplits: 1).map(String.init)
                guard p.count == 2 else { return nil }
                if p[0] == "hrgap" {
                    let r = p[1].split(separator: "-").compactMap { Double($0) }
                    return r.count == 2 ? ("hrgap", r[0], p[1]) : nil
                }
                guard let t = Double(p[1]) else { return nil }
                return (p[0], t, nil)
            }
            if let g = script.first(where: { $0.action == "hrgap" }), let a = g.arg {
                let r = a.split(separator: "-").compactMap { Double($0) }
                hrGap = r[0]...r[1]
            }
        }
    }

    /// Réglages des tests : tapis simulé, pas de demande Santé, zones connues (Z2 = 135–148 bpm).
    func configure() {
        var s = model.settings
        s.simulatorMode = true
        s.didRequestHealthAuthorization = true
        s.startWatchWorkoutWithSession = false
        s.session.zones = HeartZoneSettings(maxHR: 185, restingHR: 60, maxHRIsUserValue: true, restingHRIsUserValue: true,
                                            maxHRSource: "test", restingHRSource: "test")
        if let a = Self.value("-FouleeAppearance") { s.appearance = a == "system" ? .system : .dark }
        model.settings = s
        if Self.args.contains("-FouleeTestPrograms") { installTestPrograms() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    static var testPrograms: [WorkoutProgram] {
        var auto = AutoSpeedSettings()
        auto.minKmh = 4
        auto.maxKmh = 7
        return [
            WorkoutProgram(name: "Test Zone 2 Auto", notes: "Programme court de test (simulateur).", items: [
                .phase(.init(name: "Échauffement progressif", kind: .warmup, durationSeconds: 30, speedKmh: 4.0, endSpeedKmh: 5.5)),
                .phase(.init(name: "Zone 2 pilotée", kind: .steady, durationSeconds: 300, speedKmh: 5.8, targetZone: 2, autoSpeed: auto)),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 30, speedKmh: 4.0, endSpeedKmh: 3.5)),
            ]),
            WorkoutProgram(name: "Test enchaînement", notes: "Programme court de test (simulateur).", items: [
                .phase(.init(name: "Marche", kind: .warmup, durationSeconds: 30, speedKmh: 4.0)),
                .block(.init(name: "Intervalles", repeatCount: 2, phases: [
                    .init(name: "Rapide", kind: .work, durationSeconds: 30, speedKmh: 7.0, targetZone: 4),
                    .init(name: "Lent", kind: .recovery, durationSeconds: 20, speedKmh: 5.0),
                ])),
                .phase(.init(name: "Retour au calme", kind: .cooldown, durationSeconds: 20, speedKmh: 3.5)),
            ]),
        ]
    }

    private func installTestPrograms() {
        let existing = Set(model.dataStore.allPrograms().map(\.name))
        for p in Self.testPrograms where !existing.contains(p.name) { model.dataStore.upsert(p) }
    }

    private func tick() {
        let tm = model.treadmill
        report.watchPaired = model.watch.isWatchPaired
        report.watchAppInstalled = model.watch.isAppInstalled
        report.watchReachable = model.watch.isReachable
        if let p = Self.value("-FouleeStartProgram"), !startRequested, tm.connection.isReady, !model.hasActiveSession {
            startRequested = true
            let program = model.dataStore.allPrograms().first { $0.name == p }
            model.prepareSession(program: program)
            if let e = model.startSession() { report.log.append("démarrage refusé : \(e)") }
        }
        guard let s = model.sessionService?.session else { write(); return }
        let status = describe(s.status)
        if report.statuses.last != status { report.statuses.append(status) }
        if startedAt == nil, s.status == .running { startedAt = Date() }
        if let name = s.currentPhase?.displayName, s.status == .running, report.phases.last != name { report.phases.append(name) }
        if let r = tm.speed.requested, report.requestedSpeeds.last.map({ abs($0 - r) > 0.001 }) ?? true {
            if let lost = speedAtLinkLoss, linkLostAt != nil, r > lost + 0.001 { report.requestedSpeedIncreasedWhileLinkLost = true }
            report.requestedSpeeds.append(r)
        }
        report.maxBeltSpeed = max(report.maxBeltSpeed, tm.simulatedBeltSpeed ?? 0)
        if let a = s.autopilot, s.isAutoPhase {
            let m = "\(a.mode)"
            if report.autopilotModes.last != m { report.autopilotModes.append(m) }
        }
        report.adjustments = (s.record.autoAdjustments ?? []).map {
            .init(t: $0.t, from: $0.fromKmh, to: $0.toKmh, kind: $0.kind.rawValue, bpm: $0.filteredBPM)
        }
        if let a = s.lastAlert, report.alerts.last != a { report.alerts.append(a) }
        if let w = model.heartRate.monitor.latest[.appleWatch], w.receivedAt != lastWatchHR {
            lastWatchHR = w.receivedAt
            report.watchHeartRates += 1
        }
        if let src = model.heartRate.monitor.activeSource?.label, !report.hrSources.contains(src) { report.hrSources.append(src) }
        if linkLostAt != nil, report.linkLossPaused == nil, s.status != .running {
            report.linkLossPaused = s.status == .paused(.connectionLost)
        }
        simulateHeart(s)
        runScript(s)
        if s.status == .finished, report.finished == nil {
            let r = s.record
            report.finished = .init(title: r.title, activeSeconds: r.activeSeconds, phaseSpans: r.phaseSpans?.count ?? 0,
                                    autoAdjustments: r.autoAdjustments?.count ?? 0, manualChanges: r.manualChanges ?? 0,
                                    avgHR: r.avgHR, hrSources: r.hrSources.map(\.label), zoneSeconds: r.zoneSeconds,
                                    comparable: ProgressAnalysis.entry(for: r)?.comparable)
        }
        write()
    }

    private func simulateHeart(_ s: WorkoutSession) {
        guard Self.args.contains("-FouleeSimHR"), s.status != .ready else { return }
        let bpm = heart.advance(dt: 1, speedKmh: model.treadmill.simulatedBeltSpeed ?? 0,
                                inclinePercent: model.treadmill.telemetry.inclinePercent ?? 0)
        if let start = startedAt, let gap = hrGap, gap.contains(Date().timeIntervalSince(start)) { return }
        model.heartRate.ingestSimulated(bpm: bpm)
        report.simulatedHeartRates += 1
    }

    private func runScript(_ s: WorkoutSession) {
        guard let start = startedAt else { return }
        let t = Date().timeIntervalSince(start)
        for (i, step) in script.enumerated() where !done.contains(i) && t >= step.t && step.action != "hrgap" {
            done.insert(i)
            report.log.append("script \(step.action) à \(Int(t)) s")
            switch step.action {
            case "pause": model.pauseSession()
            case "resume":
                // Reprise explicite : fin de la fenêtre « après perte de lien » du rapport.
                linkLostAt = nil
                _ = model.resumeSession()
            case "stop": model.stopSession()
            case "manual": _ = s.adjustSpeed(by: 0.5)
            case "autopilot": s.resumeAutopilot()
            case "linkloss":
                linkLostAt = Date()
                speedAtLinkLoss = model.treadmill.speed.requested
                model.treadmill.simulateLinkLoss()
            case "reconnect":
                model.treadmill.simulateReconnect()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, let s = self.model.sessionService?.session else { return }
                    self.report.statusAfterReconnect = self.describe(s.status)
                }
            default: break
            }
        }
    }

    private func describe(_ s: WorkoutSession.Status) -> String {
        switch s {
        case .ready: return "ready"
        case .starting: return "starting"
        case .running: return "running"
        case .resuming: return "resuming"
        case let .paused(r):
            switch r {
            case .user: return "paused(user)"
            case .connectionLost: return "paused(connectionLost)"
            case .machineStopped: return "paused(machine)"
            }
        case .finished: return "finished"
        }
    }

    private func write() {
        report.updatedAt = Date()
        if report.log.count > 400 { report.log.removeFirst(report.log.count - 400) }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("scenario", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(report) { try? data.write(to: dir.appendingPathComponent("phone.json")) }
    }
}
