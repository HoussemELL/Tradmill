import SwiftUI
import TreadCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { TreadmillSettingsView() } label: {
                        LabeledContent("Tapis", value: model.treadmill.connection.label)
                    }
                    NavigationLink { HeartRateSettingsView() } label: {
                        LabeledContent("Source cardio", value: model.settings.heartRatePreference.label)
                    }
                    NavigationLink { ZoneSettingsView() } label: {
                        LabeledContent("FC max et zones", value: "\(model.settings.session.zones.maxHR) bpm")
                    }
                    NavigationLink { HealthSettingsView() } label: {
                        LabeledContent("Apple Santé", value: model.settings.health.enabled ? "Activé" : "Désactivé")
                    }
                    NavigationLink { SessionPreferencesView() } label: { Text("Séance, pas et énergie") }
                    NavigationLink { DisplaySettingsView() } label: { Text("Écran et affichage") }
                }
                Section {
                    NavigationLink { DiagnosticView() } label: { Label("Diagnostic et journaux", systemImage: "stethoscope") }
                    NavigationLink { AboutView() } label: { Label("Sécurité et limites", systemImage: "exclamationmark.shield") }
                }
            }
            .navigationTitle("Réglages")
        }
    }
}

struct TreadmillSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Tapis") {
                LabeledContent("État", value: model.treadmill.connection.label)
                if let n = model.settings.lastTreadmillName {
                    LabeledContent("Mémorisé", value: n)
                }
                Button("Rechercher un tapis") { showPicker = true }
                if model.treadmill.connection != .none {
                    Button("Déconnecter", role: .destructive) {
                        model.settings.simulatorMode = false
                        model.treadmill.disconnect()
                    }
                }
                if model.settings.lastTreadmillID != nil {
                    Button("Oublier le tapis mémorisé", role: .destructive) {
                        model.treadmill.disconnect()
                        model.settings.lastTreadmillID = nil
                        model.settings.lastTreadmillName = nil
                    }
                }
            }
            Section {
                Picker("Profil", selection: $model.settings.profileOverrideID) {
                    Text("Automatique (d'après le nom)").tag(String?.none)
                    ForEach(TreadmillProfile.all) { p in Text(p.name).tag(Optional(p.id)) }
                }
                Text(model.treadmill.profile.notes).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Profil matériel") } footer: {
                Text("Le profil est appliqué à la prochaine connexion. Il définit l'ordre des commandes de démarrage, les délais et les tolérances.")
            }
            Section("Capacités lues") {
                let c = model.treadmill.capabilities
                LabeledContent("Vitesse", value: String(format: "%.1f–%.1f km/h (pas %.2f)", c.speed.minKmh, c.speed.maxKmh, c.speed.incrementKmh))
                LabeledContent("Source", value: c.speedRangeFromDevice ? "tapis" : "profil (non lue)")
                if let i = c.inclination {
                    LabeledContent("Inclinaison", value: String(format: "%.0f–%.0f %% (pas %.1f)", i.minPercent, i.maxPercent, i.incrementPercent))
                } else {
                    LabeledContent("Inclinaison", value: "non pilotable")
                }
                if let f = c.feature {
                    Text("Mesures : \(f.machineDescription)").font(.caption)
                    Text("Consignes : \(f.targetDescription)").font(.caption)
                }
                ForEach(model.treadmill.deviceInfo.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    LabeledContent(k, value: v)
                }
            }
            Section {
                Toggle("Mode simulateur", isOn: $model.settings.simulatorMode)
            } footer: {
                Text("Remplace le tapis réel par un tapis FTMS simulé (aucune commande Bluetooth). Les séances sont marquées « Simulé ».")
            }
        }
        .navigationTitle("Tapis")
        .sheet(isPresented: $showPicker) { DevicePickerView(role: .treadmill) }
    }
}

struct HeartRateSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Source", selection: $model.settings.heartRatePreference) {
                    ForEach(HeartRateSourcePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Une seule source est utilisée à la fois ; les mesures de plusieurs sources ne sont jamais mélangées. Une mesure de plus de quelques secondes est affichée comme périmée.")
            }
            Section("Ceinture ou brassard Bluetooth") {
                LabeledContent("État", value: model.heartRate.sensorConnection.label)
                Button("Rechercher un capteur") { showPicker = true }
                if model.heartRate.sensorConnection != .none {
                    Button("Déconnecter", role: .destructive) { model.heartRate.disconnectSensor() }
                }
                if model.settings.lastHeartRateSensorID != nil {
                    Button("Oublier le capteur", role: .destructive) {
                        model.heartRate.disconnectSensor()
                        model.settings.lastHeartRateSensorID = nil
                        model.settings.lastHeartRateSensorName = nil
                    }
                }
            }
            Section {
                LabeledContent("Watch", value: model.watch.linkState.label)
                LabeledContent("App installée", value: model.watch.isAppInstalled ? "Oui" : "Non / inconnu")
                Toggle("Lancer l'exercice Watch avec la séance", isOn: $model.settings.startWatchWorkoutWithSession)
                Toggle("Terminer l'exercice Watch avec la séance", isOn: $model.settings.endWatchWorkoutWithSession)
                Button("Lancer l'exercice sur la Watch maintenant") { model.watch.launchWatchWorkout(running: false) }
            } header: { Text("Apple Watch") } footer: {
                Text("Le cardio Watch provient d'une vraie session d'exercice watchOS envoyée en direct (miroir HealthKit). L'app ne lit jamais d'anciens échantillons Santé pour les présenter comme du direct.")
            }
            Section("Dernières mesures") {
                ForEach(HeartRateSource.allCases, id: \.self) { s in
                    let r = model.heartRate.lastBySource[s]
                    LabeledContent(s.label, value: r.map { "\($0.bpm) bpm, il y a \(Int(MonotonicClock.now() - $0.receivedAt)) s" } ?? "—")
                }
            }
        }
        .navigationTitle("Source cardio")
        .sheet(isPresented: $showPicker) { DevicePickerView(role: .heartRate) }
    }
}

struct ZoneSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let zones = model.settings.session.zones
        Form {
            Section {
                Stepper("FC max : \(zones.maxHR) bpm", value: $model.settings.session.zones.maxHR, in: 100...240)
                Toggle("FC de repos renseignée", isOn: Binding(
                    get: { zones.restingHR != nil },
                    set: { model.settings.session.zones.restingHR = $0 ? 60 : nil }))
                if let rest = zones.restingHR {
                    Stepper("FC de repos : \(rest) bpm", value: Binding(
                        get: { rest }, set: { model.settings.session.zones.restingHR = $0 }), in: 30...120)
                }
                Picker("Méthode", selection: $model.settings.session.zones.method) {
                    ForEach(ZoneMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(zones.methodDescription)
            }
            if zones.effectiveMethod == .customBPM {
                Section("Seuils (bpm)") {
                    ForEach(0..<6, id: \.self) { i in
                        Stepper("\(i < 5 ? "Début Z\(i + 1)" : "Fin Z5") : \(zones.customBounds[i])",
                                value: $model.settings.session.zones.customBounds[i], in: 40...240)
                    }
                }
            } else {
                Section("Bornes (% \(zones.effectiveMethod == .heartRateReserve ? "de réserve" : "de FC max"))") {
                    ForEach(0..<5, id: \.self) { i in
                        Stepper("Début Z\(i + 1) : \(Int((zones.percentBounds[i] * 100).rounded())) %",
                                value: $model.settings.session.zones.percentBounds[i], in: 0.3...1.0, step: 0.01)
                    }
                }
            }
            if let err = zones.validationError() {
                Section { Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
            }
            Section("Zones calculées") {
                ForEach(zones.zones, id: \.zone) { z in
                    HStack {
                        Circle().fill(Theme.zoneColor(z.zone)).frame(width: 12, height: 12)
                        Text("Zone \(z.zone)")
                        Spacer()
                        Text("\(z.lower)–\(z.upper) bpm").monospacedDigit()
                    }
                }
            }
            Section {
                Toggle("Alertes de zone", isOn: $model.settings.session.zoneAlertsEnabled)
                Stepper("Hors zone pendant \(Int(model.settings.session.zoneAlertDwell)) s",
                        value: $model.settings.session.zoneAlertDwell, in: 5...120, step: 5)
                Stepper("Délai entre alertes : \(Int(model.settings.session.zoneAlertCooldown)) s",
                        value: $model.settings.session.zoneAlertCooldown, in: 30...600, step: 15)
                Toggle("Vibration", isOn: $model.settings.hapticAlerts)
            } header: { Text("Alertes") } footer: {
                Text("Une alerte n'est émise qu'après un séjour continu hors de la zone cible de la phase, pour ignorer les oscillations. Pas de pilotage du tapis par la FC en V1.")
            }
        }
        .navigationTitle("Zones cardiaques")
    }
}

struct HealthSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Enregistrer dans Apple Santé", isOn: $model.settings.health.enabled)
                    .disabled(!model.health.isAvailable)
                Button("Demander les autorisations") {
                    Task {
                        _ = await model.health.requestAuthorization()
                        status = model.health.sharingStatusLabel
                    }
                }
                .disabled(!model.health.isAvailable)
                Text(status.isEmpty ? model.health.sharingStatusLabel : status).font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("Autorisations demandées : écriture des exercices, FC, distance et énergie ; lecture des exercices (pour éviter les doublons). L'app reste utilisable si vous refusez.")
            }
            Section {
                Toggle("Écrire la distance du tapis", isOn: $model.settings.health.writeDistance)
                Toggle("Écrire l'énergie annoncée par le tapis", isOn: $model.settings.health.writeTreadmillEnergy)
            } header: { Text("Données écrites par l'iPhone") } footer: {
                Text("""
                Propriétaire unique de l'enregistrement :
                • si un exercice Apple Watch a tourné pendant la séance, c'est la Watch qui l'enregistre (FC, énergie, pas) et l'iPhone n'écrit rien ;
                • sinon l'iPhone enregistre un exercice « marche/course en intérieur » avec la FC de la ceinture et, si activé, la distance.
                Les pas ne sont jamais écrits (l'iPhone et la Watch les comptent déjà). Chaque séance porte un identifiant unique : elle n'est jamais enregistrée deux fois.
                """)
            }
        }
        .navigationTitle("Apple Santé")
    }
}

struct SessionPreferencesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Séance libre") {
                Stepper(String(format: "Vitesse de départ : %.1f km/h", model.settings.session.freeRunStartSpeed),
                        value: $model.settings.session.freeRunStartSpeed, in: 1...8, step: 0.5)
            }
            Section {
                Toggle("Arrêter le tapis en fin de programme", isOn: $model.settings.session.stopTreadmillAtProgramEnd)
            } footer: {
                Text("Désactivé : la dernière consigne est maintenue et vous arrêtez vous-même.")
            }
            Section {
                Toggle("Estimer les pas sans autre source", isOn: $model.settings.session.stepEstimationEnabled)
                Stepper(String(format: "Longueur de pas : %.0f cm", model.settings.session.strideLengthMeters * 100),
                        value: $model.settings.session.strideLengthMeters, in: 0.4...1.4, step: 0.01)
            } header: { Text("Pas") } footer: {
                Text("Priorité : pas fournis par le tapis, puis Apple Watch, puis estimation (affichée « estimée »). Les sources ne sont jamais additionnées. Sans source ni estimation : « — ».")
            }
            Section {
                Toggle("Estimer l'énergie", isOn: Binding(
                    get: { model.settings.session.weightKg != nil },
                    set: { model.settings.session.weightKg = $0 ? 70 : nil }))
                if let w = model.settings.session.weightKg {
                    Stepper("Poids : \(Int(w)) kg", value: Binding(get: { w }, set: { model.settings.session.weightKg = $0 }), in: 30...200)
                }
            } header: { Text("Énergie") } footer: {
                Text("Estimation ACSM (marche/course + pente), distincte des calories du tapis et de celles de l'Apple Watch.")
            }
        }
        .navigationTitle("Séance")
    }
}

struct DisplaySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Écran allumé pendant les programmes", isOn: $model.settings.keepScreenOnDuringPrograms)
                Toggle("Écran allumé pendant les séances libres", isOn: $model.settings.keepScreenOnDuringFreeRun)
            } footer: {
                Text("Recommandé : écran verrouillé, iOS peut ralentir l'app. Les notifications Bluetooth du tapis continuent de faire avancer le programme en arrière-plan, mais sans garantie de régularité.")
            }
            Section("Apparence") {
                Picker("Thème", selection: $model.settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .navigationTitle("Écran")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section("Sécurité") {
                Label("Le bouton Arrêter de l'app ne remplace pas la clé de sécurité physique : gardez-la attachée.", systemImage: "key.fill")
                Label("Le tapis ne démarre que sur une action explicite. Aucune reprise automatique après une reconnexion.", systemImage: "hand.raised.fill")
                Label("En cas de perte Bluetooth, l'état réel du tapis est inconnu : utilisez son bouton ou la clé.", systemImage: "antenna.radiowaves.left.and.right.slash")
                Label("Les diagnostics actifs se lancent hors du tapis, personne dessus.", systemImage: "stethoscope")
            }
            Section("Limites connues") {
                Text("iOS peut suspendre l'app écran verrouillé ; seule l'activité Bluetooth la réveille.")
                Text("Le comptage des pas par le tapis dépend d'un champ non standard (bit 13) ; il est absent sur beaucoup de modèles.")
                Text("Le profil URTM047 repose sur des observations à confirmer sur votre tapis.")
            }
        }
        .navigationTitle("Sécurité et limites")
    }
}
