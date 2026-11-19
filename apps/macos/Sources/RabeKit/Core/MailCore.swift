import Foundation

/// The part of the core client the stores use.
///
/// A protocol only for testability: the undo, queue and settings paths are
/// exercised against `Tests/RabeTests/FakeCore.swift` without a running Rust
/// core, because the interesting behaviour is the command sequence, not the
/// database behind it. `RabeClient` is the only real implementation.
public protocol MailCore: Sendable {
    // Reading
    func listThreads(view: MailView, splitId: Int64?, accountId: Int64?, cursor: Int64?, limit: Int) async throws -> ThreadPage
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

    // Actions
    func performAction(_ kind: ActionKind, threadIds: [Int64], wakeAt: Int64?) async throws -> ActionResult
    func undoLast() async throws -> Bool

    // Compose
    func suggestContacts(_ query: String) async throws -> [ContactSuggestion]
    func saveDraft(_ args: SaveDraftArgs) async throws -> Int64
    func deleteDraft(_ id: Int64) async throws
    func queueSend(draftId: Int64) async throws -> QueueSendResult
    func cancelSend(actionId: Int64) async throws -> Bool

    // Settings (the object stays untyped, see `RabeClient`)
    func settingsJSON() async throws -> String
    func setSettingsJSON(_ settingsObjectJSON: String) async throws
}

/// The actor's methods satisfy the async requirements directly; `notifyUiReady`
/// is nonisolated there for the same reason it is here.
extension RabeClient: MailCore {}

extension MailCore {
    /// The plain actions (archive, star, mark read …) send no params.
    func performAction(_ kind: ActionKind, threadIds: [Int64]) async throws -> ActionResult {
        try await performAction(kind, threadIds: threadIds, wakeAt: nil)
    }
}
