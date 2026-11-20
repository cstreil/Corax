import Foundation
import RabeBindings
import os

/// Errors surfaced to the UI. The Rust side sends `{code, message}`; the code is
/// the stable token `src/ipc/errors.ts` localizes.
public enum RabeClientError: LocalizedError, Sendable {
    case notStarted
    case core(code: String, message: String)
    case decode(command: String, detail: String)
    case host(String)

    public var code: String {
        switch self {
        case .notStarted: "not_started"
        case .core(let code, _): code
        case .decode: "decode"
        case .host: "unknown"
        }
    }

    public var errorDescription: String? { Strings.errorText(self) }

    public static func from(_ error: Error) -> RabeClientError {
        if let own = error as? RabeClientError { return own }
        if let rabe = error as? RabeError {
            switch rabe {
            case let .Core(code, message): return .core(code: code, message: message)
            }
        }
        return .host(String(describing: error))
    }
}

/// Typed wrappers over the JSON dispatcher (`RabeHost.invoke`). One instance per
/// process; the host is thread-safe, so the actor only serializes encoding and
/// keeps timing in one place.
public actor RabeClient {
    public nonisolated let host: RabeHost
    public nonisolated let dataDirectory: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let signposter = OSSignposter(subsystem: "de.streil.rabe.native", category: "ipc")

    /// Starts the host. Returns as soon as the instance lock is held; the core
    /// starts in the background (`waitReady`).
    public nonisolated static func start(identifier: String, delegate: RabeDelegate) throws -> RabeClient {
        do {
            let host = try RabeHost.start(identifier: identifier, resourceDir: Bundle.main.resourcePath, delegate: delegate)
            return RabeClient(host: host)
        } catch {
            throw RabeClientError.from(error)
        }
    }

    private init(host: RabeHost) {
        self.host = host
        self.dataDirectory = host.dataDir()
    }

    public func waitReady() async throws {
        do { try await host.waitReady() } catch { throw RabeClientError.from(error) }
    }

    public nonisolated func notifyUiReady() { host.notifyUiReady() }
    public nonisolated func shutdown() { host.shutdown() }

    // MARK: Generic call

    /// Set once at launch (`AppModel.init`): a refused command becomes a toast.
    /// The client is an actor and cannot reach the toast center itself; the
    /// handler is only installed before the first command, never changed after.
    nonisolated(unsafe) public static var onRefused: (@Sendable (String) -> Void)?

    public func raw(_ command: String, json: String = "{}") async throws -> String {
        // The visible switch (P2g) is the only way to enable writes; it is read
        // right before sending, so flipping it applies to the next command.
        let writesAllowed = await WriteAccess.shared.allowed
        switch CommandPolicy.decision(for: command, json: json, sandbox: Instance.isSandbox,
                                      writesAllowed: writesAllowed) {
        case .allowed:
            break
        case .writesDisabled:
            throw Self.refuse(command, reason: "writes_disabled", code: "read_only")
        case .notAllowed:
            throw Self.refuse(command, reason: "not_on_list", code: "command_not_allowed")
        case .actionNotAllowed(let kind):
            // The kind is a fixed token from `ActionKind`, never user content.
            throw Self.refuse("\(command):\(kind)", reason: "action_not_allowed", code: "action_not_allowed")
        case .pendingAudit:
            // M2.1: the settings sections work in the sandbox; the real
            // instance waits for the audit.
            throw Self.refuse(command, reason: "pending_audit", code: "pending_audit")
        }
        let state = Self.signposter.beginInterval("invoke", "\(command, privacy: .public)")
        defer { Self.signposter.endInterval("invoke", state) }
        do {
            return try await host.invoke(cmd: command, argsJson: json)
        } catch {
            throw RabeClientError.from(error)
        }
    }

    /// Logs a refusal (command name and reason only, never the arguments) and
    /// hands it to the UI; returns the error for the caller to throw.
    nonisolated private static func refuse(_ command: String, reason: String, code: String) -> RabeClientError {
        PerfLog.shared.write("command_refused cmd=\(command) reason=\(reason)")
        let text = Strings.errorText(.core(code: code, message: ""))
        onRefused?(text)
        return .core(code: code, message: text)
    }

    public func call<R: Decodable & Sendable>(_ command: String, _ args: some Encodable & Sendable, as: R.Type = R.self) async throws -> R {
        let data = try encoder.encode(args)
        let json = try await raw(command, json: String(decoding: data, as: UTF8.self))
        do {
            return try decoder.decode(R.self, from: Data(json.utf8))
        } catch {
            throw RabeClientError.decode(command: command, detail: String(describing: error))
        }
    }

    public func call<R: Decodable & Sendable>(_ command: String, as: R.Type = R.self) async throws -> R {
        try await call(command, Empty(), as: R.self)
    }

    /// For commands whose result the UI ignores (`null`, `{}`).
    public func send(_ command: String, _ args: some Encodable & Sendable) async throws {
        let data = try encoder.encode(args)
        _ = try await raw(command, json: String(decoding: data, as: UTF8.self))
    }

    private struct Empty: Encodable, Sendable {}

    // MARK: Typed commands (names and argument shapes from src/ipc/types.ts)

    public func listThreads(view: MailView, splitId: Int64?, accountId: Int64?, cursor: Int64?, limit: Int) async throws -> ThreadPage {
        try await call("list_threads", IPCArgs.ListThreads(view: view, splitId: splitId, accountId: accountId, cursor: cursor, limit: limit))
    }

    public func getThread(_ id: Int64) async throws -> ThreadDetail {
        try await call("get_thread", IPCArgs.GetThread(threadId: id))
    }

    public func getBody(_ messageId: Int64) async throws -> MessageDetail {
        try await call("get_body", IPCArgs.GetBody(messageId: messageId))
    }

    public func performAction(_ kind: ActionKind, threadIds: [Int64], params: ActionParams? = nil) async throws -> ActionResult {
        try await call("perform_action", WithArgs(args: IPCArgs.PerformAction(kind: kind, threadIds: threadIds, params: params)))
    }

    public func undoLast() async throws -> Bool {
        let result: UndoResult = try await call("undo_last")
        return result.undone
    }

    /// M2.5: "Verschieben" needs the IMAP folders of the account.
    public func listFolders(accountId: Int64?) async throws -> [FolderInfo] {
        try await call("list_folders", IPCArgs.ListFolders(accountId: accountId))
    }

    /// M2.5: "Jetzt synchronisieren". The core answers `null`.
    public func syncNow(accountId: Int64?) async throws {
        try await send("sync_now", IPCArgs.ListFolders(accountId: accountId))
    }

    public func accounts() async throws -> [Account] { try await call("list_accounts") }
    public func splits() async throws -> [SplitRule] { try await call("list_splits") }
    public func labels() async throws -> [Label] { try await call("list_labels") }
    public func unreadCounts() async throws -> UnreadCounts {
        try await call("unread_counts", IPCArgs.UnreadCounts(accountId: nil))
    }
    func syncStatus() async throws -> [SyncStatus] { try await call("get_sync_status") }

    public func search(_ query: String, accountId: Int64?) async throws -> SearchResults {
        try await call("search", WithArgs(args: IPCArgs.Search(query: query, accountId: accountId, limit: 100)))
    }

    public func suggestContacts(_ query: String) async throws -> [ContactSuggestion] {
        try await call("suggest_contacts", IPCArgs.SuggestContacts(query: query, limit: 8))
    }

    public func saveDraft(_ args: SaveDraftArgs) async throws -> Int64 {
        let result: SaveDraftResult = try await call("save_draft", WithArgs(args: args))
        return result.draftId
    }

    public func deleteDraft(_ id: Int64) async throws {
        try await send("delete_draft", IPCArgs.DeleteDraft(draftId: id))
    }

    public func queueSend(draftId: Int64, sendAt: Int64? = nil) async throws -> QueueSendResult {
        try await call("queue_send", WithArgs(args: IPCArgs.QueueSend(draftId: draftId, sendAt: sendAt)))
    }

    public func cancelSend(actionId: Int64) async throws -> Bool {
        struct R: Decodable, Sendable { let cancelled: Bool }
        let result: R = try await call("cancel_send", IPCArgs.CancelSend(actionId: actionId))
        return result.cancelled
    }

    public func openAttachment(_ id: Int64) async throws {
        try await send("open_attachment", IPCArgs.OpenAttachment(attachmentId: id))
    }

    public func saveAttachment(_ id: Int64, to path: String) async throws {
        // dispatch.rs deserializes with `rename_all = "camelCase"`: `attachmentId`.
        try await send("save_attachment", IPCArgs.SaveAttachment(attachmentId: id, dest: path))
    }

    // MARK: M2.4 — avatars, verification codes, unsubscribing

    public func senderAvatar(_ email: String) async throws -> String? {
        try await call("sender_avatar", IPCArgs.SenderAvatar(email: email))
    }

    public func latestVerificationCode(maxAgeMinutes: Int? = nil) async throws -> VerificationCode? {
        try await call("latest_verification_code", IPCArgs.VerificationCode(maxAgeMinutes: maxAgeMinutes))
    }

    public func threadUnsubscribeMessage(threadId: Int64) async throws -> Int64? {
        try await call("thread_unsubscribe_message", IPCArgs.ThreadID(threadId: threadId))
    }

    public func unsubscribeMessage(messageId: Int64) async throws -> UnsubscribeOutcome {
        try await call("unsubscribe_message", IPCArgs.MessageID(messageId: messageId))
    }

    public func testConnection(_ args: AddPasswordAccountArgs) async throws -> ConnectionTestResult {
        try await call("test_connection", WithArgs(args: args))
    }

    public func addAccount(_ args: AddPasswordAccountArgs) async throws {
        try await send("add_account_password", WithArgs(args: args))
    }

    /// Settings stay untyped: the object has ~60 fields and `set_settings` must
    /// always receive all of them (read-modify-write).
    public func settingsJSON() async throws -> String { try await raw("get_settings") }

    public func setSettingsJSON(_ settingsObjectJSON: String) async throws {
        _ = try await raw("set_settings", json: "{\"settings\":" + settingsObjectJSON + "}")
    }

    // MARK: HTML (synchronous, pure)

    public nonisolated func htmlForDisplay(_ html: String, theme: DisplayThemeJSON, loadRemoteImages: Bool) -> String {
        let data = (try? JSONEncoder().encode(theme)) ?? Data()
        return (try? host.htmlForDisplay(html: html, themeJson: String(decoding: data, as: UTF8.self), loadRemoteImages: loadRemoteImages)) ?? ""
    }

    public nonisolated func hasRemoteImages(_ html: String) -> Bool { host.htmlHasRemoteImages(html: html) }
    public nonisolated func darkModeScript() -> String { host.darkModeScript() }
}

/// `DisplayTheme` in rabe-host/src/html.rs. Handed to `wrapForDisplay`, so the
/// app needs it too (`Theme.displayTheme`).
public struct DisplayThemeJSON: Encodable, Sendable {
    public let text: String
    public let textMuted: String
    public let accent: String
    public let colorScheme: String
    public let fontFamily: String?

    public init(text: String, textMuted: String, accent: String, colorScheme: String, fontFamily: String?) {
        self.text = text
        self.textMuted = textMuted
        self.accent = accent
        self.colorScheme = colorScheme
        self.fontFamily = fontFamily
    }
}

/// Arguments of the typed wrappers, one type per command. They are top level so
/// `Tests/RabeTests/IPCContractTests.swift` can encode them and compare the JSON
/// keys against `src/ipc/types.ts` (the dispatcher rejects unknown fields).
enum IPCArgs {
    struct ListThreads: Encodable, Sendable {
        let view: MailView
        let splitId: Int64?
        let accountId: Int64?
        let cursor: Int64?
        let limit: Int
    }
    struct GetThread: Encodable, Sendable { let threadId: Int64 }
    struct GetBody: Encodable, Sendable { let messageId: Int64 }
    /// `PerformActionArgs` (`params`: snooze: wakeAt, move: targetFolderId,
    /// add/remove_label: labelId).
    struct PerformAction: Encodable, Sendable {
        let kind: ActionKind
        let threadIds: [Int64]
        let params: ActionParams?
    }
    /// `list_folders` and `sync_now` share the same single optional argument.
    struct ListFolders: Encodable, Sendable { let accountId: Int64? }
    public struct UnreadCounts: Encodable, Sendable { let accountId: Int64? }
    struct Search: Encodable, Sendable { let query: String; let accountId: Int64?; let limit: Int }
    struct SuggestContacts: Encodable, Sendable { let query: String; let limit: Int }
    struct DeleteDraft: Encodable, Sendable { let draftId: Int64 }
    struct QueueSend: Encodable, Sendable { let draftId: Int64; let sendAt: Int64? }
    struct CancelSend: Encodable, Sendable { let actionId: Int64 }
    struct OpenAttachment: Encodable, Sendable { let attachmentId: Int64 }
    struct SaveAttachment: Encodable, Sendable { let attachmentId: Int64; let dest: String }

    // M2.4
    struct SenderAvatar: Encodable, Sendable { let email: String }
    /// `maxAgeMinutes?: number` in `types.ts`; `Option<i64>` with a default in
    /// the dispatcher, so it may be left out.
    struct VerificationCode: Encodable, Sendable { let maxAgeMinutes: Int? }
    struct ThreadID: Encodable, Sendable { let threadId: Int64 }
    struct MessageID: Encodable, Sendable { let messageId: Int64 }
}
