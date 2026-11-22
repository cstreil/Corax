import AppKit
import CoraxKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// M2.3: ⌘J / ⌘⇧P from the menu reach the compose view that holds the key
    /// window (`object`: "draft" | "proofread").
    static let coraxComposeAI = AppIdentity.notification("compose.ai")
    /// M2.5: composer commands from the menu, the palette or a key
    /// (`object`: "send_done" | "send_later" | "instant_send" | "attach" |
    /// "snippet" | "quote:<text>").
    static let coraxComposeAction = AppIdentity.notification("compose.action")
}

/// M2.9: Panel und Inline-Entwurf liegen im selben Fenster. Ein Kürzel aus dem
/// Menü gehört nur dem Entwurf, den die Benachrichtigung nennt.
extension Notification {
    func isFor(_ id: UUID) -> Bool {
        guard let target = userInfo?["draft"] as? UUID else { return true }
        return target == id
    }
}

/// Text composer, inline under a thread or in its own window (mockup `.composer`).
/// M2.3 adds the AI bar (`ai_draft`), the proofread proposal (`ai_proofread`),
/// quick replies (`ai_quick_replies`), the typed follow-ups (`ai_draft_actions`)
/// and `⌘Z` for an AI change on the text.
struct ComposeView: View {
    @Bindable var draft: ComposeDraft
    /// M2.9: inline unter dem Thread, im eigenen Fenster oder angedockt im
    /// Panel. Die Felder sind in allen drei Fällen dieselben (Entwurf §5).
    let presentation: ComposePresentation
    var onClose: (() -> Void)? = nil
    /// Panel: `Esc` schließt zuerst ein Popup, dann das Maximieren, dann
    /// minimiert es den Entwurf (§3.3). Ohne Closure wird verworfen.
    var onEscape: (() -> Void)? = nil
    /// Panel: Zähler, damit `⌃Tab` den Fokus in den Editor legt.
    var focusRequest: Int = 0

    private var inline: Bool { presentation == .inline }
    private var docked: Bool { presentation == .docked }
    @Environment(\.theme) private var theme
    @FocusState private var focus: Field?
    @State private var suggestions: [ContactSuggestion] = []
    @State private var suggestionIndex = 0

    // MARK: KI (M2.3)
    @State private var aiOpen = false
    @State private var aiInstruction = ""
    @FocusState private var aiFocused: Bool
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    // M2.5: Anhänge, Textbausteine, Senden-Varianten.
    @State private var sendLaterOpen = false
    @State private var snippetOpen = false
    @State private var dropActive = false
    // M2.6: formatierter Textkörper (HTML), Link-Feld, @-Vorschläge.
    @State private var editor = RichEditorController()
    @State private var linkOpen = false
    @State private var mentionSuggestions: [ContactSuggestion] = []

    enum Field { case to, subject }

    /// Fixed edit instructions; they go through `ai_draft` with the current
    /// body, which is Tauri's "Edit with AI".
    private let editPresets = ["Kürzer", "Freundlicher", "Formeller", "Klarer"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            recipientRow
            // M2.4: Cc was invisible until now (reply-all and `mailto:`); Bcc
            // comes from a `mailto:` link and is shown, not edited.
            if !draft.cc.isEmpty { ccRow }
            if !draft.bcc.isEmpty { bccRow }
            if !suggestions.isEmpty { suggestionList }
            if !inline || draft.mode == .forward {
                TextField("Betreff", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($focus, equals: .subject)
                    .onSubmit { editor.focus() }
                Divider().overlay(theme.line.color)
            }
            if !draft.quickReplies.isEmpty { quickReplyRow }
            // M2.6: der Körper ist formatierter Text (`NSTextView`, HTML-Teilmenge).
            VStack(alignment: .leading, spacing: 4) {
                FormatBar(controller: editor, theme: theme,
                          onLink: { withAnimation(Motion.animation) { linkOpen.toggle() } },
                          onAttach: { attachFiles() })
                if linkOpen {
                    LinkField(theme: theme,
                              onApply: { value in
                                  linkOpen = false
                                  editor.applyLink(value)
                                  editor.focus()
                              },
                              onRemove: {
                                  linkOpen = false
                                  editor.applyLink(nil)
                                  editor.focus()
                              },
                              onClose: { linkOpen = false; editor.focus() })
                }
                RichTextEditor(html: draft.bodyHtml, revision: draft.bodyRevision, theme: theme,
                               controller: editor, minHeight: editorMinHeight,
                               onChange: { draft.syncEditorBody($0) },
                               onMention: { query in handleMentionQuery(query) },
                               onLink: { withAnimation(Motion.animation) { linkOpen = true } })
                    .frame(minHeight: editorMinHeight, maxHeight: docked ? .infinity : nil)
                    .accessibilityLabel("Nachricht")
                    .overlay(alignment: .topLeading) {
                        if !mentionSuggestions.isEmpty {
                            MentionList(suggestions: mentionSuggestions, index: editor.mentionIndex,
                                        theme: theme, onPick: { pickMention($0) })
                                .offset(y: 22)
                        }
                    }
            }
            if !draft.attachments.isEmpty { attachmentRow }
            if aiOpen { aiBar }
            if let suggestion = draft.proofreadSuggestion { proofreadBox(suggestion) }
            if draft.canUndoAIChange { undoBar }
            if !draft.draftActions.isEmpty { followUpRow }
            ComposeFooter(draft: draft, theme: theme,
                          onDismissHint: false,
                          escHint: docked ? "minimieren" : "verwerfen",
                          onDetach: inline ? { AppModel.shared.detachInlineDraft() } : nil,
                          onAI: { withAnimation(Motion.animation) { aiOpen.toggle() } },
                          onAttach: { attachFiles() },
                          onSnippet: { snippetOpen = true },
                          onSend: { send(.now) },
                          onDone: { send(.done) },
                          onLater: { sendLaterOpen = true },
                          onInstant: { send(.instant) })
            .font(.system(size: 12))
            .foregroundStyle(theme.ink3.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, docked ? 8 : 10)
        .frame(maxWidth: inline ? 640 : .infinity,
               maxHeight: docked ? .infinity : nil, alignment: docked ? .topLeading : .leading)
        // Das Panel liefert Fläche, Rand und Schatten selbst (ComposePanelView);
        // im Fenster und unter dem Thread bleibt die Karte wie bisher.
        .background(docked ? nil : RoundedRectangle(cornerRadius: 12).fill(theme.surface.color))
        .overlay(docked ? nil : RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.color, lineWidth: 1))
        .shadow(color: docked ? .clear : theme.accent.color.opacity(0.25), radius: 10, y: 6)
        .background(WindowProbe(window: $window))
        .onAppear {
            if docked { AppModel.shared.compose.takeFocus(draft.id) }
            if inline { AppModel.shared.compose.takeInlineFocus(draft.id) }
            draft.editorHost = editor
            editor.onMentionPick = { suggestion in draft.addRecipient(suggestion.address) }
            // Esc first closes an open popup, only then the draft: with the
            // link field open, Esc used to throw the whole mail away (M2.6
            // walkthrough).
            editor.onEscape = {
                if linkOpen {
                    linkOpen = false
                    editor.focus()
                } else if !mentionSuggestions.isEmpty {
                    mentionSuggestions = []
                    editor.mentionSuggestions = []
                    editor.focus()
                } else if let onEscape {
                    onEscape()
                } else {
                    discard()
                }
            }
            focus = initialField
            if initialField != .to {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { editor.focus() }
            }
            installKeyMonitor()
            #if DEBUG || CORAX_TEST_HOOKS
            logComposeFocus()
            #endif
            if draft.mode == .reply || draft.mode == .replyAll {
                Task { await draft.loadQuickReplies() }
            }
        }
        .onDisappear {
            removeKeyMonitor()
            if inline { AppModel.shared.compose.releaseInlineFocus(draft.id) }
        }
        .onChange(of: aiOpen) { _, open in
            if open { DispatchQueue.main.async { aiFocused = true } }
        }
        // `⌃Tab` (und `C`) legen den Fokus in den Editor des Panels.
        .onChange(of: focusRequest) { _, _ in
            guard docked, AppModel.shared.compose.keyboardFocus == draft.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { editor.focus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .coraxComposeAI)) { note in
            guard isKeyWindow, note.isFor(draft.id) else { return }
            switch note.object as? String {
            case "draft": withAnimation(Motion.animation) { aiOpen = true }
            case "proofread": Task { await draft.aiProofread() }
            default: break
            }
        }
        .modifier(ComposeDefaultFocus(focus: $focus, field: initialField, active: presentation == .window))
        // Esc: an open popup closes first, only then the draft. SwiftUI runs
        // this handler for a TextField's Esc even when the child already
        // consumed it — without the check, closing the link field threw the
        // whole mail away (M2.6 walkthrough).
        .onExitCommand {
            if linkOpen {
                linkOpen = false
                editor.focus()
            } else if !mentionSuggestions.isEmpty {
                mentionSuggestions = []
                editor.mentionSuggestions = []
                editor.focus()
            } else if let onEscape {
                onEscape()
            } else {
                discard()
            }
        }
        // M2.5: Dateien per Drag & Drop, Zeitwahl, Textbausteine.
        .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in
            dropActive = false
            Task { await acceptDrop(providers) }
            return true
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.color, lineWidth: dropActive ? 2 : 0)
            .allowsHitTesting(false))
        .sheet(isPresented: $sendLaterOpen) { sendLaterSheet }
        .sheet(isPresented: $snippetOpen) { snippetSheet }
        .onReceive(NotificationCenter.default.publisher(for: .coraxComposeAction)) { note in
            guard isKeyWindow, note.isFor(draft.id) else { return }
            handleComposeAction(note.object as? String ?? "")
        }
    }

    /// M2.5: the two small sheets (delivery time, text module). Separate computed
    /// properties keep the view builder of the composer short.
    @ViewBuilder private var sendLaterSheet: some View {
        SendLaterSheet(theme: theme) { date in
            sendLaterOpen = false
            send(.later(date))
        }
    }

    @ViewBuilder private var snippetSheet: some View {
        SnippetPickerView(theme: theme) { snippet in
            snippetOpen = false
            draft.insertSnippet(snippet)
            editor.focus()
        }
    }

    /// The composer only reacts to the menu and to `⌘Z` while it holds the key
    /// window, so several open drafts never fight over one keystroke.
    private var isKeyWindow: Bool { window != nil && NSApp.keyWindow === window }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘Z takes an AI change back. Without one the event goes on to the
            // text view's own undo, so typing undo keeps working.
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "z",
               draft.undoAIChange() {
                return nil
            }
            // M2.5: die Sende-Varianten und die Anhänge.
            let lower = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags == [.command, .shift], event.keyCode == 36 { send(.done); return nil }   // ⌘⇧↵
            if flags == [.command, .shift], lower == "l" { sendLaterOpen = true; return nil } // ⌘⇧L
            if flags == [.command, .shift], lower == "z" { send(.instant); return nil }      // ⌘⇧Z
            if flags == [.command, .shift], lower == "a" { attachFiles(); return nil }       // ⌘⇧A
            if flags == .command, lower == ";" { snippetOpen = true; return nil }            // ⌘;
            // M2.6: ⌘K opens the link field here, before the menu's palette.
            if flags == .command, lower == "k", editor.hasFocus {
                withAnimation(Motion.animation) { linkOpen = true }
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    #if DEBUG || CORAX_TEST_HOOKS
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

    /// Where the keyboard goes when the composer appears: "An" for a new mail
    /// (no recipients yet), the body for a reply/forward (M2.6: the editor).
    private var initialField: Field { draft.to.isEmpty ? .to : .subject }

    // MARK: KI-Bausteine

    private var aiBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AIBadge(label: draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Entwurf" : "Ändern")
                HStack(spacing: 6) {
                    TextField(Strings.aiDraftPlaceholder, text: $aiInstruction)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($aiFocused)
                        .onSubmit { runDraft(aiInstruction) }
                        .accessibilityLabel(Strings.aiDraftTitle)
                    if draft.aiBusy {
                        // M2.4: the text appears while the model writes it.
                        if draft.aiStreaming {
                            Text("Text entsteht …").font(.system(size: 11)).foregroundStyle(theme.ink3.color)
                        }
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Erzeugen") { runDraft(aiInstruction) }
                            .controlSize(.small)
                            .disabled(aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover.color))
            }
            HStack(spacing: 6) {
                ForEach(editPresets, id: \.self) { preset in
                    Button(preset) { runDraft(preset) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(theme.hover.color))
                        .foregroundStyle(theme.ink2.color)
                        .disabled(draft.aiBusy)
                }
                Spacer(minLength: 0)
            }
            if let failure = draft.aiFailure {
                HStack(spacing: 8) {
                    Text(failure.text).font(.system(size: 11)).foregroundStyle(theme.ink2.color)
                    if failure == .notConfigured {
                        Button(Strings.aiNeedsSetup) { SettingsNavigation.request(.intelligence) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.accent.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.accent.color.opacity(0.3), lineWidth: 0.6))
    }

    private func proofreadBox(_ suggestion: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AIBadge(label: Strings.aiProofreadTitle)
                Spacer()
                Button(Strings.aiProofreadApply) { draft.acceptProofread() }
                    .controlSize(.small)
                Button(Strings.aiProofreadDiscard) { draft.discardProofread() }
                    .controlSize(.small)
            }
            ScrollView {
                Text(suggestion)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 72)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.hover.color))
    }

    private var undoBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
            Button(Strings.aiUndoChange) { draft.undoAIChange() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
            KeyCap("⌘Z")
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.ink2.color)
    }

    private var quickReplyRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(draft.quickReplies, id: \.self) { reply in
                Button { draft.useQuickReply(reply) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 9))
                        Text(reply).lineLimit(1)
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(theme.accent.color.opacity(0.12)))
                    .foregroundStyle(theme.ink2.color)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Antwort übernehmen")
                .accessibilityLabel("Schnellantwort: \(reply)")
            }
        }
    }

    /// `ai_draft_actions`: the typed follow-up the core proposed for the draft.
    private var followUpRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(draft.draftActions.enumerated()), id: \.offset) { _, action in
                Button {
                    AppModel.shared.createEventFromSuggestion(action.suggestion)
                    draft.removeDraftAction(action)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar.badge.plus").font(.system(size: 9))
                        Text("Termin anlegen: \(action.suggestion.title)").lineLimit(1)
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(theme.accent.color.opacity(0.12)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Termin aus dem Entwurf anlegen (prüfen und speichern)")
            }
        }
    }

    private func runDraft(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            if await draft.aiDraft(instruction: trimmed) {
                aiInstruction = ""
                withAnimation(Motion.animation) { aiOpen = false }
                editor.focus()
            }
        }
    }

    // MARK: Recipients

    /// "Cc: name ✕" — a reply-all keeps its recipients visible (M2.4).
    private var ccRow: some View {
        HStack(spacing: 6) {
            Text("Cc:").foregroundStyle(theme.ink3.color)
            ForEach(draft.cc, id: \.email) { address in
                HStack(spacing: 4) {
                    Text(address.name ?? address.email).lineLimit(1)
                    Button { draft.removeCc(address) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(address.email) entfernen")
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(theme.hover.color))
                .help(address.email)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    /// Bcc from a `mailto:` link: visible, so nothing is sent to a hidden
    /// recipient the user never saw.
    private var bccRow: some View {
        HStack(spacing: 6) {
            Text("Bcc:").foregroundStyle(theme.ink3.color)
            ForEach(draft.bcc, id: \.email) { address in
                Text(address.email)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(theme.hover.color))
                    .help("Blindkopie aus dem mailto:-Link")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

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
                    editor.focus()
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

    private func send(_ variant: ComposeDraft.SendVariant = .now) {
        let model = AppModel.shared
        // `send_done` also archives the answered thread, like Tauri's send_done.
        let threadId = draft.threadId
        draft.send(variant: variant, onSent: {
            model.composeDraftLeft(draft, presentation: presentation) { onClose?() }
            if variant == .done, let threadId, model.mailbox.index(of: threadId) != nil {
                model.mailbox.archive(threadId)
                PerfLog.shared.write("send_done thread=\(threadId)")
            }
        }, onUndo: { restored in
            model.composeDraftReturned(restored, presentation: presentation)
        })
    }

    /// The composer commands from the menu, the palette or a key.
    ///
    /// The hook-only commands of the acceptance walkthrough (`fmt:`, `embed:`,
    /// `type:`, …) sit behind `CORAX_TEST_HOOKS`: they must not exist in the
    /// release build, where the notification name alone could reach them.
    private func handleComposeAction(_ command: String) {
        switch command {
        case "send_done": send(.done)
        case "send_later": sendLaterOpen = true
        case "instant_send": send(.instant)
        case "attach": attachFiles()
        case "snippet": snippetOpen = true
        default:
            if command.hasPrefix("quote:") {
                draft.insertQuote(String(command.dropFirst("quote:".count)))
                return
            }
            #if DEBUG || CORAX_TEST_HOOKS
            hookComposeAction(command)
            #endif
        }
    }

    #if DEBUG || CORAX_TEST_HOOKS
    private func hookComposeAction(_ command: String) {
        if command.hasPrefix("fmt:") {
            applyFormat(String(command.dropFirst("fmt:".count)))
        } else if command.hasPrefix("link:") {
            editor.applyLink(String(command.dropFirst("link:".count)))
        } else if command.hasPrefix("embed:") {
            embedImage(path: String(command.dropFirst("embed:".count)))
        } else if command.hasPrefix("mention:") {
            mention(String(command.dropFirst("mention:".count)))
        } else if command.hasPrefix("type:") {
            let text = String(command.dropFirst("type:".count))
                .replacingOccurrences(of: "\\n", with: "\n")
            editor.typeForHook(text)
        } else if command == "selectall" {
            editor.selectAllForHook()
        } else if command == "focus" {
            editor.focus()
            PerfLog.shared.write("compose_focus_hook responder=\(String(describing: window?.firstResponder.map { type(of: $0) }))")
        } else if command == "roundtrip" {
            PerfLog.shared.write("compose_roundtrip \(editor.roundTripReport())")
        } else if command == "save" {
            Task {
                let ok = await draft.saveNow()
                PerfLog.shared.write("compose_save ok=\(ok ? 1 : 0) html=\(draft.bodyHtml.count) "
                                     + "text=\(RichHTML.plainText(html: draft.bodyHtml).count)")
            }
        } else if command == "mentionpick" {
            let taken = editor.pickFirstMention()
            mentionSuggestions = []
            PerfLog.shared.write("mention_pick_hook email=\(taken ?? "none") "
                                 + "suggestions=\(editor.mentionSuggestions.count)")
        } else if command == "probecontacts" {
            for query in ["a", "an", "ul", "ulrike", "bah", "jana", "st", "sa"] {
                Task {
                    let found = await draft.suggestions(for: query)
                    PerfLog.shared.write("contacts q=\(query) n=\(found.count) "
                                         + "first=\(found.first?.email ?? "-")")
                }
            }
        } else if command == "bodyhtml" {
            let html = draft.bodyHtml
            let counts = ["<p>", "<b>", "<i>", "<u>", "<s>", "<ul>", "<ol>", "<li>", "<blockquote>",
                          "<a href", "<img", "co-mention", "co-signature"]
                .map { "\($0)=\(html.components(separatedBy: $0).count - 1)" }
                .joined(separator: " ")
            PerfLog.shared.write("compose_html bytes=\(html.count) text=\(draft.aiBodyText.count) "
                                 + "tags=\(counts) head=\(html.prefix(160).debugDescription) "
                                 + "tail=\(html.suffix(160).debugDescription)")
        } else if command == "signature" {
            PerfLog.shared.write("compose_signature bytes=\(draft.signatureHtml?.count ?? 0)")
        }
    }

    /// `mention:<query>` in the hook build: looks the query up and takes the
    /// first suggestion, so the sandbox run needs no pointer.
    private func mention(_ payload: String) {
        handleMentionQuery(payload)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let first = mentionSuggestions.first else {
                PerfLog.shared.write("mention_none q=\(payload)")
                return
            }
            pickMention(first)
        }
    }
    #endif

    // MARK: Formatierung und Erwähnungen (M2.6)

    /// The format commands of the hook build and the palette.
    private func applyFormat(_ name: String) {
        switch name {
        case "bold": editor.toggleBold()
        case "italic": editor.toggleItalic()
        case "underline": editor.toggleUnderline()
        case "strike": editor.toggleStrike()
        case "bullet": editor.toggleList(.bullet)
        case "ordered": editor.toggleList(.ordered)
        case "quote": editor.toggleQuote()
        case "clear": editor.clearFormatting()
        default: PerfLog.shared.write("fmt_unknown name=\(name)")
        }
        PerfLog.shared.write("fmt kind=\(name) active=\(editor.state)")
    }

    /// The `@` list: the same contact lookup the recipient field uses.
    private func handleMentionQuery(_ query: String?) {
        guard let query else {
            mentionSuggestions = []
            editor.mentionSuggestions = []
            PerfLog.shared.write("mention_closed")
            return
        }
        Task {
            let found = await draft.suggestions(for: query)
            mentionSuggestions = found
            editor.mentionSuggestions = found
            PerfLog.shared.write("mention_query q_len=\(query.count) n=\(found.count) start=\(editor.mentionStart ?? -1)")
        }
    }

    private func pickMention(_ suggestion: ContactSuggestion) {
        editor.pickMention(suggestion)
        mentionSuggestions = []
        PerfLog.shared.write("mention_pick n=1")
    }

    private func embedImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Einfügen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        embedImage(path: url.path)
    }

    /// Reads a picture from disk and puts it into the body as a `data:` image
    /// (the panel uses it, and the walkthrough calls it with a path).
    private func embedImage(path: String) {
        guard let image = NSImage(contentsOfFile: path) else {
            PerfLog.shared.write("embed_missing path=\(path)")
            return
        }
        guard let encoded = RichTextBridge.encode(image, alt: (path as NSString).lastPathComponent) else {
            PerfLog.shared.write("embed_too_large path=\(path)")
            AppModel.shared.toasts.show("Bild ist zu groß für die Mail (Grenze 2 MB)", isError: true)
            return
        }
        editor.insertImage(encoded)
        PerfLog.shared.write("embed_image mime=\(encoded.mime.rawValue) bytes=\(encoded.data.count) "
                             + "total=\(draft.bodyHtml.count)")
    }

    // MARK: Anhänge (M2.5)

    /// The attached files as chips. A plain horizontal `ScrollView` instead of
    /// the wrapping `FlowLayout`: inside the compose window the wrapping layout
    /// fed its own width back into the window size and looped in layout
    /// (samples showed the infinite `sizeThatFits` chain).
    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(draft.attachments, id: \.self) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 28)
    }

    private func attachmentChip(_ attachment: DraftAttachment) -> some View {
        var sizeText = ""
        if let size = draft.attachmentSize(attachment) { sizeText = Format.size(size) }
        return HStack(spacing: 6) {
            Image(systemName: "paperclip").font(.system(size: 10))
            Text(attachment.filename).lineLimit(1)
            if !sizeText.isEmpty {
                Text(sizeText).font(.system(size: 10.5)).foregroundStyle(theme.ink3.color)
            }
            Button { draft.removeAttachment(attachment) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(attachment.filename) entfernen")
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover.color))
        .help(attachment.filePath)
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Anhängen"
        let response: NSApplication.ModalResponse = panel.runModal()
        guard response == .OK else {
            PerfLog.shared.write("attach_cancelled")
            return
        }
        let paths = panel.urls.map(\.path)
        let added = draft.addAttachments(paths: paths)
        PerfLog.shared.write("attach_pick n=\(added) total=\(draft.attachments.count)")
    }

    private func acceptDrop(_ providers: [NSItemProvider]) async {
        var paths: [String] = []
        for provider in providers {
            let identifier = UTType.fileURL.identifier
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    continuation.resume(returning: item as? Data)
                }
            }
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { continue }
            paths.append(url.path)
        }
        let added = draft.addAttachments(paths: paths)
        PerfLog.shared.write("attach_drop n=\(added) total=\(draft.attachments.count)")
    }

    private func discard() {
        switch presentation {
        case .inline: AppModel.shared.discardInlineDraft()
        case .docked: AppModel.shared.discardDockedDraft(draft.id)
        case .window: draft.discard(); onClose?()
        }
    }

    /// Höhe des Editors: unter dem Thread knapp, im Fenster großzügig, im
    /// Panel füllt er den Rest (Entwurf §3.2).
    private var editorMinHeight: CGFloat {
        switch presentation {
        case .inline: 84
        case .window: 200
        case .docked: 120
        }
    }
}

/// The window this view lives in (needed to tell which composer holds the
/// keyboard when several drafts are open).
struct WindowProbe: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window { DispatchQueue.main.async { window = nsView.window } }
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

/// `⌥C` bzw. „In eigenem Fenster": der Entwurf als eigenes Fenster. Der
/// Gegenweg steht in der Kopfzeile („Im Hauptfenster andocken", M2.9 §3.3).
struct ComposeWindowView: View {
    let draftID: UUID?
    @Environment(\.dismiss) private var dismiss
    private var model: AppModel { AppModel.shared }

    var body: some View {
        Group {
            if let draftID, let draft = model.composeDrafts[draftID] {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(draft.title).font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 8)
                        Button {
                            model.dockComposeWindow(draftID)
                            dismiss()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "rectangle.bottomhalf.inset.filled")
                                Text("Im Hauptfenster andocken")
                            }
                            .font(.system(size: 11.5))
                        }
                        .buttonStyle(.plain)
                        .help("Zurück ins Verfassen-Panel")
                    }
                    ComposeView(draft: draft, presentation: .window) { dismiss() }
                }
                .padding(18)
            } else {
                Text("Kein Entwurf").padding()
            }
        }
        // Das Fenster schließt per rotem Knopf ohne Senden: der Entwurf wandert
        // dann als Leiste ins Dock, statt unsichtbar liegen zu bleiben (M2.9).
        .onDisappear { if let draftID { model.composeWindowClosed(draftID) } }
        // Tall enough for the AI bar, a proofread proposal and the undo row
        // without clipping the send row (M2.3).
        .frame(minWidth: 540, minHeight: 600)
        .environment(\.theme, model.theme)
        .background(model.theme.win.color)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
    }
}


/// The bottom row of the composer (M2.5: hint, AI, attachments, snippet,
/// "Senden" with its variants). A separate view so the body stays type-checkable.
private struct ComposeFooter: View {
    @Bindable var draft: ComposeDraft
    let theme: Theme
    let onDismissHint: Bool
    /// „verwerfen" unter dem Thread und im Fenster, „minimieren" im Panel.
    var escHint: String = "verwerfen"
    /// Unter dem Thread: „Lösen" ins Panel (§3.7).
    var onDetach: (() -> Void)? = nil
    let onAI: () -> Void
    let onAttach: () -> Void
    let onSnippet: () -> Void
    let onSend: () -> Void
    let onDone: () -> Void
    let onLater: () -> Void
    let onInstant: () -> Void

    var body: some View {
        // Kompakt: Symbol + Kürzel, die Erklärung im Tooltip. Mit Text wurden die
        // Knöpfe im 620-pt-Fenster umbrochen und "Senden" abgeschnitten (M2.5-
        // Walkthrough, Screenshot m25-attachments.png).
        HStack(spacing: 8) {
            HStack(spacing: 5) { KeyCap("Esc"); Text(escHint) }
                .fixedSize()
            iconButton("sparkles", "⌘J", help: "Mit KI schreiben (⌘J)", tint: theme.accent.color, action: onAI)
            iconButton("paperclip", "⌘⇧A", help: "Dateien anhängen (⌘⇧A)", action: onAttach)
            iconButton("text.badge.plus", "⌘;", help: "Textbaustein einfügen (⌘;)", action: onSnippet)
            if let onDetach {
                iconButton("rectangle.portrait.and.arrow.right", "⌘⇧M",
                           help: "In das Verfassen-Panel lösen (⌘⇧M)", action: onDetach)
            }
            if draft.savedOnce {
                Text(Strings.draftSaved).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 4)
            Button(action: onSend) {
                HStack(spacing: 6) {
                    Text(Strings.send).fontWeight(.semibold)
                    Text("⌘↵").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.25)))
                }
                .fixedSize()
                .foregroundStyle(theme.accentInk.color)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.color))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.isSending)
            .accessibilityLabel(Strings.send)
            Menu {
                Button("Senden und erledigen", action: onDone)
                Button("Später senden …", action: onLater)
                Divider()
                Button("Sofort senden (ohne Rückgängig)", action: onInstant)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.accentInk.color)
                    .frame(width: 20, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.color))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(draft.isSending)
            .help("Senden-Varianten")
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.ink3.color)
    }

    private func iconButton(_ symbol: String, _ key: String, help: String,
                            tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(key).font(.system(size: 10))
            }
            .fixedSize()
            .foregroundStyle(tint ?? theme.ink2.color)
            .padding(.horizontal, 5)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
