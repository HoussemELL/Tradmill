import SwiftUI
import TreadCore

/// Recherche et choix d'un tapis FTMS ou d'un capteur cardio.
struct DevicePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let role: BluetoothHub.Role

    private var devices: [BluetoothHub.Discovered] {
        model.bluetooth.discovered.filter { $0.role == role }.sorted { $0.rssi > $1.rssi }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.bluetooth.stateLabel).font(.footnote).foregroundStyle(.secondary)
                }
                Section(role == .treadmill ? "Tapis FTMS à proximité" : "Capteurs cardio à proximité") {
                    if devices.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Recherche…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(devices) { d in
                        Button {
                            if role == .treadmill {
                                model.settings.simulatorMode = false
                                model.treadmill.connect(id: d.id, name: d.name)
                            } else {
                                model.heartRate.connectSensor(id: d.id, name: d.name)
                            }
                            model.bluetooth.stopScan()
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(d.name).font(.headline)
                                    if role == .treadmill {
                                        Text("Profil : \(TreadmillProfile.match(deviceName: d.name).name)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if role == .treadmill {
                    Section {
                        Button {
                            model.settings.simulatorMode = true
                            model.bluetooth.stopScan()
                            dismiss()
                        } label: {
                            Label("Utiliser le simulateur (aucun tapis réel)", systemImage: "cpu")
                        }
                    } footer: {
                        Text("Le simulateur reproduit un tapis FTMS au niveau des octets, avec les particularités supposées de l'URTM047.")
                    }
                }
            }
            .navigationTitle(role == .treadmill ? "Choisir un tapis" : "Choisir un capteur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { model.bluetooth.stopScan(); dismiss() }
                }
            }
            .onAppear { model.bluetooth.startScan(for: role) }
            .onDisappear { model.bluetooth.stopScan() }
        }
    }
}
