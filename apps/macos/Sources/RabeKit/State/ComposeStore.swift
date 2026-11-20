import Foundation
import Observation

/// One draft (inline reply or compose window). Port of the reply rules in
/// `src/components/compose/Composer.tsx` for the M1 text-only composer:
/// recipients, subject prefix, draft autosave (1 s debounce), send with undo.
@MainActor
@Observable
public final class ComposeDraft: Identifiable {
    public let id = UUID()
    public let mode: ComposeMode
    public let accountId: Int64
    let inReplyToMessageId: Int64?
    /// The thread the draft answers (nil for a fresh mail); `ai_draft` and
    /// `ai_quick_replies` take it.
    public let threadId: Int64?
    /// Display name of the account, sent to `ai_draft` as `senderName`.
    private let senderName: String?
    /// The AI half of the client. Normally the same object as `client`; the
    /// sandbox walkthrough swaps in a canned provider (hook builds only).
    private let aiClient: (any AICore)?
    public var to: [Address]
    public var cc: [Address]
    /// Bcc recipients (from a `mailto:` link; the composer shows them but does
    /// not edit them).
    public var bcc: [Address] = []
    /// M2.5: files to send with this draft. The core stages them again on save
    /// (`stage_draft_attachment`), so the paths here are the user's originals.
    public private(set) var attachments: [DraftAttachment] = []
    /// File sizes per path. Read **off** the main thread when a file is added:
    /// a file in iCloud Drive blocks in `attributesOfItem` until it is
    /// downloaded, and doing that while SwiftUI lays out the chip froze the app
    /// (found in the M2.5 walkthrough, `sample` showed the main thread inside
    /// `attributesOfItem`).
    public private(set) var attachmentSizes: [String: Int64] = [:]
    public var subject: String
    /// The rich body (M2.6): the composer's HTML subset, exactly what goes out
    /// as `text/html`. The editor writes into it through `syncEditorBody`,
    /// everything else (AI text, snippet, quote, signature) through `body`.
    public private(set) var bodyHtml: String
    /// Bumped whenever the body changed from *outside* the editor. The editor
    /// reloads when it sees a new revision; its own edits do not bump it.
    public private(set) var bodyRevision = 0
    /// The account's default signature as HTML (`div.co-signature`), nil when
    /// the account has none.
    public private(set) var signatureHtml: String?
    /// The editor on screen, if any: snippets and quotes land at the caret.
    public weak var editorHost: (any ComposeEditorHost)?

    /// The plain text of the whole body, signature and quote included — this is
    /// what `text/plain` carries and what the AI is *not* shown (see
    /// `RichHTML.aiPlainText`).
    public var body: String {
        get { RichHTML.plainText(html: bodyHtml) }
        set { replaceBody(RichHTML.html(fromPlainText: newValue)) }
    }
    public var toText: String = ""
    private(set) var draftId: Int64?
    public private(set) var isSending = false
    public private(set) var savedOnce = false

    // MARK: KI (M2.3)

    /// A `ai_draft`/`ai_proofread` call is running.
    public private(set) var aiBusy = false
    public private(set) var aiFailure: AIFailure?
    /// M2.4: the `ai_draft` call streams its text; the body grows while it runs.
    public private(set) var aiStreaming = false
    /// The `requestId` of the running `ai_draft` call; streamed tokens carry it.
    public private(set) var aiRequestId: String?
    /// The proofread result, waiting for the user to accept or discard it.
    public private(set) var proofreadSuggestion: String?
    /// The body (HTML) before the last applied AI change; `⌘Z` restores it.
    public private(set) var aiUndoHtml: String?
    /// Follow-ups the core proposed for the finished draft (a calendar event).
    public private(set) var draftActions: [AIDraftAction] = []
    /// One-tap reply suggestions for a reply draft (`ai_quick_replies`).
    public private(set) var quickReplies: [String] = []

    /// Body before the running `ai_draft` (the undo target), and the stream.
    private var aiBaseHtml: String?
    private var streamRaw = ""
    private var streamThrottle = TokenThrottle()

    private let client: any MailCore
    private let toasts: ToastCenter
    private let settings: SettingsStore
    /// Debounce timer of the autosave.
    private var saveTask: Task<Void, Never>?
    /// Every save runs behind the previous one (W2): a second save never starts
    /// before the first has returned its `draftId`, so no orphan draft appears.
    private var saveChain: Task<Int64?, Never>?
    /// Bumped by `discard()`; a save that returns later must not resurrect it.
    private var generation = 0
    /// Every draft id a queued save produced, including saves whose generation
    /// `discard()` already ended (R-W2): `discard` deletes all of them, so no
    /// orphan survives two saves queued back to back.
    private var producedDraftIds: Set<Int64> = []
    /// The task that deletes the discarded drafts, for the test to await.
    private var discardTask: Task<Void, Never>?

    public init(mode: ComposeMode, accountId: Int64, inReplyTo: Int64?, to: [Address], cc: [Address], subject: String,
         body: String = "", threadId: Int64? = nil, senderName: String? = nil,
         client: any MailCore, aiClient: (any AICore)? = nil, toasts: ToastCenter, settings: SettingsStore) {
        self.mode = mode
        self.accountId = accountId
        self.inReplyToMessageId = inReplyTo
        self.threadId = threadId
        self.senderName = senderName
        self.to = to
        self.cc = cc
        // W1: a line break in the subject is a second header line in the sent
        // mail (`mail-builder` writes it raw). The `mailto:` path and the
        // `Re: `/`Fwd: ` prefixes both end up here.
        self.subject = HeaderSafety.subject(subject)
        self.bodyHtml = RichHTML.html(fromPlainText: body)
        self.client = client
        self.aiClient = aiClient
        self.toasts = toasts
        self.settings = settings
        if let signature = Self.defaultSignature(settings: settings, accountId: accountId, mode: mode) {
            signatureHtml = signature.html
            bodyHtml = RichHTML.settingSignature(html: bodyHtml, signatureHTML: signature.html)
        }
    }

    /// The signature the account's defaults pick for this mode (Tauri's
    /// `pickSignature`): `newId` for fresh mail, `replyId` for replies.
    public static func defaultSignature(settings: SettingsStore, accountId: Int64,
                                        mode: ComposeMode) -> Signature? {
        let defaults = settings.signatureDefaults[String(accountId)]
        let id = mode == .new ? defaults?.newId : defaults?.replyId
        guard let id, !id.isEmpty else { return nil }
        return settings.signatures.first { $0.id == id && $0.accountId == accountId }
    }

    // MARK: Rich-Text (M2.6)

    /// The editor's own change: store it, but do not make the editor reload.
    public func syncEditorBody(_ html: String) {
        guard html != bodyHtml else { return }
        bodyHtml = html
        scheduleSave()
    }

    /// A change from outside the editor (AI, snippet, quote, signature, undo).
    private func replaceBody(_ html: String) {
        guard html != bodyHtml else { return }
        bodyHtml = html
        bodyRevision += 1
        scheduleSave()
    }

    /// Replaces the draft's own text and keeps quote and signature (AI result,
    /// quick reply, proofread).
    private func setContentText(_ text: String) {
        replaceBody(RichHTML.replacingContent(html: bodyHtml, withText: text))
    }

    /// Swaps the signature block (`nil` removes it).
    public func setSignature(_ html: String?) {
        signatureHtml = html
        replaceBody(RichHTML.settingSignature(html: bodyHtml, signatureHTML: html ?? ""))
    }

    /// The text the AI works on: without signature, without the quoted original.
    public var aiBodyText: String { RichHTML.aiPlainText(html: bodyHtml) }

    /// Puts the quoted original into a fresh reply (`A`/`⇧A`): below the caret,
    /// below the signature (mail order: text, signature, quote).
    public func quoteOriginal(_ html: String) {
        guard !html.isEmpty else { return }
        replaceBody(RichHTML.settingQuote(html: bodyHtml, quoteHTML: html))
    }

    public var title: String {
        switch mode {
        case .new: Strings.newMail
        case .reply: Strings.reply
        case .replyAll: Strings.replyAll
        case .forward: Strings.forward
        }
    }

    /// Builds a reply/forward from `messageId` (the focused message), else the
    /// thread's newest message.
    public static func reply(mode: ComposeMode, to detail: ThreadDetail, messageId: Int64? = nil, selfEmails: Set<String>,
                      senderName: String? = nil, aiClient: (any AICore)? = nil,
                      client: any MailCore, toasts: ToastCenter, settings: SettingsStore) -> ComposeDraft {
        let last = detail.messages.first(where: { $0.id == messageId && !$0.isDraft })
            ?? detail.messages.last(where: { !$0.isDraft }) ?? detail.messages.last
        let subject = detail.thread.subject
        var to: [Address] = []
        var cc: [Address] = []
        if let last {
            let isOwn = last.isOutgoing || selfEmails.contains(last.from.email.lowercased())
            switch mode {
            case .reply:
                to = isOwn ? last.to : [last.from]
            case .replyAll:
                let primary = isOwn ? last.to : [last.from]
                let others = (last.to + last.cc).filter { addr in
                    !selfEmails.contains(addr.email.lowercased()) && !primary.contains { $0.email.lowercased() == addr.email.lowercased() }
                }
                to = primary
                cc = dedupe(others)
            case .forward, .new:
                break
            }
        }
        let prefixed: String
        switch mode {
        case .forward: prefixed = prefix(subject, "Fwd: ", known: ["fwd:", "fw:", "wg:"])   // compose:forwardPrefix
        case .new: prefixed = ""
        default: prefixed = prefix(subject, "Re: ", known: ["re:", "aw:"])                    // compose:replyPrefix
        }
        let draft = ComposeDraft(mode: mode, accountId: detail.thread.accountId, inReplyTo: last?.id, to: to, cc: cc,
                                 subject: prefixed, threadId: detail.thread.id, senderName: senderName,
                                 client: client, aiClient: aiClient, toasts: toasts, settings: settings)
        // The original goes below the caret: a reply quotes it as a
        // `blockquote`, a forward carries Tauri's header block. Without a body
        // (not loaded yet) the draft stays empty rather than quoting a snippet.
        if let last, !last.isDraft, mode != .new {
            let original = (html: last.htmlBody, text: last.textBody)
            let quote = mode == .forward
                ? Quoting.forwardHTML(bodyHTML: original.html, bodyText: original.text, from: last.from,
                                      to: last.to, subject: last.subject, date: last.dateValue)
                : Quoting.replyHTML(bodyHTML: original.html, bodyText: original.text, from: last.from,
                                    date: last.dateValue)
            if !quote.isEmpty { draft.quoteOriginal(quote) }
        }
        return draft
    }

    private static func prefix(_ subject: String, _ p: String, known: [String]) -> String {
        let lower = subject.lowercased()
        return known.contains(where: { lower.hasPrefix($0) }) ? subject : p + subject
    }

    private static func dedupe(_ list: [Address]) -> [Address] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.email.lowercased()).inserted }
    }

    // MARK: Recipients

    /// Commits typed text ("a@b.de, c@d.de") into `to`.
    public func commitToText() {
        let parts = toText.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let usable = parts.filter { $0.contains("@") && HeaderSafety.isUsableAddress($0) }
        for part in usable where !to.contains(where: { $0.email.lowercased() == part.lowercased() }) {
            to.append(Address(name: nil, email: part))
        }
        if usable.count < parts.count {
            toasts.show("Adresse verworfen: Zeilenumbrüche und spitze Klammern gehören nicht in ein Adressfeld",
                        isError: true)
        }
        if !parts.isEmpty { toText = "" }
        scheduleSave()
    }

    public func addRecipient(_ address: Address) {
        if !to.contains(where: { $0.email.lowercased() == address.email.lowercased() }) { to.append(address) }
        toText = ""
        scheduleSave()
    }

    public func removeRecipient(_ address: Address) {
        to.removeAll { $0.email == address.email }
        scheduleSave()
    }

    /// Cc (from a reply-all or a `mailto:` link, M2.4).
    public func removeCc(_ address: Address) {
        cc.removeAll { $0.email == address.email }
        scheduleSave()
    }

    public func suggestions(for query: String) async -> [ContactSuggestion] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return [] }
        return (try? await client.suggestContacts(q)) ?? []
    }

    // MARK: Draft

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            _ = await self.enqueueSave().value
        }
    }

    private var args: SaveDraftArgs {
        SaveDraftArgs(draftId: draftId, accountId: accountId, to: to, cc: cc, bcc: bcc,
                      subject: HeaderSafety.subject(subject),
                      bodyText: RichHTML.plainText(html: bodyHtml),
                      bodyHtml: bodyHtml.isEmpty ? nil : bodyHtml,
                      mode: mode, inReplyToMessageId: inReplyToMessageId, attachments: attachments)
    }

    private var blank: Bool {
        aiBodyText.isEmpty && !RichHTML.hasImages(html: bodyHtml) && to.isEmpty && cc.isEmpty
            && bcc.isEmpty && attachments.isEmpty && draftId == nil
    }

    /// Queues one save behind all running ones and returns its task. Arguments
    /// are read when the save runs, so it always carries the `draftId` of the
    /// save before it instead of creating a second draft.
    private func enqueueSave() -> Task<Int64?, Never> {
        let previous = saveChain
        let enqueueGeneration = generation
        let task = Task<Int64?, Never> { [weak self] in
            _ = await previous?.value
            guard let self else { return nil }
            // R-W2: a save queued before `discard()` must not run at all —
            // otherwise it creates a second draft the discard never hears of.
            guard self.generation == enqueueGeneration else { return nil }
            guard !self.isSending, !self.blank else { return self.draftId }
            let args = self.args
            do {
                let id = try await self.client.saveDraft(args)
                self.producedDraftIds.insert(id)
                // `discard()` bumped the generation while this save ran: its
                // draft is not this draft's any more, `discard` deletes it.
                if self.generation == enqueueGeneration {
                    self.draftId = id
                    self.savedOnce = true
                }
                return id
            } catch {
                self.toasts.error(error)
                return nil
            }
        }
        saveChain = task
        return task
    }

    @discardableResult
    public func saveNow() async -> Bool {
        guard !isSending, !blank else { return !isSending }
        return await enqueueSave().value != nil
    }

    /// `⌘↵`: save, `queue_send`, toast "Gesendet · Rückgängig" for the
    /// configured undo window (`cancel_send`).
    public func send(onSent: @escaping @MainActor () -> Void, onUndo: @escaping @MainActor (ComposeDraft) -> Void) {
        send(variant: .now, onSent: onSent, onUndo: onUndo)
    }

    /// `Esc`: drop the text and the saved draft. A save that is still running is
    /// waited for, and its draft is deleted too — otherwise it would survive as
    /// an orphan (W2).
    public func discard() {
        saveTask?.cancel()
        generation += 1
        let running = saveChain
        saveChain = nil
        draftId = nil
        let previous = discardTask
        discardTask = Task { [weak self] in
            _ = await previous?.value
            _ = await running?.value
            guard let self else { return }
            // R-W2: every id any queued save produced, not only the last one.
            let ids = self.producedDraftIds
            self.producedDraftIds = []
            for id in ids.sorted() { try? await self.client.deleteDraft(id) }
        }
    }

    /// Tests: waits until the drafts of `discard()` are deleted.
    func waitForDiscard() async { await discardTask?.value }

    /// A fresh draft with the same content (undo of `Esc`); saving it creates
    /// a new server-side draft.
    public func restoredCopy() -> ComposeDraft {
        let copy = ComposeDraft(mode: mode, accountId: accountId, inReplyTo: inReplyToMessageId, to: to, cc: cc,
                                subject: subject, body: "", threadId: threadId, senderName: senderName,
                                client: client, aiClient: aiClient, toasts: toasts, settings: settings)
        copy.toText = toText
        copy.attachments = attachments
        copy.signatureHtml = signatureHtml
        copy.body = body          // schedules the save
        return copy
    }

    public var isEmpty: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !RichHTML.hasImages(html: bodyHtml) && draftId == nil
    }

    // MARK: Anhänge und Textbausteine (M2.5)

    /// Adds files picked with the dialog or dropped on the composer. A file that
    /// is already attached (same path) is skipped; a missing file is refused.
    @discardableResult
    public func addAttachments(paths: [String]) -> Int {
        var added = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let name = url.lastPathComponent.isEmpty ? "Anhang" : url.lastPathComponent
            if attachments.contains(where: { $0.filePath == path }) { continue }
            let attachment = DraftAttachment(filePath: path, filename: name)
            attachments.append(attachment)
            measure(attachment)
            added += 1
        }
        if added > 0 { scheduleSave() }
        return added
    }

    public func removeAttachment(_ attachment: DraftAttachment) {
        attachments.removeAll { $0 == attachment }
        attachmentSizes[attachment.filePath] = nil
        scheduleSave()
    }

    /// Reads the size of a freshly added file in the background (see
    /// `attachmentSizes`). Never runs during layout.
    private func measure(_ attachment: DraftAttachment) {
        let path = attachment.filePath
        Task.detached(priority: .utility) { [weak self] in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value
            await MainActor.run { self?.attachmentSizes[path] = size }
        }
    }

    /// Bytes of one attached file (nil until measured or when it vanished).
    public func attachmentSize(_ attachment: DraftAttachment) -> Int64? {
        attachmentSizes[attachment.filePath]
    }

    public var attachmentsBytes: Int64 {
        attachments.reduce(0) { $0 + (attachmentSize($1) ?? 0) }
    }

    /// `insert-snippet`: the text lands at the caret (or at the end), a subject
    /// only when the draft has none yet.
    public func insertSnippet(_ snippet: Snippet) {
        if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let snippetSubject = snippet.subject,
           !snippetSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subject = snippetSubject
        }
        let text = snippet.bodyText
        guard !text.isEmpty else { return }
        let html = RichHTML.html(fromPlainText: text)
        if let editorHost {
            editorHost.insertHTML(html)
        } else {
            replaceBody(RichHTML.appending(html: bodyHtml, html: html))
        }
    }

    /// `quote-selection` (`⇧R`): the marked passage as a `blockquote` at the
    /// caret, with room to answer around it.
    public func insertQuote(_ text: String) {
        let html = Quoting.selectionHTML(text)
        guard !html.isEmpty else { return }
        if let editorHost {
            editorHost.insertHTML(html)
        } else {
            replaceBody(RichHTML.prepending(html: bodyHtml, html: html))
        }
    }

    // MARK: Senden-Varianten (M2.5)

    /// How the draft leaves the composer. `.now` keeps the undo window; `.done`
    /// archives the answered thread after sending; `.later` picks a delivery
    /// time; `.instant` sends without the window. The core supports all four
    /// through `QueueSendArgs.send_at`.
    public enum SendVariant: Equatable {
        case now
        case done
        case later(Date)
        case instant
    }

    public func send(variant: SendVariant, onSent: @escaping @MainActor () -> Void,
                     onUndo: @escaping @MainActor (ComposeDraft) -> Void) {
        commitToText()
        guard !to.isEmpty else { toasts.show("Mindestens ein Empfänger fehlt", isError: true); return }
        guard !isSending else { return }
        saveTask?.cancel()
        let sendAt: Int64?
        let seconds: Int
        switch variant {
        case .now:
            sendAt = nil
            seconds = max(2, settings.undoSendSeconds)
        case .done:
            sendAt = nil
            seconds = max(2, settings.undoSendSeconds)
        case .later(let date):
            sendAt = Int64(date.timeIntervalSince1970 * 1000)
            seconds = 0
        case .instant:
            sendAt = Int64(Date().timeIntervalSince1970 * 1000)
            seconds = 0
        }
        Task {
            let sendGeneration = generation
            guard let savedId = await enqueueSave().value, !isSending, sendGeneration == generation else { return }
            isSending = true
            do {
                let result = try await client.queueSend(draftId: savedId, sendAt: sendAt)
                onSent()
                if let sendAt {
                    let when = Format.messageTime(Date(timeIntervalSince1970: Double(sendAt) / 1000))
                    toasts.show("Gesendet: \(when)")
                    PerfLog.shared.write("send_scheduled at=\(sendAt) action=\(result.actionId)")
                } else {
                    toasts.show("\(Strings.sent)", actionTitle: Strings.undo, duration: TimeInterval(seconds),
                                action: { [weak self] in
                        guard let self else { return }
                        Task {
                            do {
                                if try await self.client.cancelSend(actionId: result.actionId) {
                                    self.isSending = false
                                    onUndo(self)
                                } else {
                                    self.toasts.show(Strings.tooLate)
                                }
                            } catch { self.toasts.error(error) }
                        }
                    })
                }
            } catch {
                isSending = false
                toasts.error(error)
            }
        }
    }

    // MARK: KI (M2.3)

    /// The object the AI calls go to (the canned provider in a hook run).
    private var ai: any AICore { aiClient ?? client }

    /// True while a body change made by the AI can still be taken back.
    public var canUndoAIChange: Bool { aiUndoHtml != nil }

    /// `ai_draft`: with an empty body the instruction produces a fresh draft,
    /// with text in the body it edits that text (Tauri's "Edit with AI").
    /// Returns false on failure; the reason is in `aiFailure`.
    @discardableResult
    public func aiDraft(instruction: String) async -> Bool {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !aiBusy, !isSending else { return false }
        aiBusy = true
        aiFailure = nil
        proofreadSuggestion = nil
        let previousHtml = bodyHtml
        aiBaseHtml = previousHtml
        streamRaw = ""
        streamThrottle = TokenThrottle()
        aiStreaming = false
        let requestId = UUID().uuidString
        aiRequestId = requestId
        let current = aiBodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let text = try await ai.aiDraft(
                threadId: threadId,
                replyToMessageId: inReplyToMessageId,
                instruction: trimmed,
                currentDraft: current.isEmpty ? nil : current,
                senderName: senderName,
                voice: nil,
                hasSignature: nil,
                requestId: requestId)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                rollBackStream()
                aiFailure = .message("Die Antwort war leer")
                aiBusy = false
                return false
            }
            setContentText(cleaned)
            if previousHtml != bodyHtml { aiUndoHtml = previousHtml }
            draftActions = []
            aiBusy = false
            aiStreaming = false
            aiRequestId = nil
            await refreshDraftActions()
            return true
        } catch {
            // A partially streamed body is not the user's text: take it back.
            rollBackStream()
            aiFailure = AIFailure(error)
            aiBusy = false
            aiStreaming = false
            aiRequestId = nil
            return false
        }
    }

    /// One streamed token of the running `ai_draft`; false when it belongs to
    /// another draft's call. Publishing is throttled to 30 updates a second.
    @discardableResult
    public func consumeDraftToken(_ token: AIStreamToken) -> Bool {
        guard token.kind == .draft, aiBusy, let aiRequestId, token.requestId == aiRequestId else { return false }
        streamRaw += token.delta
        if !aiStreaming, !streamRaw.isEmpty {
            aiStreaming = true
            aiUndoHtml = aiBaseHtml
        }
        var throttle = streamThrottle
        let publish = throttle.append(token.delta, at: ProcessInfo.processInfo.systemUptime)
        streamThrottle = throttle
        if publish {
            _ = streamThrottle.take()
            let text = String(streamRaw.drop(while: { $0.isWhitespace }))
            if !text.isEmpty { setContentText(text) }
        }
        return true
    }

    /// Drops text that only streamed in; the body goes back to what it was.
    private func rollBackStream() {
        guard aiStreaming, let base = aiBaseHtml else { return }
        replaceBody(base)
        aiUndoHtml = nil
        streamRaw = ""
    }

    /// `ai_proofread`: the corrected text waits in `proofreadSuggestion` until
    /// the user accepts it (`acceptProofread`) or drops it.
    @discardableResult
    public func aiProofread() async -> Bool {
        guard !aiBusy, !isSending else { return false }
        let current = aiBodyText
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        aiBusy = true
        aiFailure = nil
        defer { aiBusy = false }
        do {
            let corrected = try await ai.proofread(current).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty, corrected != current.trimmingCharacters(in: .whitespacesAndNewlines) else {
                toasts.show(Strings.aiProofreadClean)
                proofreadSuggestion = nil
                return false
            }
            proofreadSuggestion = corrected
            return true
        } catch {
            aiFailure = AIFailure(error)
            return false
        }
    }

    /// Takes the proofread text over; `⌘Z` brings the old text back.
    public func acceptProofread() {
        guard let suggestion = proofreadSuggestion else { return }
        aiUndoHtml = bodyHtml
        setContentText(suggestion)
        proofreadSuggestion = nil
    }

    public func discardProofread() { proofreadSuggestion = nil }

    /// `⌘Z` for an AI change on the text. Returns false when there is nothing
    /// to take back (the field keeps its own undo then).
    @discardableResult
    public func undoAIChange() -> Bool {
        guard let previous = aiUndoHtml else { return false }
        aiUndoHtml = nil
        proofreadSuggestion = nil
        draftActions = []
        replaceBody(previous)
        return true
    }

    /// `ai_draft_actions`: best effort — a missing follow-up is not an error.
    public func refreshDraftActions() async {
        let text = aiBodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { draftActions = []; return }
        draftActions = (try? await ai.aiDraftActions(threadId: threadId, draft: text)) ?? []
    }

    public func removeDraftAction(_ action: AIDraftAction) {
        draftActions.removeAll { $0 == action }
    }

    /// `ai_quick_replies` for a reply draft. Errors stay silent: the composer
    /// simply shows no chips (same fallback as Tauri).
    public func loadQuickReplies() async {
        guard mode == .reply || mode == .replyAll, let threadId, !aiBusy else { return }
        guard let replies = try? await ai.quickReplies(threadId), !replies.isEmpty else { return }
        quickReplies = replies
    }

    /// Puts a quick reply in the body (an AI change, so `⌘Z` takes it back).
    public func useQuickReply(_ text: String) {
        aiUndoHtml = bodyHtml
        setContentText(text)
        quickReplies = []
    }
}
