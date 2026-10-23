import SwiftUI
import TreadCore

/// Séance en cours : gros chiffres, peu de texte, commandes toujours visibles.
struct LiveSessionView: View {
    @Environment(AppModel.self) private var model
    let service: SessionService
    @State private var actionError: String?

    private var snap: SessionSnapshot { service.snapshot }
    private var tm: TreadmillService { model.treadmill }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                banners
                if !snap.isFreeRun { phaseHeader }
                metricsGrid
                manualControls
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom) { mainControls }
        .onChange(of: model.banner) { _, new in
            guard new != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { model.banner = nil }
        }
    }

    // MARK: Bandeaux

    @ViewBuilder private var banners: some View {
        if isLinkLost {
            Banner(text: "Connexion perdue : l'état du tapis est inconnu. Utilisez son bouton ou la clé de sécurité. Rien ne redémarrera sans votre action.",
                   color: Theme.danger, systemImage: "antenna.radiowaves.left.and.right.slash")
        }
        if case let .paused(.machineStopped(reason)) = snap.status {
            Banner(text: "Tapis arrêté (\(reason)). Appuyez sur Reprendre quand vous êtes prêt.", color: Theme.warning)
        }
        if snap.status == .starting || snap.status == .resuming {
            Banner(text: tm.beltState == .startUnconfirmed
                   ? "Start acquitté mais aucun mouvement observé. Aucun nouvel essai automatique."
                   : "Démarrage : \(tm.beltState.label)",
                   color: tm.beltState == .startUnconfirmed ? Theme.danger : Theme.accent,
                   systemImage: tm.beltState == .startUnconfirmed ? "exclamationmark.octagon.fill" : "hourglass")
        }
        if tm.settlingInitialSpeed {
            Banner(text: String(format: "Stabilisation à %.1f km/h avant la consigne du palier", tm.speed.acknowledged ?? 0),
                   color: Theme.accent, systemImage: "hourglass")
        }
        if tm.speed.status == .mismatch, let req = tm.speed.verifying {
            Banner(text: String(format: "Écart vitesse : consigne %.1f %@, mesure %@ km/h", req,
                                tm.speed.unanswered != nil ? "sans réponse" : "acquittée", Format.speed(tm.telemetry.speedKmh))
                   + (tm.speed.machineReported.map { String(format: " · le tapis annonce %.1f", $0) } ?? ""))
        }
        if tm.incline.status == .mismatch, let req = tm.incline.verifying {
            Banner(text: String(format: "Écart inclinaison : consigne %.0f %%, mesure %@ %%", req, Format.incline(tm.telemetry.inclinePercent)))
        }
        if case let .failed(m) = tm.speed.status { Banner(text: "Vitesse : \(m)", color: Theme.danger) }
        if snap.overrideActive {
            Banner(text: "Consigne manuelle jusqu'au prochain palier", color: Theme.speed, systemImage: "hand.raised.fill")
        }
        if let a = model.banner { Banner(text: a, color: Theme.heart, systemImage: "heart.text.square.fill") }
        if let e = actionError { Banner(text: e, color: Theme.danger) }
    }

    private var isLinkLost: Bool {
        if tm.beltState == .linkLost { return true }
        if case .paused(.connectionLost) = snap.status { return true }
        return false
    }

    // MARK: Phase

    private var phaseHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(Theme.phaseColor(snap.currentPhaseKind)).frame(width: 12, height: 12)
                Text(snap.currentPhaseName ?? "—").font(.title3.bold()).lineLimit(1)
                Spacer()
                if let i = snap.phaseIndex { Text("\(i + 1)/\(snap.phaseCount)").font(.subheadline).foregroundStyle(.secondary) }
            }
            if let el = snap.phaseElapsed, let rem = snap.phaseRemaining, el + rem > 0 {
                ProgressView(value: el, total: el + rem).tint(Theme.phaseColor(snap.currentPhaseKind))
            }
            HStack {
                Text("Phase : \(Format.duration(snap.phaseRemaining))").monospacedDigit()
                Spacer()
                if let next = snap.nextPhaseName {
                    Text("Ensuite : \(next) · \(snap.nextPhaseSummary ?? "")").lineLimit(1)
                } else {
                    Text("Dernière phase")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    // MARK: Indicateurs

    private var metricsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            MetricTile(title: "Vitesse réelle", value: Format.speed(freshSpeed), unit: "km/h",
                       detail: speedDetail, color: Theme.speed, large: true)
            MetricTile(title: "Inclinaison réelle", value: Format.incline(freshIncline), unit: "%",
                       detail: inclineDetail, color: Theme.incline, large: true)
            heartTile
            MetricTile(title: "Zone", value: Theme.zoneName(snap.zone), detail: zoneDetail, color: Theme.zoneColor(snap.zone))
            MetricTile(title: "Pas", value: snap.steps.map { "\($0)" } ?? "—",
                       detail: snap.steps == nil ? "aucune source" : snap.stepsSource.label)
            MetricTile(title: "Distance", value: Format.distance(snap.distanceMeters),
                       detail: snap.distanceSource == .estimated ? "calculée depuis la vitesse" : snap.distanceSource.label)
            MetricTile(title: "Temps actif", value: Format.duration(snap.activeTime))
            MetricTile(title: snap.isFreeRun ? "Énergie" : "Restant",
                       value: snap.isFreeRun ? kcalValue : Format.duration(snap.programRemaining),
                       detail: snap.isFreeRun ? kcalDetail : nil)
        }
    }

    private var freshSpeed: Double? {
        tm.telemetry.isFresh(now: MonotonicClock.now()) ? tm.telemetry.speedKmh : nil
    }

    private var freshIncline: Double? {
        tm.telemetry.isFresh(now: MonotonicClock.now()) ? tm.telemetry.inclinePercent : nil
    }

    private var speedDetail: String {
        var s = String(format: "Cible %.1f", snap.targetSpeed)
        if let v = freshSpeed { s += String(format: " · écart %+.1f", v - snap.targetSpeed) }
        switch tm.speed.status {
        case .pending: s += " · envoyée"
        case .acknowledged: s += " · acquittée"
        case .unanswered: s += " · sans réponse"
        case .deferred: s += " · en attente"
        default: break
        }
        return s
    }

    private var inclineDetail: String {
        guard tm.capabilities.supportsInclinationControl else { return "non pilotable" }
        var s = String(format: "Cible %.0f", snap.targetIncline)
        if let v = freshIncline { s += String(format: " · écart %+.1f", v - snap.targetIncline) }
        return s
    }

    @ViewBuilder private var heartTile: some View {
        switch model.heartRate.status {
        case let .live(bpm, source, age):
            MetricTile(title: "Cardio", value: "\(bpm)", unit: "bpm",
                       detail: "\(source.shortLabel) · \(Int(age)) s", color: Theme.zoneColor(snap.zone), large: true)
        case let .stale(bpm, source, age):
            MetricTile(title: "Cardio", value: "—", unit: "bpm",
                       detail: "\(source.shortLabel) : \(bpm) il y a \(Int(age)) s", color: .secondary, large: true,
                       accessibilityValue: "Mesure périmée")
        case .unavailable:
            MetricTile(title: "Cardio", value: "—", unit: "bpm", detail: "indisponible", color: .secondary, large: true)
        }
    }

    private var zoneDetail: String {
        var parts: [String] = []
        if let t = snap.currentTargetZone { parts.append("cible Z\(t)") }
        if let z = snap.zone, z >= 0, z < snap.zoneSeconds.count {
            parts.append(Format.duration(snap.zoneSeconds[z]) + " dans la zone")
        }
        return parts.joined(separator: " · ")
    }

    private var kcalValue: String {
        if let k = snap.watchKcal { return String(format: "%.0f", k) }
        if let k = snap.treadmillKcal { return String(format: "%.0f", k) }
        if let k = snap.estimatedKcal { return String(format: "%.0f", k) }
        return "—"
    }

    private var kcalDetail: String {
        if snap.watchKcal != nil { return "kcal actives (Watch)" }
        if snap.treadmillKcal != nil { return "kcal (tapis)" }
        if snap.estimatedKcal != nil { return "kcal estimées" }
        return "kcal"
    }

    // MARK: Commandes

    private var manualControls: some View {
        VStack(spacing: 10) {
            adjustRow(title: "Vitesse", value: String(format: "%.1f km/h", snap.targetSpeed), color: Theme.speed,
                      minus: { act { try service.session.adjustSpeed(by: -max(tm.capabilities.speed.incrementKmh, 0.1) * 5).get() } },
                      minusSmall: { act { try service.session.adjustSpeed(by: -max(tm.capabilities.speed.incrementKmh, 0.1)).get() } },
                      plusSmall: { act { try service.session.adjustSpeed(by: max(tm.capabilities.speed.incrementKmh, 0.1)).get() } },
                      plus: { act { try service.session.adjustSpeed(by: max(tm.capabilities.speed.incrementKmh, 0.1) * 5).get() } })
            if tm.capabilities.supportsInclinationControl {
                let step = max(tm.capabilities.inclination?.incrementPercent ?? 1, 0.5)
                adjustRow(title: "Inclinaison", value: String(format: "%.0f %%", snap.targetIncline), color: Theme.incline,
                          minus: nil,
                          minusSmall: { act { try service.session.adjustIncline(by: -step).get() } },
                          plusSmall: { act { try service.session.adjustIncline(by: step).get() } },
                          plus: nil)
            }
            if !snap.isFreeRun && snap.nextPhaseName != nil {
                Button {
                    service.session.skipToNextPhase()
                } label: {
                    Label("Phase suivante", systemImage: "forward.end.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func adjustRow(title: String, value: String, color: Color,
                           minus: (() -> Void)?, minusSmall: @escaping () -> Void,
                           plusSmall: @escaping () -> Void, plus: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            if let minus { stepButton("chevron.down.2", label: "\(title) moins 5 crans", action: minus) }
            stepButton("minus", label: "\(title) moins", action: minusSmall)
            VStack(spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            stepButton("plus", label: "\(title) plus", action: plusSmall)
            if let plus { stepButton("chevron.up.2", label: "\(title) plus 5 crans", action: plus) }
        }
    }

    private func stepButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.bold()).frame(width: 48, height: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); actionError = nil } catch { actionError = "\(error)" }
    }

    private var mainControls: some View {
        HStack(spacing: 12) {
            if service.session.isPaused {
                Button {
                    actionError = model.resumeSession()
                } label: {
                    Label("Reprendre", systemImage: "play.fill").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tm.connection.isReady)
            } else {
                Button {
                    model.pauseSession()
                } label: {
                    Label("Pause", systemImage: "pause.fill").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warning)
            }
            Button(role: .destructive) {
                model.stopSession()
            } label: {
                Label("Arrêter", systemImage: "stop.fill").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .accessibilityHint("Arrête le tapis et termine la séance")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

/// Résumé de fin de séance.
struct FinishedSessionView: View {
    @Environment(AppModel.self) private var model
    let service: SessionService

    var body: some View {
        let r = service.session.record
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
                Text("Séance terminée").font(.title.bold())
                if model.treadmill.beltState != .stopped && model.treadmill.beltState != .idle && model.treadmill.beltState != .disconnected {
                    Banner(text: "Arrêt non confirmé par la télémétrie (\(model.treadmill.beltState.label)). Vérifiez le tapis.",
                           color: Theme.danger)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    MetricTile(title: "Temps actif", value: Format.duration(r.activeSeconds))
                    MetricTile(title: "Distance", value: Format.distance(r.distanceMeters))
                    MetricTile(title: "FC moy.", value: r.avgHR.map { "\($0)" } ?? "—", unit: "bpm")
                    MetricTile(title: "Pas", value: r.steps.map { "\($0)" } ?? "—", detail: r.stepsSource.label)
                }
                ZoneBars(seconds: r.zoneSeconds)
                Button {
                    model.closeFinishedSession()
                } label: {
                    Text("Nouvelle séance").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}
