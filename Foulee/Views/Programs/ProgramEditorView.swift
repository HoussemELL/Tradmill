import SwiftUI
import TreadCore

/// Édition d'un programme : phases, blocs répétés, réorganisation, aperçu et validation.
struct ProgramEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var program: WorkoutProgram
    let onSave: (WorkoutProgram) -> Void

    @State private var editingPhase: PhaseEditTarget?
    @State private var editingBlockIndex: Int?
    @State private var confirmUnlock = false

    /// Un protocole verrouillé (Cardio Baseline) ne se modifie qu'après déverrouillage explicite.
    private var phasesEditable: Bool { !program.isLocked }

    struct PhaseEditTarget: Identifiable {
        let itemIndex: Int
        let phaseIndex: Int?   // nil = phase simple ; sinon phase d'un bloc
        let phase: ProgramPhase
        var id: String { "\(itemIndex)-\(phaseIndex ?? -1)" }
    }

    init(program: WorkoutProgram, onSave: @escaping (WorkoutProgram) -> Void) {
        _program = State(initialValue: program)
        self.onSave = onSave
    }

    private var structureErrors: [ProgramIssue] {
        ProgramValidator.validateStructure(program).filter { $0.severity == .error }
    }

    private var treadmillIssues: [ProgramIssue] {
        ProgramValidator.validate(program, against: model.treadmill.capabilities)
            .filter { issue in !structureErrors.contains(where: { $0.id == issue.id }) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Programme") {
                    TextField("Nom", text: $program.name)
                    TextField("Notes", text: $program.notes, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    ProgramChart(program: program).frame(height: 140)
                    LabeledContent("Durée totale", value: Format.duration(TimeInterval(program.totalDurationSeconds)))
                    LabeledContent("Phases (blocs déroulés)", value: "\(program.schedule.count)")
                } header: { Text("Aperçu") }
                if phasesEditable { phasesSection } else { lockedSection }
                if !structureErrors.isEmpty || !treadmillIssues.isEmpty {
                    Section("À corriger") {
                        ForEach(structureErrors + treadmillIssues) { i in
                            Label("\(i.phaseName.map { "\($0) : " } ?? "")\(i.message)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle(program.name.isEmpty ? "Programme" : program.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        program.updatedAt = Date()
                        onSave(program)
                        dismiss()
                    }
                    .disabled(!structureErrors.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .alert("Déverrouiller le protocole ?", isPresented: $confirmUnlock) {
                Button("Déverrouiller", role: .destructive) { program.locked = false }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les séances faites après une modification ne seront plus comparées aux précédentes (protocole différent).")
            }
            .sheet(item: $editingPhase) { target in
                PhaseEditorView(phase: target.phase, capabilities: model.treadmill.capabilities) { updated in
                    apply(updated, to: target)
                }
            }
            .sheet(item: Binding(get: { editingBlockIndex.map { BlockIndex(value: $0) } },
                                 set: { editingBlockIndex = $0?.value })) { idx in
                if case let .block(b) = program.items[idx.value] {
                    BlockEditorView(block: b, capabilities: model.treadmill.capabilities) { updated in
                        program.items[idx.value] = .block(updated)
                    }
                }
            }
        }
    }

    private var lockedSection: some View {
        Section {
            ProgramSegmentsView(program: program)
            Button {
                confirmUnlock = true
            } label: {
                Label("Déverrouiller pour modifier", systemImage: "lock.open")
            }
        } header: {
            Label("Protocole de référence verrouillé", systemImage: "lock.fill")
        } footer: {
            Text("Gardé strictement identique pour comparer votre FC à effort égal au fil des semaines. Pour une variante, dupliquez-le plutôt.")
        }
    }

    private var phasesSection: some View {
        Section {
            ForEach(Array(program.items.enumerated()), id: \.element.id) { index, item in
                itemRow(index: index, item: item)
            }
            .onMove { program.items.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { program.items.remove(atOffsets: $0) }
            Menu {
                Button("Échauffement") { addPhase(kind: .warmup) }
                Button("Phase d'effort") { addPhase(kind: .work) }
                Button("Récupération") { addPhase(kind: .recovery) }
                Button("Allure stable") { addPhase(kind: .steady) }
                Button("Retour au calme") { addPhase(kind: .cooldown) }
                Divider()
                Button("Bloc répété") { addBlock() }
            } label: {
                Label("Ajouter", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Phases")
        } footer: {
            Text("Glissez pour réorganiser (bouton Modifier), balayez pour supprimer.")
        }
    }

    struct BlockIndex: Identifiable { let value: Int; var id: Int { value } }

    @ViewBuilder
    private func itemRow(index: Int, item: ProgramItem) -> some View {
        switch item {
        case let .phase(p):
            Button { editingPhase = PhaseEditTarget(itemIndex: index, phaseIndex: nil, phase: p) } label: {
                PhaseRow(phase: p)
            }
        case let .block(b):
            Button { editingBlockIndex = index } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "repeat")
                        Text("\(b.name) × \(b.repeatCount)").font(.headline)
                        Spacer()
                        Text(Format.duration(TimeInterval(item.durationSeconds))).foregroundStyle(.secondary)
                    }
                    ForEach(b.phases) { p in
                        Text("  • \(p.name) \(Format.duration(TimeInterval(p.durationSeconds))) · \(PhaseText.summary(p))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func addPhase(kind: PhaseKind) {
        let caps = model.treadmill.capabilities
        let speed: Double
        switch kind {
        case .warmup, .cooldown: speed = 3.5
        case .recovery: speed = 4.5
        case .steady: speed = 5.0
        case .work: speed = 7.0
        }
        program.items.append(.phase(ProgramPhase(name: kind.label, kind: kind, durationSeconds: kind == .work ? 120 : 300,
                                                 speedKmh: caps.snapSpeed(speed))))
    }

    private func addBlock() {
        let caps = model.treadmill.capabilities
        program.items.append(.block(RepeatBlock(name: "Intervalles", repeatCount: 4, phases: [
            ProgramPhase(name: "Rapide", kind: .work, durationSeconds: 60, speedKmh: caps.snapSpeed(7)),
            ProgramPhase(name: "Lent", kind: .recovery, durationSeconds: 120, speedKmh: caps.snapSpeed(4.5)),
        ])))
    }

    private func apply(_ updated: ProgramPhase, to target: PhaseEditTarget) {
        guard target.itemIndex < program.items.count else { return }
        if target.phaseIndex == nil {
            program.items[target.itemIndex] = .phase(updated)
        }
    }
}

struct PhaseRow: View {
    let phase: ProgramPhase

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 3).fill(Theme.phaseColor(phase.kind)).frame(width: 6)
            VStack(alignment: .leading) {
                Text(phase.name).font(.headline).foregroundStyle(.primary)
                Text(PhaseText.summary(phase))
                    .font(.caption).foregroundStyle(phase.isAuto ? Theme.accent : .secondary)
            }
            Spacer()
            Text(Format.duration(TimeInterval(phase.durationSeconds))).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Édition d'une phase. Les pas de réglage suivent l'incrément du tapis ; la validation
/// complète (plages) est affichée dans l'éditeur du programme.
struct PhaseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var phase: ProgramPhase
    let capabilities: TreadmillCapabilities
    let onSave: (ProgramPhase) -> Void

    init(phase: ProgramPhase, capabilities: TreadmillCapabilities, onSave: @escaping (ProgramPhase) -> Void) {
        _phase = State(initialValue: phase)
        self.capabilities = capabilities
        self.onSave = onSave
    }

    private var minutes: Binding<Int> {
        Binding(get: { phase.durationSeconds / 60 }, set: { phase.durationSeconds = $0 * 60 + phase.durationSeconds % 60 })
    }

    private var seconds: Binding<Int> {
        Binding(get: { phase.durationSeconds % 60 }, set: { phase.durationSeconds = (phase.durationSeconds / 60) * 60 + $0 })
    }

    enum SpeedMode: String, CaseIterable, Identifiable {
        case fixed, ramp, auto
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fixed: return "Fixe"
            case .ramp: return "Progressive"
            case .auto: return "Pilotée par la FC"
            }
        }
    }

    private var speedMode: Binding<SpeedMode> {
        Binding(get: {
            if phase.autoSpeed != nil { return .auto }
            return phase.endSpeedKmh != nil ? .ramp : .fixed
        }, set: { mode in
            switch mode {
            case .fixed:
                phase.endSpeedKmh = nil
                phase.autoSpeed = nil
            case .ramp:
                phase.autoSpeed = nil
                phase.endSpeedKmh = phase.endSpeedKmh ?? phase.speedKmh
            case .auto:
                phase.endSpeedKmh = nil
                let a = phase.autoSpeed ?? AutoSpeedSettings()
                phase.autoSpeed = a
                phase.speedKmh = min(max(phase.speedKmh, a.minKmh), a.maxKmh)
                phase.targetZone = a.targetZone
            }
        })
    }

    private var speedStep: Double { max(capabilities.speed.incrementKmh, 0.1) }

    private func auto<T>(_ kp: WritableKeyPath<AutoSpeedSettings, T>) -> Binding<T> {
        Binding(get: { (phase.autoSpeed ?? AutoSpeedSettings())[keyPath: kp] },
                set: { v in
                    var a = phase.autoSpeed ?? AutoSpeedSettings()
                    a[keyPath: kp] = v
                    phase.autoSpeed = a
                })
    }

    private var autoError: String? { phase.autoSpeed?.validationError() }

    var body: some View {
        NavigationStack {
            Form {
                Section("Phase") {
                    TextField("Nom", text: $phase.name)
                    Picker("Type", selection: $phase.kind) {
                        ForEach(PhaseKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Durée") {
                    Stepper("\(minutes.wrappedValue) min", value: minutes, in: 0...240)
                    Stepper("\(seconds.wrappedValue) s", value: seconds, in: 0...55, step: 5)
                }
                Section {
                    Picker("Vitesse", selection: speedMode) {
                        ForEach(SpeedMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: $phase.speedKmh, in: 0.1...30, step: speedStep) {
                        LabeledContent(phase.endSpeedKmh != nil || phase.autoSpeed != nil ? "Vitesse de départ" : "Vitesse",
                                       value: String(format: "%.1f km/h", phase.speedKmh))
                    }
                    if let end = phase.endSpeedKmh {
                        Stepper(value: Binding(get: { end }, set: { phase.endSpeedKmh = $0 }), in: 0.1...30, step: speedStep) {
                            LabeledContent("Vitesse de fin", value: String(format: "%.1f km/h", end))
                        }
                    }
                    Stepper(value: $phase.inclinePercent, in: -10...30, step: max(capabilities.inclination?.incrementPercent ?? 1, 0.5)) {
                        LabeledContent("Inclinaison", value: "\(Format.incline(phase.inclinePercent)) %")
                    }
                } header: {
                    Text("Consignes")
                } footer: {
                    Text(String(format: "Tapis actuel : %.1f–%.1f km/h", capabilities.speed.minKmh, capabilities.speed.maxKmh)
                         + (capabilities.inclination.map { String(format: ", %.0f–%.0f %%", $0.minPercent, $0.maxPercent) } ?? ", inclinaison non pilotable"))
                }
                if phase.autoSpeed != nil {
                    autoSection
                } else {
                    Section {
                        Picker("Zone cible", selection: $phase.targetZone) {
                            Text("Aucune").tag(Int?.none)
                            ForEach(1...5, id: \.self) { Text("Zone \($0)").tag(Optional($0)) }
                        }
                    } footer: {
                        Text("Indication et alertes uniquement : dans une phase à vitesse fixe ou progressive, la FC ne pilote jamais le tapis.")
                    }
                }
            }
            .navigationTitle("Phase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        if let a = phase.autoSpeed { phase.targetZone = a.targetZone }
                        phase.speedKmh = (phase.speedKmh * 100).rounded() / 100
                        phase.inclinePercent = (phase.inclinePercent * 10).rounded() / 10
                        onSave(phase)
                        dismiss()
                    }
                    .disabled(phase.durationSeconds <= 0 || phase.name.trimmingCharacters(in: .whitespaces).isEmpty || autoError != nil)
                }
            }
        }
    }

    private var autoSection: some View {
        Section {
            Picker("Zone visée", selection: auto(\.targetZone)) {
                ForEach(1...5, id: \.self) { Text("Zone \($0)").tag($0) }
            }
            Stepper(String(format: "Vitesse auto min : %.1f km/h", auto(\.minKmh).wrappedValue),
                    value: auto(\.minKmh), in: 0.5...20, step: speedStep)
            Stepper(String(format: "Vitesse auto max : %.1f km/h", auto(\.maxKmh).wrappedValue),
                    value: auto(\.maxKmh), in: 0.5...20, step: speedStep)
            Stepper(String(format: "Palier : %.1f km/h", auto(\.stepKmh).wrappedValue),
                    value: auto(\.stepKmh), in: speedStep...1, step: speedStep)
            Stepper("Entre deux accélérations : \(Int(auto(\.increaseInterval).wrappedValue)) s",
                    value: auto(\.increaseInterval), in: 30...240, step: 10)
            Stepper("Entre deux ralentissements : \(Int(auto(\.decreaseInterval).wrappedValue)) s",
                    value: auto(\.decreaseInterval), in: 10...90, step: 5)
            Stepper("FC filtrée sur \(Int(auto(\.filterSeconds).wrappedValue)) s",
                    value: auto(\.filterSeconds), in: 10...30, step: 1)
            Stepper("Marge sous la limite haute : \(auto(\.upperMarginBpm).wrappedValue) bpm",
                    value: auto(\.upperMarginBpm), in: 0...10)
            Toggle("Viser le milieu de la zone", isOn: auto(\.nudgeTowardMiddle))
            Stepper(String(format: "Allure de sécurité sans FC : %.1f km/h", auto(\.fallbackKmh).wrappedValue),
                    value: auto(\.fallbackKmh), in: 1...8, step: speedStep)
            if let e = autoError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            }
        } header: {
            Text("Pilotage par la FC")
        } footer: {
            Text("Sous la zone : +palier, au plus une accélération par délai. Dans la zone : vitesse maintenue. Au-dessus de (limite haute − marge) pendant le délai de ralentissement : −palier (−2 paliers si la FC dépasse la zone de plus de 5 bpm). Sans FC : plus d'accélération, retour progressif à l'allure de sécurité. Les boutons de vitesse reprennent toujours la main. Les limites du tapis s'appliquent en plus.")
        }
    }
}

/// Édition d'un bloc répété.
struct BlockEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var block: RepeatBlock
    let capabilities: TreadmillCapabilities
    let onSave: (RepeatBlock) -> Void
    @State private var editing: ProgramPhase?

    init(block: RepeatBlock, capabilities: TreadmillCapabilities, onSave: @escaping (RepeatBlock) -> Void) {
        _block = State(initialValue: block)
        self.capabilities = capabilities
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bloc") {
                    TextField("Nom", text: $block.name)
                    Stepper("Répétitions : \(block.repeatCount)", value: $block.repeatCount, in: 1...ProgramValidator.maxRepeat)
                    LabeledContent("Durée totale", value: Format.duration(TimeInterval(block.singleIterationSeconds * block.repeatCount)))
                }
                Section("Phases d'une répétition") {
                    ForEach(block.phases) { p in
                        Button { editing = p } label: { PhaseRow(phase: p) }
                    }
                    .onMove { block.phases.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { block.phases.remove(atOffsets: $0) }
                    Button {
                        block.phases.append(ProgramPhase(name: "Phase", kind: .work, durationSeconds: 60, speedKmh: capabilities.snapSpeed(5)))
                    } label: { Label("Ajouter une phase", systemImage: "plus.circle.fill") }
                }
            }
            .navigationTitle("Bloc répété")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { onSave(block); dismiss() }.disabled(block.phases.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .sheet(item: $editing) { p in
                PhaseEditorView(phase: p, capabilities: capabilities) { updated in
                    if let i = block.phases.firstIndex(where: { $0.id == updated.id }) { block.phases[i] = updated }
                }
            }
        }
    }
}
