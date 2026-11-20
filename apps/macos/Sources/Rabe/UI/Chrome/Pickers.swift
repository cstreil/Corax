import RabeKit
import SwiftUI

/// The four pickers of M2.5 — "Verschieben" (`V`), "Label" (`L`), "Split nach
/// Absender" and the confirmation before a thread is deleted for good — as one
/// small card over the list: search field, arrow keys, ↵, Esc.
///
/// Layout of the list itself is untouched: the pickers are overlays in
/// `MainView`, the same way the palette and the AI panel are.

/// Backdrop + card shared by every picker.
struct PickerShell<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { onClose() }
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased(with: Format.locale))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.ink3.color)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                content
            }
            .foregroundStyle(theme.ink.color)
            .frame(width: 400)
            .padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line.color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
            .padding(.top, 90)
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// One row of a picker: title, optional detail on the right, optional checkmark.
struct PickerRow: View {
    let title: String
    var detail: String? = nil
    var checked = false
    var tint: Color? = nil
    let selected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if let tint {
                Circle().fill(tint).frame(width: 8, height: 8)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(theme.ink3.color).lineLimit(1)
            }
            if checked {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.sel.color : .clear))
        .contentShape(Rectangle())
    }
}

/// Small horizontal key hints for the footer of a picker.
struct PickerHint: View {
    let keys: [(String, String)]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(keys, id: \.0) { key, label in
                HStack(spacing: 5) { KeyCap(key); Text(label) }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.ink3.color)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - Verschieben (`V`)

struct MovePickerView: View {
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }
    @State private var query = ""
    @State private var index = 0
    /// W3: the threads the popover was opened on. Acting on the live selection
    /// could move a row that slid in while the popover stood.
    @State private var targets: [Int64]?
    @FocusState private var focused: Bool

    private var frozenTargets: [Int64] { targets ?? box.targetIds }

    private var matches: [FolderInfo] {
        Pickers.moveCandidates(box.folders, view: box.view, query: query)
    }

    var body: some View {
        PickerShell(title: "Verschieben", onClose: close) {
            VStack(spacing: 0) {
                TextField("Ordner suchen …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .onChange(of: query) { _, _ in index = 0 }
                    .onSubmit { pick() }
                    .focusWhenShown($focused)
                    .accessibilityLabel("Ordner suchen")
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { i, folder in
                                Button { index = i; pick() } label: {
                                    PickerRow(title: box.folderName(folder), detail: folder.role, selected: i == index)
                                }
                                .buttonStyle(.plain)
                                .id(folder.id)
                            }
                            if matches.isEmpty {
                                Text(box.folders.isEmpty ? "Ordner werden geladen …" : "Kein Ordner gefunden")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 18)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: index) { _, i in
                        guard matches.indices.contains(i) else { return }
                        proxy.scrollTo(matches[i].id)
                    }
                }
                PickerHint(keys: [("↑↓", "wählen"), ("↵", "verschieben"), ("Esc", "abbrechen")])
            }
            .onKeyPress(.downArrow) { index = min(index + 1, max(0, matches.count - 1)); return .handled }
            .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onAppear { focused = true; targets = box.targetIds }
        }
    }

    private func pick() {
        guard matches.indices.contains(index) else { return }
        let folder = matches[index]
        let ids = frozenTargets
        let count = ids.count
        close()
        box.moveToFolder(folder, targets: ids)
        PerfLog.shared.write("move_pick folder=\(folder.id) n=\(count)")
    }

    private func close() {
        model.moveOpen = false
        box.focusList()
    }
}

// MARK: - Label (`L`)

struct LabelPickerView: View {
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }
    @State private var query = ""
    @State private var index = 0
    /// Toggles made while the popover stands; the cached rows do not re-render.
    @State private var override: [Int64: Bool] = [:]
    /// W3: the threads the popover was opened on (see `MovePickerView`).
    @State private var targets: [Int64]?
    @FocusState private var focused: Bool

    private var frozenTargets: [Int64] { targets ?? box.targetIds }

    private var matches: [RabeKit.Label] {
        Pickers.labelCandidates(model.labels.items, query: query)
    }

    private func isApplied(_ label: RabeKit.Label) -> Bool {
        override[label.id] ?? box.allTargetsHaveLabel(label.id, targets: frozenTargets)
    }

    var body: some View {
        PickerShell(title: "Label", onClose: close) {
            VStack(spacing: 0) {
                TextField("Label suchen …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .onChange(of: query) { _, _ in index = 0 }
                    .onSubmit { toggle() }
                    .focusWhenShown($focused)
                    .accessibilityLabel("Label suchen")
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { i, label in
                                Button { index = i; toggle() } label: {
                                    PickerRow(title: label.name,
                                              detail: label.isAuto == true ? "auto" : nil,
                                              checked: isApplied(label),
                                              tint: NSColor(hex: label.color).map(Color.init(nsColor:)) ?? nil,
                                              selected: i == index)
                                }
                                .buttonStyle(.plain)
                                .id(label.id)
                            }
                            if matches.isEmpty {
                                Text(model.labels.loaded ? "Kein Label gefunden" : "Labels werden geladen …")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 18)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: index) { _, i in
                        guard matches.indices.contains(i) else { return }
                        proxy.scrollTo(matches[i].id)
                    }
                }
                PickerHint(keys: [("↑↓", "wählen"), ("↵", "setzen / entfernen"), ("Esc", "fertig")])
            }
            .onKeyPress(.downArrow) { index = min(index + 1, max(0, matches.count - 1)); return .handled }
            .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onAppear { focused = true; targets = box.targetIds }
        }
    }

    private func toggle() {
        guard matches.indices.contains(index) else { return }
        let label = matches[index]
        let applied = !isApplied(label)
        override[label.id] = applied
        box.setLabel(label.id, applied: applied, targets: frozenTargets)
        PerfLog.shared.write("label_toggle id=\(label.id) applied=\(applied ? 1 : 0)")
    }

    private func close() {
        model.labelOpen = false
        box.focusList()
    }
}

// MARK: - Split nach Absender

struct SplitPickerView: View {
    private var model: AppModel { AppModel.shared }
    @State private var name = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        let suggestion = model.splitSuggestion
        PickerShell(title: "Split nach Absender", onClose: close) {
            VStack(alignment: .leading, spacing: 10) {
                if let suggestion {
                    Text("Neuer Tab für alle Mails von @\(suggestion.domain)")
                        .font(.system(size: 13))
                    TextField("Name des Tabs", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { create(suggestion) }
                        .focusWhenShown($focused)
                        .accessibilityLabel("Name des Tabs")
                    Text("Regel: Absender enthält „\(suggestion.sender)“")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Abbrechen") { close() }
                        Button(busy ? "Lege an …" : "Anlegen") { create(suggestion) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Text("Für diesen Absender gibt es keine Domain, nach der sich ein Tab trennen ließe.")
                        .font(.system(size: 12))
                    HStack { Spacer(); Button("Schließen") { close() } }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .onAppear {
                name = model.splitSuggestion?.name ?? ""
                focused = true
            }
        }
    }

    private func create(_ suggestion: (name: String, domain: String, sender: String)) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !busy else { return }
        busy = true
        let position = model.splits.nextPosition
        let input = SplitInput(id: nil, name: title, position: position,
                               condition: .sender(.contains, suggestion.sender), target: nil)
        Task {
            let created = await model.splits.save(input)
            busy = false
            PerfLog.shared.write("split_create ok=\(created != nil ? 1 : 0) domain=\(suggestion.domain)")
            if created != nil {
                model.toasts.show("Tab „\(title)“ angelegt")
                close()
                await model.mailbox.bootstrap()
            }
        }
    }

    private func close() {
        model.splitOpen = false
        model.splitSuggestion = nil
        model.mailbox.focusList()
    }
}

// MARK: - Endgültig löschen

struct PermanentDeleteDialogView: View {
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }
    @Environment(\.theme) private var theme

    var body: some View {
        // W3: the dialog shows and deletes the threads it was opened on.
        let count = model.permanentDeleteIds.count
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea().onTapGesture { close() }
            VStack(alignment: .leading, spacing: 12) {
                Text("Endgültig löschen")
                    .font(.system(size: 15, weight: .semibold))
                Text(count == 1
                     ? "Dieser Thread wird auf dem Server gelöscht. Das lässt sich nicht rückgängig machen."
                     : "\(count) Threads werden auf dem Server gelöscht. Das lässt sich nicht rückgängig machen.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    Button("Abbrechen") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Endgültig löschen") {
                        let n = count
                        let ids = model.permanentDeleteIds
                        close()
                        box.deletePermanently(ids: ids)
                        PerfLog.shared.write("permanent_delete_confirmed n=\(n)")
                    }
                    .tint(.red)
                    .disabled(count == 0)
                }
            }
            .padding(18)
            .frame(width: 400)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line.color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
        }
        .onExitCommand { close() }
    }

    private func close() {
        model.permanentDeleteOpen = false
        box.focusList()
    }
}
