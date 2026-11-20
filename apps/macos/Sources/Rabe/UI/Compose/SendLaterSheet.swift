import RabeKit
import SwiftUI

/// "Später senden …" (`⌘⇧L`): a free-text time ("morgen 9:00", "in 3 stunden",
/// "2h") plus the snooze presets, as Tauri's `TimePopover` — the picked time goes
/// to `queue_send` as `sendAt`.
struct SendLaterSheet: View {
    let theme: Theme
    let onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var parsed: NaturalTime.Pick? { NaturalTime.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Später senden")
                .font(.system(size: 15, weight: .semibold))
            TextField("z. B. morgen 9:00, in 2 stunden, montag", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .focusWhenShown($focused)
                .onSubmit { pickParsed() }
                .accessibilityLabel("Sendezeit")
            Text(parsed.map { "↵ Senden \($0.label)" } ?? "Weiter tippen …")
                .font(.system(size: 11.5))
                .foregroundStyle(parsed == nil ? theme.ink3.color : theme.accent.color)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Format.snoozePresets(), id: \.id) { preset in
                        Button {
                            onPick(preset.at)
                            dismiss()
                        } label: {
                            HStack {
                                Text(preset.name)
                                Spacer()
                                Text(Format.messageTime(preset.at))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.ink3.color)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 150)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(theme.surface.color)
        .onAppear { focused = true }
    }

    private func pickParsed() {
        guard let parsed else { return }
        onPick(parsed.at)
        dismiss()
    }
}

/// `insert-snippet` (`⌘;`): type-ahead over the text modules of the settings.
struct SnippetPickerView: View {
    let theme: Theme
    let onPick: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var snippets: [Snippet] { AppModel.shared.snippets.items }

    private var matches: [Snippet] { Pickers.snippetCandidates(snippets, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Textbaustein einfügen")
                .font(.system(size: 15, weight: .semibold))
            TextField("Baustein suchen …", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onChange(of: query) { _, _ in index = 0 }
                .onSubmit { pick() }
                .focusWhenShown($focused)
                .accessibilityLabel("Baustein suchen")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { i, snippet in
                        Button { index = i; pick() } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(snippet.name).lineLimit(1)
                                    if let shortcut = snippet.shortcut, !shortcut.isEmpty {
                                        Text(";\(shortcut)")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(theme.ink3.color)
                                    }
                                    Spacer(minLength: 0)
                                }
                                Text(snippet.bodyText.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.ink3.color)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(i == index ? theme.sel.color : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty {
                        Text(snippets.isEmpty ? "Noch keine Textbausteine (Einstellungen → Textbausteine)"
                                              : "Nichts gefunden")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.ink3.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
            }
            .frame(height: 220)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(theme.surface.color)
        .onAppear {
            focused = true
            if !AppModel.shared.snippets.loaded { Task { await AppModel.shared.snippets.load() } }
        }
    }

    private func pick() {
        guard matches.indices.contains(index) else { return }
        onPick(matches[index])
        dismiss()
    }
}
