import Foundation
import TreadCore

/// Scénarios de test dans le simulateur, pilotés par les arguments de lancement
/// (scripts/sim). Sans `-FouleeScenario`, rien ne change dans l'app.
///
/// - `-FouleeSimulated` : exercice sans HealthKit, FC calculée depuis la vitesse du tapis ;
/// - `-FouleeDemo` : catalogue de démonstration (programmes prédéfinis) si l'iPhone n'a rien envoyé ;
/// - `-FouleeDemoLive` : séance de démonstration affichée sans iPhone (captures) ;
/// - `-FouleeAutoStart <nom>` : sélectionne et lance ce programme dès que l'iPhone est prêt ;
/// - `-FouleeScript "pause@40,resume@55,stop@150"` : commandes, en secondes après le départ ;
/// - `-FouleeHRGap "a-b"` : coupure de la FC simulée entre a et b secondes ;
/// - `-FouleeOpen <nom>` / `-FouleePage <n>` : écran à afficher.
enum WatchScenario {
    static let args = ProcessInfo.processInfo.arguments

    static func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func intValue(_ key: String) -> Int? { value(key).flatMap { Int($0) } }

    struct Report: Encodable {
        var scenario: String
        var events: [String] = []
        var programsReceived = 0
        var programNames: [String] = []
        var phoneReachable = false
        var treadmillReady = false
        var startRequested = false
        var startAccepted: Bool?
        var startMessage: String?
        var liveCount = 0
        var states: [String] = []
        var phases: [String] = []
        var targetSpeeds: [Double] = []
        var heartRatesSent = 0
        var commandsReceived: [String] = []
        var controlsSent: [String] = []
        var workoutEnded = false
        var updatedAt = Date()
    }

    private static var report = Report(scenario: "")
    private static var timers: [Timer] = []

    private static var started = false

    static func start(_ m: WorkoutManager) {
        guard !started, let name = value("-FouleeScenario") else { return }
        started = true
        report = Report(scenario: name)
        m.onEvent = { record($0, m) }
        if let gap = value("-FouleeHRGap"), let parts = Optional(gap.split(separator: "-").compactMap { Double($0) }), parts.count == 2 {
            m.simulatedHeartGap = parts[0]...parts[1]
        }
        if args.contains("-FouleeDemo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if m.programs.isEmpty { m.apply(context: demoContext()) }
            }
        }
        if args.contains("-FouleeDemoLive") { startDemoLive(m) }
        if let program = value("-FouleeAutoStart") { autoStart(program, m, deadline: Date().addingTimeInterval(120)) }
        if let script = value("-FouleeScript") { runScript(script, m) }
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in write(m) }
        timers.append(t)
    }

    private static func record(_ e: String, _ m: WorkoutManager) {
        if e == "hr" { report.heartRatesSent += 1; return }
        if e.hasPrefix("live:") {
            report.liveCount += 1
            let parts = e.split(separator: ":", maxSplits: 3).map(String.init)
            if parts.count >= 4 {
                if report.states.last != parts[1] { report.states.append(parts[1]) }
                if parts[2] != "-", report.phases.last != parts[2] { report.phases.append(parts[2]) }
                if let v = Double(parts[3]), report.targetSpeeds.last != v { report.targetSpeeds.append(v) }
            }
            return
        }
        if e.hasPrefix("context:") { report.programsReceived = Int(e.dropFirst(8)) ?? 0 }
        if e.hasPrefix("startRequest") { report.startRequested = true }
        if e.hasPrefix("startResult:") { report.startAccepted = e.hasSuffix("true") }
        if e.hasPrefix("command:") { report.commandsReceived.append(String(e.dropFirst(8))) }
        if e.hasPrefix("control:") { report.controlsSent.append(String(e.dropFirst(8))) }
        if e == "ended" { report.workoutEnded = true }
        report.events.append("\(Int(Date().timeIntervalSince1970)) \(e)")
    }

    private static func write(_ m: WorkoutManager) {
        report.programNames = m.programs.map(\.name)
        report.programsReceived = m.programs.count
        report.phoneReachable = m.phoneReachable
        report.treadmillReady = m.context?.treadmill.ready ?? false
        if case let .refused(why) = m.launch { report.startMessage = why }
        if case .ended = m.phase { report.workoutEnded = true }
        report.updatedAt = Date()
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("scenario", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(report) { try? data.write(to: dir.appendingPathComponent("watch.json")) }
    }

    /// Lance le programme dès que l'iPhone a publié son catalogue et que le tapis est prêt
    /// (équivaut à : choisir le programme, « Démarrer », confirmer).
    private static func autoStart(_ name: String, _ m: WorkoutManager, deadline: Date) {
        if let p = m.programs.first(where: { $0.name == name }), m.phoneReachable, m.context?.treadmill.ready == true {
            m.startProgram(p)
            return
        }
        if Date() > deadline {
            report.startMessage = "programme « \(name) » ou tapis indisponible après 120 s (programmes reçus : \(m.programs.count), iPhone joignable : \(m.phoneReachable))"
            return
        }
        if Int(deadline.timeIntervalSinceNow) % 10 == 0 { m.requestContext() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { autoStart(name, m, deadline: deadline) }
    }

    /// Commandes datées relativement au début de l'exercice de la montre.
    private static func runScript(_ script: String, _ m: WorkoutManager) {
        let actions: [(String, Double)] = script.split(separator: ",").compactMap { item in
            let p = item.split(separator: "@")
            guard p.count == 2, let t = Double(p[1]) else { return nil }
            return (String(p[0]), t)
        }
        func waitForStart() {
            guard let start = m.startDate, m.isActive else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitForStart() }
                return
            }
            for (action, t) in actions {
                let delay = max(0, start.addingTimeInterval(t).timeIntervalSinceNow)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    record("script:\(action)", m)
                    switch action {
                    case "pause": m.requestPause()
                    case "resume": m.requestResume()
                    case "stop": m.requestStop()
                    case "autopilot": m.requestAutopilot()
                    default: break
                    }
                }
            }
        }
        waitForStart()
    }

    static func demoContext() -> WatchPhoneContext {
        WatchPhoneContext(programs: WorkoutProgram.templates.map(WatchProgramSummary.init),
                          treadmill: WatchTreadmillBrief(name: "URTM047", ready: true, simulated: true, label: "Démo"),
                          activeSessionID: nil, activeProgramName: nil,
                          zoneBounds: HeartZoneSettings(maxHR: 185, restingHR: 60).bounds, sentAt: Date(timeIntervalSince1970: 0))
    }

    /// Séance de démonstration sans iPhone (captures d'écran de la séance en cours).
    private static func startDemoLive(_ m: WorkoutManager) {
        let bounds = HeartZoneSettings(maxHR: 185, restingHR: 60).bounds
        m.apply(context: demoContext())
        Task { @MainActor in await m.start(activity: .walking) }
        var t = 600.0
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            t += 1
            m.injectDemo(live: WatchLiveStatus(
                state: .running, stateLabel: "En cours", programName: "Zone 2 Auto", activeSeconds: t,
                speedKmh: 6.2, inclinePercent: 0, targetSpeedKmh: 6.2, targetInclinePercent: 0,
                phaseName: "Zone 2 pilotée", phaseIndex: 1, phaseCount: 3, phaseRemaining: 1800 - t,
                programRemaining: 2100 - t, nextPhaseName: "Retour au calme",
                zoneBounds: bounds, zoneSeconds: [0, 240, 330, 20, 0, 0], targetZone: 2, phoneHeartRate: 128,
                phoneHeartRateSource: "Watch", phoneZone: 2, autopilotStatus: "Dans la zone : vitesse maintenue",
                autopilotManual: false, sentAt: Date()))
        }
        timers.append(timer)
    }
}
