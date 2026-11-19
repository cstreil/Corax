import AppKit
import RabeKit
import SwiftUI

/// Text composer, inline under a thread or in its own window (mockup `.composer`).
struct ComposeView: View {
    @Bindable var draft: ComposeDraft
    let inline: Bool
    var onClose: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @FocusState private var focus: Field?
    @State private var suggestions: [ContactSuggestion] = []
    @State private var suggestionIndex = 0

    enum Field { case to, subject, body }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            recipientRow
            if !suggestions.isEmpty { suggestionList }
            if !inline || draft.mode == .forward {
                TextField("Betreff", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($focus, equals: .subject)
                    .onSubmit { focus = .body }
                Divider().overlay(theme.line.color)
            }
            TextEditor(text: $draft.body)
                .font(.system(size: 14))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(minHeight: inline ? 84 : 240)
                .focused($focus, equals: .body)
                .accessibilityLabel("Nachricht")
                .onKeyPress(.escape) { discard(); return .handled }
            HStack(spacing: 10) {
                HStack(spacing: 6) { KeyCap("Esc"); Text("verwerfen") }
                if draft.savedOnce { Text(Strings.draftSaved).foregroundStyle(theme.ink3.color) }
                Spacer()
                Button(action: send) {
                    HStack(spacing: 8) {
                        Text(Strings.send).fontWeight(.semibold)
                        Text("⌘↵").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 5)
                            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.25)))
                    }
                    .foregroundStyle(theme.accentInk.color)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.color))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.isSending)
                .accessibilityLabel(Strings.send)
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.ink3.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: inline ? 640 : .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.color, lineWidth: 1))
        .shadow(color: theme.accent.color.opacity(0.25), radius: 10, y: 6)
        .onAppear {
            focus = initialField
            #if DEBUG || RABE_TEST_HOOKS
            logComposeFocus()
            #endif
        }
        .modifier(ComposeDefaultFocus(focus: $focus, field: initialField, active: !inline))
        .onExitCommand { discard() }
    }

    /// Where the keyboard goes when the composer appears: "An" for a new mail
    /// (no recipients yet), the text field for a reply/forward.
    private var initialField: Field { draft.to.isEmpty ? .to : .body }

    #if DEBUG || RABE_TEST_HOOKS
    /// Evidence for P2f #9: what the composer expected, what the FocusState
    /// says and whether a field editor really holds the keyboard.
    private func logComposeFocus() {
        let expected = initialField
        let inline = self.inline
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
            let actual = focus.map { String(describing: $0) } ?? "none"
            PerfLog.shared.write("compose_focus inline=\(inline ? 1 : 0) expected=\(expected) actual=\(actual) responder=\(responder)")
        }
    }
    #endif

    private var recipientRow: some View {
        HStack(spacing: 6) {
            Text("An:").foregroundStyle(theme.ink3.color)
            ForEach(draft.to, id: \.email) { address in
                HStack(spacing: 4) {
                    Text(address.name ?? address.email).lineLimit(1)
                    Button { draft.removeRecipient(address) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(address.email) entfernen")
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(theme.hover.color))
                .help(address.email)
            }
            TextField(draft.to.isEmpty ? "Empfänger" : "", text: $draft.toText)
                .textFieldStyle(.plain)
                .focused($focus, equals: .to)
                .accessibilityLabel("Empfänger")
                .onSubmit {
                    if suggestions.indices.contains(suggestionIndex) { pick(suggestions[suggestionIndex]) } else { draft.commitToText() }
                    focus = .body
                }
                .onKeyPress(.downArrow) { suggestionIndex = min(suggestionIndex + 1, max(0, suggestions.count - 1)); return .handled }
                .onKeyPress(.upArrow) { suggestionIndex = max(0, suggestionIndex - 1); return .handled }
                .onChange(of: draft.toText) { _, text in
                    if text.hasSuffix(",") || text.hasSuffix(";") { draft.commitToText(); suggestions = []; return }
                    Task {
                        let found = await draft.suggestions(for: text)
                        if draft.toText == text { suggestions = found; suggestionIndex = 0 }
                    }
                }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.ink.color)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.prefix(6).enumerated()), id: \.element.email) { i, s in
                Button { pick(s) } label: {
                    HStack {
                        Text(s.name ?? s.email).fontWeight(.medium)
                        Text(s.email).foregroundStyle(theme.ink3.color)
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(i == suggestionIndex ? theme.sel.color : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
    }

    private func pick(_ s: ContactSuggestion) {
        draft.addRecipient(s.address)
        suggestions = []
    }

    private func send() {
        let model = AppModel.shared
        draft.send(onSent: {
            if inline { model.mailbox.inlineCompose = nil } else { onClose?() }
            model.mailbox.focusList()
        }, onUndo: { restored in
            if inline { model.mailbox.inlineCompose = restored } else {
                model.composeDrafts[restored.id] = restored
                model.openComposeWindow?(restored.id)
            }
            model.toasts.show(Strings.undone)
        })
    }

    private func discard() {
        if inline { AppModel.shared.discardInlineDraft() } else { draft.discard(); onClose?() }
    }
}

/// The compose window is created *after* `ComposeView.onAppear` has run, and
/// when it turns key AppKit makes the window itself the first responder
/// (observed: `responder=SwiftUI.AppKitWindow`) — the FocusState set in
/// `onAppear` is forgotten. `defaultFocus` tells SwiftUI which field to pick
/// when the window appears. The inline composer does not use it: there the text
/// editor already takes the focus.
private struct ComposeDefaultFocus: ViewModifier {
    let focus: FocusState<ComposeView.Field?>.Binding
    let field: ComposeView.Field
    let active: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content.defaultFocus(focus, field)
        } else {
            content
        }
    }
}

/// `C`: new mail in its own window.
struct ComposeWindowView: View {
    let draftID: UUID?
    @Environment(\.dismiss) private var dismiss
    private var model: AppModel { AppModel.shared }

    var body: some View {
        Group {
            if let draftID, let draft = model.composeDrafts[draftID] {
                VStack(alignment: .leading, spacing: 10) {
                    Text(draft.title).font(.system(size: 15, weight: .semibold))
                    ComposeView(draft: draft, inline: false) {
                        model.composeDrafts[draftID] = nil
                        dismiss()
                    }
                }
                .padding(18)
            } else {
                Text("Kein Entwurf").padding()
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .environment(\.theme, model.theme)
        .background(model.theme.win.color)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
    }
}
