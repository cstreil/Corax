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
    public var to: [Address]
    public var cc: [Address]
    public var subject: String
    public var body: String { didSet { scheduleSave() } }
    public var toText: String = ""
    private(set) var draftId: Int64?
    public private(set) var isSending = false
    public private(set) var savedOnce = false

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
         body: String = "", client: any MailCore, toasts: ToastCenter, settings: SettingsStore) {
        self.mode = mode
        self.accountId = accountId
        self.inReplyToMessageId = inReplyTo
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.client = client
        self.toasts = toasts
        self.settings = settings
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
        return ComposeDraft(mode: mode, accountId: detail.thread.accountId, inReplyTo: last?.id, to: to, cc: cc,
                            subject: prefixed, client: client, toasts: toasts, settings: settings)
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
            .filter { $0.contains("@") }
        for part in parts where !to.contains(where: { $0.email.lowercased() == part.lowercased() }) {
            to.append(Address(name: nil, email: part))
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
        SaveDraftArgs(draftId: draftId, accountId: accountId, to: to, cc: cc, bcc: [], subject: subject,
                      bodyText: body, bodyHtml: nil, mode: mode, inReplyToMessageId: inReplyToMessageId, attachments: [])
    }

    private var blank: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && to.isEmpty && draftId == nil
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
    func saveNow() async -> Bool {
        guard !isSending, !blank else { return !isSending }
        return await enqueueSave().value != nil
    }

    /// `⌘↵`: save, `queue_send`, toast "Gesendet · Rückgängig" for the
    /// configured undo window (`cancel_send`).
    public func send(onSent: @escaping @MainActor () -> Void, onUndo: @escaping @MainActor (ComposeDraft) -> Void) {
        commitToText()
        guard !to.isEmpty else { toasts.show("Mindestens ein Empfänger fehlt", isError: true); return }
        saveTask?.cancel()
        Task {
            // Waits for a running save and uses the id it returns (W2).
            let sendGeneration = generation
            guard let savedId = await enqueueSave().value, !isSending, sendGeneration == generation else { return }
            isSending = true
            do {
                let result = try await client.queueSend(draftId: savedId)
                onSent()
                let seconds = max(2, settings.undoSendSeconds)
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
            } catch {
                isSending = false
                toasts.error(error)
            }
        }
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
                                subject: subject, body: "", client: client, toasts: toasts, settings: settings)
        copy.toText = toText
        copy.body = body          // didSet schedules the save
        return copy
    }

    public var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftId == nil }
}
