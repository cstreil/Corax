import Foundation

/// The part of the core client the stores use.
///
/// A protocol only for testability: the undo, queue and settings paths are
/// exercised against `Tests/RabeTests/FakeCore.swift` without a running Rust
/// core, because the interesting behaviour is the command sequence, not the
/// database behind it. `RabeClient` is the only real implementation.
/// M2.3: the AI commands are part of the same client surface — the composer
/// calls `ai_draft`/`ai_proofread` on the draft it already holds, and the AI
/// stores take any `AICore`, so one protocol keeps both sides in step.
public protocol MailCore: AICore {
    // Reading
    /// `labelId`/`folderId` (M2.9): die Seitenleiste filtert die Liste auf ein
    /// Label oder einen Ordner, so wie Tauri `selectLabel`/`selectFolder`.
    func listThreads(view: MailView, splitId: Int64?, accountId: Int64?, labelId: Int64?,
                     folderId: Int64?, cursor: Int64?, limit: Int) async throws -> ThreadPage
    func getThread(_ id: Int64) async throws -> ThreadDetail
    func getBody(_ messageId: Int64) async throws -> MessageDetail
    func accounts() async throws -> [Account]
    func splits() async throws -> [SplitRule]
    func labels() async throws -> [Label]
    func unreadCounts() async throws -> UnreadCounts
    func search(_ query: String, accountId: Int64?) async throws -> SearchResults
    func openAttachment(_ id: Int64) async throws
    func saveAttachment(_ id: Int64, to path: String) async throws
    /// Tells the core that the first list is on screen.
    nonisolated func notifyUiReady()

    // M2.4: sender pictures, one-time codes and unsubscribing.
    /// A `data:` URL for the sender's picture, or nil. The core resolves it
    /// once (Gravatar, BIMI, site icon) and caches it on disk for a week, so the
    /// first call for an address may use the network.
    func senderAvatar(_ email: String) async throws -> String?
    /// The newest one-time code of the last `maxAgeMinutes`, or nil.
    func latestVerificationCode(maxAgeMinutes: Int?) async throws -> VerificationCode?
    /// The message of a thread that carries a `List-Unsubscribe` header, or nil.
    func threadUnsubscribeMessage(threadId: Int64) async throws -> Int64?
    /// Runs the unsubscribe (RFC 8058 one-click POST, mailto send, or a URL).
    func unsubscribeMessage(messageId: Int64) async throws -> UnsubscribeOutcome

    // Actions
    func performAction(_ kind: ActionKind, threadIds: [Int64], params: ActionParams?) async throws -> ActionResult
    func undoLast() async throws -> Bool
    /// M2.5: IMAP folders of one account, for "Verschieben" (`V`).
    func listFolders(accountId: Int64?) async throws -> [FolderInfo]
    /// M2.5: "Jetzt synchronisieren".
    func syncNow(accountId: Int64?) async throws

    // Compose
    func suggestContacts(_ query: String) async throws -> [ContactSuggestion]
    func saveDraft(_ args: SaveDraftArgs) async throws -> Int64
    func deleteDraft(_ id: Int64) async throws
    /// `sendAt` = nil sends after the configured undo window; a timestamp picks
    /// the delivery time ("Später senden"), `now` sends without the window
    /// ("Sofort senden"). The core supports both through `QueueSendArgs.send_at`.
    func queueSend(draftId: Int64, sendAt: Int64?) async throws -> QueueSendResult
    func cancelSend(actionId: Int64) async throws -> Bool

    // Settings (the object stays untyped, see `RabeClient`)
    func settingsJSON() async throws -> String
    func setSettingsJSON(_ settingsObjectJSON: String) async throws

    // Settings editors (M2.1): accounts, snippets, labels, splits/rules, MCP.
    func setAccountDisplayName(accountId: Int64, name: String) async throws -> Account
    func removeAccount(_ id: Int64) async throws

    func listSnippets() async throws -> [Snippet]
    func saveSnippet(_ input: SnippetInput) async throws -> Snippet
    func deleteSnippet(_ id: Int64) async throws

    func saveLabel(_ input: LabelInput) async throws -> Label
    func deleteLabel(_ id: Int64) async throws
    func restoreAutoLabels() async throws -> Int64
    func createCategory(name: String, color: String, description: String) async throws -> Label

    func saveSplit(_ input: SplitInput) async throws -> SplitRule
    func deleteSplit(_ id: Int64) async throws
    func reorderTabs(_ order: [TabRef]) async throws
    func previewSplitCondition(_ condition: RuleCondition, limit: Int64?) async throws -> ConditionPreview
    /// Re-runs auto-label classification over stored mail; returns the count.
    func relabelAutoLabels() async throws -> Int64

    // MCP. `mcpToken()`/`mcpRegenerateToken()` return the access token; it is
    // masked in the store and must never reach a log or a report.
    func mcpStatus() async throws -> McpStatus
    func mcpActivity() async throws -> [McpCall]
    func mcpListClients() async throws -> [McpClientInfo]
    func mcpToken() async throws -> String
    func mcpRegenerateToken() async throws -> String
    func mcpClientSnippet(id: String) async throws -> String
    func mcpInstallClient(id: String) async throws -> McpInstallResult

    // M3.4 — Google-Anmeldung. `startOAuth` antwortet erst nach dem Rücksprung
    // aus dem Browser; `cancelOAuth` beendet das Warten.
    func startOAuth(provider: OAuthProvider) async throws -> Account
    func reauthAccount(id: Int64) async throws -> Account
    func cancelOAuth() async throws
}

/// The actor's methods satisfy the async requirements directly; `notifyUiReady`
/// is nonisolated there for the same reason it is here.
extension RabeClient: MailCore {}

extension MailCore {
    /// The plain actions (archive, star, mark read …) send no params.
    func performAction(_ kind: ActionKind, threadIds: [Int64]) async throws -> ActionResult {
        try await performAction(kind, threadIds: threadIds, params: nil)
    }

    /// Snooze: `wakeAt` is the only param.
    func performAction(_ kind: ActionKind, threadIds: [Int64], wakeAt: Int64?) async throws -> ActionResult {
        try await performAction(kind, threadIds: threadIds,
                                params: wakeAt.map { ActionParams(wakeAt: $0) })
    }

    /// The undo window path (`send` in the composer).
    func queueSend(draftId: Int64) async throws -> QueueSendResult {
        try await queueSend(draftId: draftId, sendAt: nil)
    }
}
