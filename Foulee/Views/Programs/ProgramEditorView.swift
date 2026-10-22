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
                        Text("  • \(p.name) \(Format.duration(TimeInterval(p.durationSeconds))) · \(Format.speed(p.speedKmh)) km/h · \(Format.incline(p.inclinePercent)) %")
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
                Text("\(Format.speed(phase.speedKmh)) km/h · \(Format.incline(phase.inclinePercent)) %"
                     + (phase.targetZone.map { " · Z\($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
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
                    Stepper(value: $phase.speedKmh, in: 0.1...30, step: max(capabilities.speed.incrementKmh, 0.1)) {
                        LabeledContent("Vitesse", value: String(format: "%.1f km/h", phase.speedKmh))
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
                Section {
                    Picker("Zone cible", selection: $phase.targetZone) {
                        Text("Aucune").tag(Int?.none)
                        ForEach(1...5, id: \.self) { Text("Zone \($0)").tag(Optional($0)) }
                    }
                } footer: {
                    Text("Indication et alertes uniquement : la FC ne pilote pas le tapis.")
                }
            }
            .navigationTitle("Phase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        phase.speedKmh = (phase.speedKmh * 100).rounded() / 100
                        phase.inclinePercent = (phase.inclinePercent * 10).rounded() / 10
                        onSave(phase)
                        dismiss()
                    }
                    .disabled(phase.durationSeconds <= 0 || phase.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
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
