import CoraxKit
import SwiftUI

// MARK: - Human-readable rule description

/// German one-liners for split rules (`settings:splits.describe.*`), used in the
/// list and in the editor's summary.
enum RuleDescription {
    static func text(for rule: SplitRule, labelNames: [Int64: String]) -> String {
        if let condition = rule.condition {
            return text(for: condition, labelNames: labelNames)
        }
        return text(for: rule.query, labelNames: labelNames)
    }

    static func text(for condition: RuleCondition, labelNames: [Int64: String]) -> String {
        switch condition {
        case .all(let of):
            return of.map { text(for: $0, labelNames: labelNames) }.joined(separator: " · ")
        case .any(let of):
            return of.map { text(for: $0, labelNames: labelNames) }.joined(separator: " oder ")
        case .not(let inner):
            return "nicht " + text(for: inner, labelNames: labelNames)
        case .sender(let op, let value):
            return "von " + addressText(op, value)
        case .recipient(let op, let value):
            return "an " + addressText(op, value)
        case .subject(let op, let value):
            return "Betreff " + subjectOpText(op) + " " + value
        case .label(let id):
            return "Label \(labelNames[id] ?? "#\(id)")"
        case .isAutomated(let value):
            return value ? "nur automatisiert" : "von einer Person"
        case .hasAttachment(let value):
            return value ? "mit Anhang" : "ohne Anhang"
        }
    }

    static func text(for query: SplitRuleQuery, labelNames: [Int64: String]) -> String {
        var parts: [String] = []
        if let senders = query.senders, !senders.isEmpty { parts.append("von " + list(senders)) }
        if let excluded = query.excludeSenders, !excluded.isEmpty { parts.append("nicht von " + list(excluded)) }
        if let recipients = query.recipients, !recipients.isEmpty { parts.append("an " + list(recipients)) }
        if let subjects = query.subjectContains, !subjects.isEmpty { parts.append("Betreff enthält " + list(subjects)) }
        if let labels = query.labels, !labels.isEmpty {
            parts.append("Label " + list(labels.map { labelNames[$0] ?? "#\($0)" }))
        }
        if let automated = query.isAutomated { parts.append(automated ? "nur automatisiert" : "von einer Person") }
        if let attachment = query.hasAttachment { parts.append(attachment ? "mit Anhang" : "ohne Anhang") }
        return parts.isEmpty ? "trifft auf nichts zu" : parts.joined(separator: " · ")
    }

    private static func list(_ values: [String]) -> String { values.joined(separator: ", ") }

    /// "X", "genau X", "X…", "…X" — enough to see what a text condition does.
    private static func addressText(_ op: TextOp, _ value: String) -> String {
        switch op {
        case .contains: value
        case .equals: "genau " + value
        case .startsWith: value + "…"
        case .endsWith: "…" + value
        }
    }

    private static func subjectOpText(_ op: TextOp) -> String {
        switch op {
        case .contains: "enthält"
        case .equals: "ist genau"
        case .startsWith: "beginnt mit"
        case .endsWith: "endet mit"
        }
    }

    /// Route keys: "important", "other", "label:<id>".
    static func targetText(_ target: String?, labels: [MailLabel]) -> String {
        guard let target else { return "eigener Tab" }
        switch target {
        case "important": return "Wichtig"
        case "other": return "Sonstige"
        default:
            if target.hasPrefix("label:"), let id = Int64(target.dropFirst(6)) {
                return labels.first { $0.id == id }?.name ?? target
            }
            return target
        }
    }
}

// MARK: - Splits and rules page

struct SplitsSettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var store: SplitsStore { model.splits }

    @State private var editing: RuleDraft?
    @State private var deleteTarget: SplitRule?

    private var labelNames: [Int64: String] {
        var map: [Int64: String] = [:]
        for label in model.labels.items { map[label.id] = label.name }
        return map
    }

    var body: some View {
        Form {
            Section {
                Text("Wichtig steht immer zuerst, Sonstige immer zuletzt. Eigene Tabs und automatische Label-Tabs sortierst du dazwischen.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                builtinRow(name: "Wichtig", desc: "E-Mails von Personen", badge: "Immer zuerst")
                ForEach(Array(store.tabs.enumerated()), id: \.element.tabIdentity) { index, tab in
                    tabRow(tab, index: index)
                }
                builtinRow(name: "Sonstige", desc: "automatisierte E-Mails", badge: "Immer zuletzt")
            } header: {
                Text("Geteilte Inbox")
            } footer: {
                Text("Regeln laufen einmal pro Nachricht und nur auf E-Mails der letzten 3 Tage.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Regeln") {
                if store.splits.isEmpty {
                    Text("Noch keine Regeln. Eine Regel sortiert neue E-Mails anhand einer Bedingung.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(store.splits) { rule in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(rule.name).fontWeight(.medium)
                                if rule.target != nil {
                                    Text("→ \(RuleDescription.targetText(rule.target, labels: model.labels.items))")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                                }
                            }
                            Text(RuleDescription.text(for: rule, labelNames: labelNames))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Bearbeiten") { editing = RuleDraft(rule: rule) }.buttonStyle(.borderless)
                        Button("Löschen", role: .destructive) { deleteTarget = rule }.buttonStyle(.borderless)
                    }
                }
                Button { editing = RuleDraft(rule: nil, position: store.nextPosition) } label: {
                    Label("Neue Regel", systemImage: "plus")
                }
            }

            Section("Auto-Labels") {
                SettingToggleRow(title: "Auto-Labels",
                                 hint: "Eingehende E-Mails automatisch als Marketing, News, Social oder Pitch kategorisieren.",
                                 isOn: Binding(get: { model.settings.autoLabelsEnabled },
                                               set: { model.settings.set("autoLabelsEnabled", $0) }))
                HStack {
                    Button("Auto-Labels neu vergeben") {
                        Task {
                            if let count = await store.relabelAutoLabels() {
                                model.toasts.show("\(count) Unterhaltungen neu zugeordnet")
                            }
                        }
                    }
                    .disabled(store.busy)
                    Spacer()
                    if store.autoLabels.isEmpty {
                        Button("Standard-Kategorien wiederherstellen") {
                            Task {
                                if let count = await store.restoreAutoLabels() {
                                    model.toasts.show("\(count) Kategorien wiederhergestellt")
                                    await model.reloadOrganisation()
                                }
                            }
                        }
                        .disabled(store.busy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            RuleEditorView(draft: draft, labels: model.labels.items, nextPosition: draft.position) { input in
                Task {
                    if await store.save(input) != nil {
                        editing = nil
                        await model.reloadOrganisation()
                    }
                }
            } onCancel: { editing = nil }
        }
        .alert("Regel löschen?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Löschen", role: .destructive) {
                if let target = deleteTarget {
                    Task {
                        if await store.delete(target.id) { await model.reloadOrganisation() }
                    }
                }
                deleteTarget = nil
            }
            Button("Abbrechen", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget.map { SettingsConfirm.deleteRow($0.name, what: "Regel") } ?? "")
        }
    }

    // MARK: Rows

    private func builtinRow(name: String, desc: String, badge: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tabRow(_ tab: TabItem, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tab.name).fontWeight(.medium)
                    if !tab.ownsTab {
                        Text("→ inline").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if tab.isAutoCategory {
                        Text("Auto").font(.system(size: 10))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                if let rule = store.splits.first(where: { $0.id == tab.id }), tab.kind == .split {
                    Text(RuleDescription.text(for: rule, labelNames: labelNames))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { move(index, -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0 || store.busy)
                .help("Nach oben")
            Button { move(index, +1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == store.tabs.count - 1 || store.busy)
                .help("Nach unten")
        }
    }

    private func move(_ index: Int, _ step: Int) {
        Task { _ = await store.move(from: index, to: index + step) }
    }
}

// MARK: - Draft

/// The editable form of a split rule. The condition builder keeps the common
/// shapes (one leaf, or an `all`/`any` list of leaves, each possibly negated);
/// a tree it cannot represent is preserved untouched and only name/target are
/// editable then.
struct RuleDraft: Identifiable {
    /// Stable identity for the sheet; `ruleID` is the row id (nil = new rule).
    let draftID = UUID()
    var id: String { draftID.uuidString }

    enum Combine: String, CaseIterable { case all, any }

    struct Leaf: Identifiable {
        enum Field: String, CaseIterable {
            case sender, recipient, subject, label, automated, attachment
            var title: String {
                switch self {
                case .sender: "Absender"
                case .recipient: "Empfänger"
                case .subject: "Betreff"
                case .label: "Label"
                case .automated: "Automatisiert"
                case .attachment: "Anhang"
                }
            }
        }

        var id = UUID()
        var field: Field = .sender
        var op: TextOp = .contains
        var text = ""
        var labelId: Int64?
        var flag = true
        var negated = false
    }

    var ruleID: Int64?
    var name: String
    var position: Int64
    var target: String?
    var countAll: Bool
    /// Preserved as-is (AI checks are out of scope for M2.1).
    var ai: AiCheck?
    var query: SplitRuleQuery
    /// The original tree when it is too complex for the simple builder.
    var opaqueCondition: RuleCondition?

    var combine: Combine = .all
    var leaves: [Leaf] = []

    var isNew: Bool { ruleID == nil }

    init(rule: SplitRule?, position: Int64 = -1) {
        ruleID = rule?.id
        name = rule?.name ?? ""
        self.position = rule?.position ?? position
        target = rule?.target
        countAll = rule?.countAll ?? false
        ai = rule?.ai
        query = rule?.query ?? SplitRuleQuery()
        if let condition = rule?.condition, let parsed = Self.parse(condition) {
            combine = parsed.combine
            leaves = parsed.leaves
        } else if let condition = rule?.condition {
            opaqueCondition = condition
        } else {
            leaves = [Self.leaf(from: rule?.query)]
        }
    }

    /// `nil` when the tree is not a flat all/any of leaves.
    static func parse(_ condition: RuleCondition) -> (combine: Combine, leaves: [Leaf])? {
        switch condition {
        case .all(let of), .any(let of):
            let leaves = of.map { leaf(from: $0) }
            guard leaves.allSatisfy({ $0 != nil }) else { return nil }
            return (condition.isAll ? .all : .any, leaves.compactMap { $0 })
        default:
            guard let leaf = leaf(from: condition) else { return nil }
            return (.all, [leaf])
        }
    }

    static func leaf(from condition: RuleCondition) -> Leaf? {
        switch condition {
        case .sender(let op, let value): return Leaf(field: .sender, op: op, text: value)
        case .recipient(let op, let value): return Leaf(field: .recipient, op: op, text: value)
        case .subject(let op, let value): return Leaf(field: .subject, op: op, text: value)
        case .label(let id): return Leaf(field: .label, labelId: id)
        case .isAutomated(let value): return Leaf(field: .automated, flag: value)
        case .hasAttachment(let value): return Leaf(field: .attachment, flag: value)
        case .not(let inner):
            guard var leaf = leaf(from: inner) else { return nil }
            leaf.negated = true
            return leaf
        default: return nil
        }
    }

    /// The flat query the legacy rules stored; folded into one sender leaf.
    static func leaf(from query: SplitRuleQuery?) -> Leaf {
        guard let query else { return Leaf() }
        if let first = query.senders?.first { return Leaf(field: .sender, text: first) }
        if let first = query.recipients?.first { return Leaf(field: .recipient, text: first) }
        if let first = query.subjectContains?.first { return Leaf(field: .subject, text: first) }
        if let first = query.labels?.first { return Leaf(field: .label, labelId: first) }
        if let automated = query.isAutomated { return Leaf(field: .automated, flag: automated) }
        if let attachment = query.hasAttachment { return Leaf(field: .attachment, flag: attachment) }
        return Leaf()
    }

    var isEmptyLeaf: Bool { leaves.allSatisfy { $0.isBlank } }

    func buildCondition() -> RuleCondition? {
        if let opaqueCondition { return opaqueCondition }
        let built: [RuleCondition] = leaves.compactMap { leaf in
            guard !leaf.isBlank else { return nil }
            let base: RuleCondition
            switch leaf.field {
            case .sender: base = .sender(leaf.op, leaf.text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .recipient: base = .recipient(leaf.op, leaf.text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .subject: base = .subject(leaf.op, leaf.text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .label: base = leaf.labelId.map { .label($0) } ?? .label(-1)
            case .automated: base = .isAutomated(leaf.flag)
            case .attachment: base = .hasAttachment(leaf.flag)
            }
            return leaf.negated ? .not(base) : base
        }
        guard !built.isEmpty else { return nil }
        return combine == .all ? RuleCondition.allOf(built) : (built.count == 1 ? built[0] : .any(built))
    }

    func input() -> SplitInput {
        SplitInput(id: ruleID,
                   name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                   position: position,
                   query: opaqueCondition == nil ? SplitRuleQuery() : query,
                   condition: buildCondition(),
                   target: target,
                   ai: ai,
                   countAll: target == nil ? countAll : false)
    }
}

extension RuleDraft.Leaf {
    var isBlank: Bool {
        switch field {
        case .sender, .recipient, .subject: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .label: return labelId == nil
        case .automated, .attachment: return false
        }
    }
}
