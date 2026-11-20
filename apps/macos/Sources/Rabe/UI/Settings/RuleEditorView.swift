import RabeKit
import SwiftUI

/// Rule editor: name, destination tab, the condition builder, the dry-run
/// preview and the M2.3 AI check (`AiCheckField` in Tauri): a question the
/// model answers per mail, plus the plain-language planner
/// (`ai_plan_automation`) that proposes name and check text.
struct RuleEditorView: View {
    @State private var draft: RuleDraft
    @State private var preview: ConditionPreview?
    @State private var previewing = false
    // M2.3 — plain-language planner
    @State private var describePrompt = ""
    @State private var planning = false
    @State private var plan: AIAutomationPlan?

    private let labels: [MailLabel]
    private let onSave: (SplitInput) -> Void
    private let onCancel: () -> Void
    private var store: SplitsStore { AppModel.shared.splits }

    init(draft: RuleDraft, labels: [MailLabel], nextPosition: Int64,
         onSave: @escaping (SplitInput) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.labels = labels
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.isNew ? "Neue Regel" : "Regel bearbeiten").font(.headline)

            Form {
                Section("Regel") {
                    TextField("Name", text: $draft.name, prompt: Text("z. B. Lieferantenrechnungen"))
                    SettingPickerRow(title: "Ziel",
                                     hint: "Ohne Ziel bekommt die Regel einen eigenen Tab.",
                                     selection: Binding(get: { draft.target ?? "" }, set: { draft.target = $0.isEmpty ? nil : $0 })) {
                        Text("Eigener Tab").tag("")
                        Text("Wichtig").tag("important")
                        Text("Sonstige").tag("other")
                        ForEach(labels.filter { $0.isAuto != true }) { label in
                            Text("Label: \(label.name)").tag("label:\(label.id)")
                        }
                    }
                }

                Section("Bedingung") {
                    if draft.opaqueCondition != nil {
                        Text("Diese Regel hat eine verschachtelte Bedingung (z. B. aus der Tauri-App). Sie bleibt beim Speichern unverändert; hier lassen sich nur Name und Ziel bearbeiten.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(RuleDescription.text(for: draft.opaqueCondition!, labelNames: labelNames))
                            .font(.system(size: 11, design: .monospaced))
                    } else {
                        if draft.leaves.count > 1 {
                            SettingPickerRow(title: "Verknüpfung",
                                             selection: Binding(get: { draft.combine }, set: { draft.combine = $0 })) {
                                Text("Alle Bedingungen (UND)").tag(RuleDraft.Combine.all)
                                Text("Mindestens eine (ODER)").tag(RuleDraft.Combine.any)
                            }
                        }
                        ForEach($draft.leaves) { $leaf in
                            leafRow($leaf)
                        }
                        Button {
                            draft.leaves.append(RuleDraft.Leaf())
                        } label: { Label("Bedingung hinzufügen", systemImage: "plus") }
                    }
                }

                if draft.target == nil {
                    Section {
                        SettingToggleRow(title: "Alle Unterhaltungen im Tab zählen",
                                         hint: "Zeigt die Größe des Tabs auch dann, wenn alles gelesen ist.",
                                         isOn: $draft.countAll)
                    }
                }

                aiCheckSection
                aiPlannerSection
            }
            .formStyle(.grouped)
            .frame(height: 420)

            if let preview {
                Text("\(preview.total) von \(preview.scanned) der neuesten Unterhaltungen passen"
                     + (preview.samples.isEmpty ? "" : ": " + preview.samples.prefix(3).map(\.subject).joined(separator: " · ")))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button(previewing ? "Prüfe …" : "Vorschau") {
                    guard let condition = draft.buildCondition() else { return }
                    previewing = true
                    Task {
                        preview = await store.preview(condition)
                        previewing = false
                    }
                }
                .disabled(previewing || draft.opaqueCondition != nil || draft.buildCondition() == nil)
                Spacer()
                Button("Abbrechen") { onCancel() }
                Button(draft.isNew ? "Regel anlegen" : "Änderungen speichern") {
                    onSave(draft.input())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (draft.opaqueCondition == nil && draft.buildCondition() == nil))
            }
        }
        .padding(16)
        .frame(width: 620)
    }

    // MARK: KI-Prüfung (M2.3)

    private var store2: AIAssistStore { AppModel.shared.assistant }

    /// Who answers the check: the decision model when it is set and enabled for
    /// rules, else the chat model (same rule as `AiCheckField.tsx`).
    private var aiWhoText: String {
        let status = AppModel.shared.ai.status
        let settings = AppModel.shared.settings
        if status?.decisionConfigured == true, settings.decisionUseRules {
            return "Antwortet das Entscheidungsmodell \(status?.decisionModel ?? "")."
        }
        if status?.configured == true {
            return "Antwortet das Chat-Modell \(status?.model ?? "")."
        }
        return "Noch kein Modell eingerichtet (Einstellungen → Intelligenz)."
    }

    @ViewBuilder private var aiCheckSection: some View {
        Section("KI-Prüfung") {
            if let ai = draft.ai {
                TextEditor(text: Binding(
                    get: { draft.ai?.instruction ?? "" },
                    set: { draft.ai?.instruction = $0 }))
                    .font(.system(size: 12))
                    .frame(height: 54)
                    .scrollContentBackground(.hidden)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
                    .accessibilityLabel("KI-Prüfung in Worten")
                Text("Eine Frage, die das Modell für jede Mail mit Ja oder Nein beantwortet"
                     + (draft.opaqueCondition != nil || !draft.leaves.isEmpty
                        ? " – zusammen mit der Bedingung oben muss beides passen." : "."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(aiWhoText).font(.system(size: 11)).foregroundStyle(.secondary)
                SettingRow(title: "Eigene Sicherheitsschwelle",
                           hint: "Ohne Häkchen gilt der globale Wert; sonst nur Antworten oberhalb davon.") {
                    Toggle("", isOn: Binding(
                        get: { ai.minConfidence != nil },
                        set: { on in draft.ai?.minConfidence = on ? 0.6 : nil }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if let confidence = ai.minConfidence {
                    SettingRow(title: "Schwelle", hint: nil) {
                        Slider(value: Binding(get: { draft.ai?.minConfidence ?? 0.6 },
                                              set: { draft.ai?.minConfidence = $0 }),
                               in: 0...1, step: 0.05)
                            .frame(width: 200)
                        Text("\(Int(confidence * 100)) %").monospacedDigit().font(.system(size: 12))
                    }
                }
                Button("KI-Prüfung entfernen") { draft.ai = nil }
                    .foregroundStyle(.red)
            } else {
                SettingHintRow(title: "Keine KI-Prüfung",
                               hint: "Optional: eine Bedingung in Worten, die das Modell für jede Mail beantwortet.")
                Button("KI-Prüfung hinzufügen") { draft.ai = AiCheck(instruction: "") }
            }
        }
    }

    @ViewBuilder private var aiPlannerSection: some View {
        Section("Mit KI formulieren") {
            SettingHintRow(title: "Regel in Worten",
                           hint: "Die KI schlägt Name und Prüftext vor. Angewendet wird erst, wenn du es übernimmst.")
            TextField("z. B. Rechnungen von Lieferanten, die noch offen sind",
                      text: $describePrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)
            HStack(spacing: 10) {
                Button(planning ? "Formuliere …" : "Formulieren") {
                    let prompt = describePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { return }
                    planning = true
                    Task {
                        plan = await store2.planAutomation(prompt)
                        planning = false
                        if let plan, plan.supported {
                            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = plan.name }
                            if !plan.instruction.isEmpty {
                                draft.ai = AiCheck(instruction: plan.instruction, minConfidence: draft.ai?.minConfidence)
                            }
                            describePrompt = ""
                        }
                    }
                }
                .disabled(planning || describePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if planning { ProgressView().controlSize(.mini) }
                Spacer()
            }
            if let plan {
                if plan.supported {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vorschlag: \(plan.name)").font(.system(size: 12, weight: .medium))
                        Text(plan.instruction).font(.system(size: 11)).foregroundStyle(.secondary)
                        if !plan.summary.isEmpty {
                            Text(plan.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(plan.issues.enumerated()), id: \.offset) { _, issue in
                            Text("• \(issue)").font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }

    private var labelNames: [Int64: String] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })
    }

    // MARK: One condition row

    @ViewBuilder
    private func leafRow(_ leaf: Binding<RuleDraft.Leaf>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: leaf.field) {
                    ForEach(RuleDraft.Leaf.Field.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)

                switch leaf.wrappedValue.field {
                case .sender, .recipient, .subject:
                    Picker("", selection: leaf.op) {
                        Text("enthält").tag(TextOp.contains)
                        Text("ist genau").tag(TextOp.equals)
                        Text("beginnt mit").tag(TextOp.startsWith)
                        Text("endet mit").tag(TextOp.endsWith)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    TextField("Wert", text: leaf.text)
                        .textFieldStyle(.roundedBorder)
                case .label:
                    Picker("", selection: leaf.labelId) {
                        Text("Label wählen").tag(Int64?.none)
                        ForEach(labels) { label in Text(label.name).tag(Int64?.some(label.id)) }
                    }
                    .labelsHidden()
                case .automated:
                    Picker("", selection: leaf.flag) {
                        Text("nur automatisiert").tag(true)
                        Text("von einer Person").tag(false)
                    }
                    .labelsHidden()
                case .attachment:
                    Picker("", selection: leaf.flag) {
                        Text("mit Anhang").tag(true)
                        Text("ohne Anhang").tag(false)
                    }
                    .labelsHidden()
                }

                Toggle("nicht", isOn: leaf.negated)
                    .toggleStyle(.checkbox)
                Button {
                    draft.leaves.removeAll { $0.id == leaf.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Bedingung entfernen")
                .disabled(draft.leaves.count <= 1)
            }
        }
    }
}
