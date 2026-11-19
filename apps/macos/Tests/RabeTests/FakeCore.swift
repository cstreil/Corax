import Foundation
@testable import Rabe
@testable import RabeKit

/// Test double for `MailCore`: records what the stores send and lets a test set
/// delays, so the queue paths (save chain, write chain) can be driven
/// deterministically without a running Rust core.
actor FakeCore: MailCore {
    struct Action: Sendable, Equatable {
        let kind: String
        let threadIds: [Int64]
    }

    // Reading
    private(set) var threads: [ThreadSummary] = []
    var undoResult = true
    private(set) var undoCount = 0
    private(set) var actions: [Action] = []

    // Compose
    private(set) var saveDelay: Duration = .zero
    private(set) var savedDrafts: [SaveDraftArgs] = []
    private(set) var deletedDraftIds: [Int64] = []
    private var nextDraftId: Int64 = 1

    // Settings
    private var settingsText = "{}"
    private(set) var writtenSettings: [String] = []

    func setThreads(_ list: [ThreadSummary]) { threads = list }
    func setSaveDelay(_ delay: Duration) { saveDelay = delay }
    func setUndoResult(_ value: Bool) { undoResult = value }

    func listThreads(view: MailView, splitId: Int64?, accountId: Int64?, cursor: Int64?, limit: Int) async throws -> ThreadPage {
        ThreadPage(threads: threads, nextCursor: nil)
    }

    func getThread(_ id: Int64) async throws -> ThreadDetail {
        throw RabeClientError.core(code: "not_found", message: "thread \(id)")
    }

    func getBody(_ messageId: Int64) async throws -> MessageDetail {
        throw RabeClientError.core(code: "not_found", message: "message \(messageId)")
    }

    func accounts() async throws -> [Account] { [] }
    func splits() async throws -> [SplitRule] { [] }
    func labels() async throws -> [Label] { [] }
    func unreadCounts() async throws -> UnreadCounts {
        UnreadCounts(inbox: 0, important: 0, other: 0, splits: [:], labels: [:], views: [:])
    }
    func search(_ query: String, accountId: Int64?) async throws -> SearchResults { SearchResults(threads: []) }
    func openAttachment(_ id: Int64) async throws {}
    func saveAttachment(_ id: Int64, to path: String) async throws {}
    nonisolated func notifyUiReady() {}

    func performAction(_ kind: ActionKind, threadIds: [Int64], wakeAt: Int64?) async throws -> ActionResult {
        actions.append(Action(kind: kind.rawValue, threadIds: threadIds))
        return ActionResult(actionIds: [Int64(100 + actions.count)])
    }

    func undoLast() async throws -> Bool {
        undoCount += 1
        return undoResult
    }

    func suggestContacts(_ query: String) async throws -> [ContactSuggestion] { [] }

    func saveDraft(_ args: SaveDraftArgs) async throws -> Int64 {
        if saveDelay > .zero { try? await Task.sleep(for: saveDelay) }
        savedDrafts.append(args)
        if let id = args.draftId { return id }
        let id = nextDraftId
        nextDraftId += 1
        return id
    }

    func deleteDraft(_ id: Int64) async throws { deletedDraftIds.append(id) }
    func queueSend(draftId: Int64) async throws -> QueueSendResult { QueueSendResult(actionId: 77, dispatchAt: 0) }
    func cancelSend(actionId: Int64) async throws -> Bool { true }

    func settingsJSON() async throws -> String { settingsText }

    func setSettingsJSON(_ settingsObjectJSON: String) async throws {
        writtenSettings.append(settingsObjectJSON)
        settingsText = settingsObjectJSON
    }

    /// Settings the last write carried, values as strings (the tests only set
    /// string-valued keys).
    func lastSettings() -> [String: String] {
        guard let data = writtenSettings.last?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    func savedDraftCount() -> Int { savedDrafts.count }
}
