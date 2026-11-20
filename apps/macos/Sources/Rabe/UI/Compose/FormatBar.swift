import AppKit
import RabeKit
import SwiftUI

/// The composer's format bar (M2.6): the same buttons and shortcuts as Tauri's
/// `RichBody` toolbar, plus the link field.
///
/// Every button gives the keyboard back to the editor afterwards — a click moves
/// the first responder to the button, and the next keystroke belongs in the text.
struct FormatBar: View {
    let controller: RichEditorController
    let theme: Theme
    /// Shows the link field under the bar.
    var onLink: () -> Void = {}
    /// Opens the panel that embeds a picture.
    var onImage: () -> Void = {}

    private var state: RichFormatState { controller.state }

    var body: some View {
        HStack(spacing: 2) {
            toggle("bold", "Fett (⌘B)", active: state.bold) { controller.toggleBold() }
            toggle("italic", "Kursiv (⌘I)", active: state.italic) { controller.toggleItalic() }
            toggle("underline", "Unterstrichen (⌘U)", active: state.underline) { controller.toggleUnderline() }
            toggle("strikethrough", "Durchgestrichen (⌘⇧X)", active: state.strike) { controller.toggleStrike() }
            divider
            toggle("list.bullet", "Aufzählung (⌘⇧8)", active: state.listKind == .bullet) {
                controller.toggleList(.bullet)
            }
            toggle("list.number", "Nummerierte Liste (⌘⇧7)", active: state.listKind == .ordered) {
                controller.toggleList(.ordered)
            }
            toggle("text.quote", "Zitat (⌘⇧9)", active: state.quote) { controller.toggleQuote() }
            divider
            toggle("link", "Link (⌘K)", active: state.link != nil, action: onLink)
            toggle("photo", "Bild einfügen", active: false, action: onImage)
            toggle("textformat", "Formatierung entfernen (⌘\\)", active: false) { controller.clearFormatting() }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }

    private var divider: some View {
        Rectangle().fill(theme.line.color).frame(width: 1, height: 14).padding(.horizontal, 3)
    }

    private func toggle(_ symbol: String, _ help: String, active: Bool,
                        action: @escaping () -> Void) -> some View {
        Button {
            action()
            controller.focus()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .foregroundStyle(active ? theme.accent.color : theme.ink2.color)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(active ? theme.accent.color.opacity(0.15) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The link field (`⌘K`, the link button): one line, Enter applies, Esc closes.
struct LinkField: View {
    let theme: Theme
    @State private var text = ""
    @FocusState private var focused: Bool
    let onApply: (String) -> Void
    let onRemove: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("https://…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit { onApply(text) }
                .onExitCommand { onClose() }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.surface.color))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
            Button("Anwenden") { onApply(text) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.color.opacity(0.15)))
                .foregroundStyle(theme.accent.color)
            Button("Entfernen") { onRemove() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.ink3.color)
        }
        .onAppear { focused = true }
    }
}

/// The `@`-suggestion list. The editor keeps the keys: ↑/↓ move, ↵/Tab take,
/// Esc closes (see `RichEditorController.handleKey`).
struct MentionList: View {
    let suggestions: [ContactSuggestion]
    let index: Int
    let theme: Theme
    let onPick: (ContactSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.prefix(6).enumerated()), id: \.element.email) { i, suggestion in
                Button { onPick(suggestion) } label: {
                    HStack(spacing: 6) {
                        Text(suggestion.name ?? suggestion.email)
                            .fontWeight(.medium)
                        Text(suggestion.email)
                            .foregroundStyle(theme.ink3.color)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(i == index ? theme.sel.color : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line.color))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}
