import Foundation
@testable import Corax
@testable import CoraxKit

/// Test double for `MailCore`: records what the stores send and lets a test set
/// delays, so the queue paths (save chain, write chain) can be driven
/// deterministically without a running Rust core.
actor FakeCore: MailCore {
    struct Action: Sendable, Equatable {
        let kind: String
        let threadIds: [Int64]
        var params: ActionParams?

        init(kind: String, threadIds: [Int64], params: ActionParams? = nil) {
            self.kind = kind
            self.threadIds = threadIds
            self.params = params
        }
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

    /// M2.9: the filters the list asked for, so a test can check that the
    /// sidebar's label/folder choice reaches the core.
    private(set) var listQueries: [(labelId: Int64?, folderId: Int64?)] = []

    func listThreads(view: MailView, splitId: Int64?, accountId: Int64?, labelId: Int64?,
                     folderId: Int64?, cursor: Int64?, limit: Int) async throws -> ThreadPage {
        listQueries.append((labelId, folderId))
        return ThreadPage(threads: threads, nextCursor: nil)
    }

    /// M2.8c: a test that opens a thread sets a detail here. Without one the
    /// call throws (as before), and the resulting error toast replaces the undo
    /// toast — which ends the undo window in the middle of a test.
    var detail: ThreadDetail?
    func setDetail(_ value: ThreadDetail?) { detail = value }

    func getThread(_ id: Int64) async throws -> ThreadDetail {
        if let detail { return detail }
        throw CoraxClientError.core(code: "not_found", message: "thread \(id)")
    }

    func getBody(_ messageId: Int64) async throws -> MessageDetail {
        throw CoraxClientError.core(code: "not_found", message: "message \(messageId)")
    }

    private(set) var accountRows: [Account] = []
    func seedAccounts(_ rows: [Account]) { accountRows = rows }
    func accounts() async throws -> [Account] { accountRows }
    func splits() async throws -> [SplitRule] { splitRows }
    func labels() async throws -> [Label] { labelRows }
    func unreadCounts() async throws -> UnreadCounts {
        UnreadCounts(inbox: 0, important: 0, other: 0, splits: [:], labels: [:], views: [:])
    }
    func search(_ query: String, accountId: Int64?) async throws -> SearchResults { SearchResults(threads: []) }
    func openAttachment(_ id: Int64) async throws {}
    func saveAttachment(_ id: Int64, to path: String) async throws {}
    nonisolated func notifyUiReady() {}

    func performAction(_ kind: ActionKind, threadIds: [Int64], params: ActionParams?) async throws -> ActionResult {
        actions.append(Action(kind: kind.rawValue, threadIds: threadIds, params: params))
        return ActionResult(actionIds: [Int64(100 + actions.count)])
    }

    /// M2.5: `list_folders` answers `folderRows`.
    private(set) var folderRows: [FolderInfo] = []
    private(set) var folderQueries: [Int64?] = []
    private(set) var syncCalls: [Int64?] = []
    func seedFolders(_ rows: [FolderInfo]) { folderRows = rows }
    func listFolders(accountId: Int64?) async throws -> [FolderInfo] {
        folderQueries.append(accountId)
        return folderRows
    }
    func syncNow(accountId: Int64?) async throws { syncCalls.append(accountId) }

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
    private(set) var queuedSends: [(draftId: Int64, sendAt: Int64?)] = []
    func queueSend(draftId: Int64, sendAt: Int64?) async throws -> QueueSendResult {
        queuedSends.append((draftId, sendAt))
        return QueueSendResult(actionId: 77, dispatchAt: sendAt ?? 0)
    }
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

    /// The settings object the last write carried, as JSON text (`String` is
    /// Sendable, `[String: Any]` is not).
    func lastSettingsJSON() -> String { writtenSettings.last ?? "{}" }

    // MARK: - Settings editors (M2.1)

    // In-memory rows so the editors can be driven without a core.
    private(set) var snippetRows: [Snippet] = []
    private(set) var labelRows: [Label] = []
    private(set) var splitRows: [SplitRule] = []
    private(set) var tabOrder: [TabRef] = []
    private(set) var renamedAccounts: [(id: Int64, name: String)] = []
    private(set) var removedAccountIDs: [Int64] = []
    private(set) var relabelCalls = 0
    private(set) var createdCategories: [String] = []
    private(set) var previewedConditions: [RuleCondition] = []
    private var nextRowID: Int64 = 500

    func seedSnippets(_ rows: [Snippet]) { snippetRows = rows }
    func seedLabels(_ rows: [Label]) { labelRows = rows }
    func seedSplits(_ rows: [SplitRule]) { splitRows = rows }

    func setAccountDisplayName(accountId: Int64, name: String) async throws -> Account {
        renamedAccounts.append((accountId, name))
        return Account(id: accountId, email: "a@b.de", displayName: name, provider: "imap",
                       authKind: "password", syncState: "idle")
    }

    func removeAccount(_ id: Int64) async throws {
        removedAccountIDs.append(id)
        accountRows.removeAll { $0.id == id }
    }

    func listSnippets() async throws -> [Snippet] { snippetRows }

    func saveSnippet(_ input: SnippetInput) async throws -> Snippet {
        if let id = input.id, let index = snippetRows.firstIndex(where: { $0.id == id }) {
            let updated = Snippet(id: id, name: input.name, shortcut: input.shortcut,
                                  subject: input.subject, bodyText: input.bodyText,
                                  usageCount: snippetRows[index].usageCount)
            snippetRows[index] = updated
            return updated
        }
        let created = Snippet(id: nextID(), name: input.name, shortcut: input.shortcut,
                              subject: input.subject, bodyText: input.bodyText, usageCount: 0)
        snippetRows.append(created)
        return created
    }

    func deleteSnippet(_ id: Int64) async throws { snippetRows.removeAll { $0.id == id } }

    func saveLabel(_ input: LabelInput) async throws -> Label {
        if let id = input.id, let index = labelRows.firstIndex(where: { $0.id == id }) {
            let old = labelRows[index]
            let updated = Label(id: id, name: input.name, color: input.color, keyword: old.keyword,
                                position: input.position, isAuto: old.isAuto)
            labelRows[index] = updated
            return updated
        }
        let created = Label(id: nextID(), name: input.name, color: input.color,
                            keyword: "K_%lu".replacingOccurrences(of: "%lu", with: String(labelRows.count)),
                            position: input.position, isAuto: false)
        labelRows.append(created)
        return created
    }

    func deleteLabel(_ id: Int64) async throws { labelRows.removeAll { $0.id == id } }
    func restoreAutoLabels() async throws -> Int64 { 2 }

    func createCategory(name: String, color: String, description: String) async throws -> Label {
        createdCategories.append(name)
        let created = Label(id: nextID(), name: name, color: color,
                            keyword: "ComailAuto\(name)", position: Int64(labelRows.count), isAuto: true)
        labelRows.append(created)
        return created
    }

    func saveSplit(_ input: SplitInput) async throws -> SplitRule {
        if let id = input.id, let index = splitRows.firstIndex(where: { $0.id == id }) {
            let updated = SplitRule(id: id, name: input.name, position: input.position, query: input.query,
                                    condition: input.condition, target: input.target, ai: input.ai,
                                    countAll: input.countAll)
            splitRows[index] = updated
            return updated
        }
        let created = SplitRule(id: nextID(), name: input.name, position: input.position, query: input.query,
                                condition: input.condition, target: input.target, ai: input.ai,
                                countAll: input.countAll)
        splitRows.append(created)
        return created
    }

    func deleteSplit(_ id: Int64) async throws { splitRows.removeAll { $0.id == id } }
    func reorderTabs(_ order: [TabRef]) async throws {
        tabOrder = order
        // The core renumbers both tables so the shared order sticks; the fake
        // does the same, otherwise a reload would show the old order again.
        for (index, ref) in order.enumerated() {
            switch ref.kind {
            case "split":
                if let i = splitRows.firstIndex(where: { $0.id == ref.id }) {
                    let rule = splitRows[i]
                    splitRows[i] = SplitRule(id: rule.id, name: rule.name, position: Int64(index),
                                             query: rule.query, condition: rule.condition,
                                             target: rule.target, ai: rule.ai, countAll: rule.countAll)
                }
            case "label":
                if let i = labelRows.firstIndex(where: { $0.id == ref.id }) {
                    let label = labelRows[i]
                    labelRows[i] = Label(id: label.id, name: label.name, color: label.color,
                                         keyword: label.keyword, position: Int64(index), isAuto: label.isAuto)
                }
            default:
                break
            }
        }
    }
    func relabelAutoLabels() async throws -> Int64 { relabelCalls += 1; return 3 }

    func previewSplitCondition(_ condition: RuleCondition, limit: Int64?) async throws -> ConditionPreview {
        previewedConditions.append(condition)
        return ConditionPreview(total: 2, scanned: 50, samples: [])
    }

    func mcpStatus() async throws -> McpStatus {
        McpStatus(running: true, name: "corax-sandbox", port: 47823,
                  url: "http://127.0.0.1:47823/mcp", error: nil, clientCount: 1)
    }
    func mcpActivity() async throws -> [McpCall] {
        [McpCall(at: 1_700_000_000_000, client: "test", tool: "list_threads", ok: true, error: nil)]
    }
    func mcpListClients() async throws -> [McpClientInfo] {
        [McpClientInfo(id: "claude", name: "Claude Code", method: .command, detected: false,
                       configPath: nil, snippetLang: .shell)]
    }
    func mcpToken() async throws -> String { "test-token-123456" }
    func mcpRegenerateToken() async throws -> String { "test-token-654321" }
    func mcpClientSnippet(id: String) async throws -> String { "{\"mcpServers\":{}}" }
    func mcpInstallClient(id: String) async throws -> McpInstallResult {
        McpInstallResult(ok: true, message: "eingerichtet", path: nil, openUrl: nil)
    }

    // MARK: - Google-Anmeldung (M3.4)

    /// Providers the UI asked for, in order (`"gmail"`).
    private(set) var oauthStarts: [String] = []
    /// Account ids `reauth_account` was called with.
    private(set) var oauthReauths: [Int64] = []
    private(set) var oauthCancels = 0
    /// The account a sign-in returns; without one the call fails like the core
    /// does when the user cancels.
    var oauthAccount: Account?
    /// Set to make the sign-in fail (e.g. the timeout text).
    var oauthError: CoraxClientError?

    func setOAuthAccount(_ value: Account?) { oauthAccount = value }
    func setOAuthError(_ value: CoraxClientError?) { oauthError = value }

    func startOAuth(provider: OAuthProvider) async throws -> Account {
        oauthStarts.append(provider.rawValue)
        if let oauthError { throw oauthError }
        if let oauthAccount { return oauthAccount }
        throw CoraxClientError.core(code: "auth", message: "sign-in cancelled")
    }

    func reauthAccount(id: Int64) async throws -> Account {
        oauthReauths.append(id)
        if let oauthError { throw oauthError }
        if let oauthAccount { return oauthAccount }
        throw CoraxClientError.core(code: "auth", message: "sign-in cancelled")
    }

    func cancelOAuth() async throws { oauthCancels += 1 }

    private func nextID() -> Int64 {
        nextRowID += 1
        return nextRowID
    }

    // MARK: - KI (M2.3)

    /// Every AI command the stores sent, in order, for the call-sequence tests.
    private(set) var aiCalls: [String] = []
    /// When set, every AI call throws it (the error path of each feature).
    var aiError: CoraxClientError?
    /// Delay before an AI call returns (to observe the pending state).
    var aiDelay: Duration = .zero

    var aiStatusValue = AIStatus(configured: true, model: "fake-model",
                                 baseUrl: "https://fake.invalid/v1", decisionModel: "")
    var aiModelsValue = ["fake-model", "other-model"]
    var aiUsageValue = AIUsageStats(totalTokens: 120, totalRequests: 4, todayTokens: 30,
                                    yesterdayTokens: 20, last7DaysTokens: 90, last30DaysTokens: 120, days: [])
    var aiEmbeddingValue = EmbeddingStatus(enabled: true, model: "fake-embed", total: 10,
                                           embedded: 6, pending: 4, ready: true)
    var aiDecisionResults: [DecisionTestResult] = [
        DecisionTestResult(provider: "openrouter", model: "jev", ok: true, latencyMs: 42,
                           probability: 0.93, error: "")
    ]
    var aiVoiceValue = "Kurz und freundlich."
    var aiReindexValue: Int64 = 12

    var aiSummaryValue = AIThreadSummary(
        timeline: [AITimelineEntry(actor: "Ana", event: "schickt die Rechnung")],
        keyPoints: ["Rechnung offen"], nextAction: "Zahlen", proposedReply: "Mache ich.")
    var aiQuickRepliesValue = ["Danke, mache ich."]
    var aiDraftValue = "Guten Tag, ich sage zu."
    var aiDraftActionsValue: [AIDraftAction] = []
    var aiProofreadValue = "Guten Tag, ich sage zu."
    var aiSignatureValue = "Viele Grüße\nChristian"
    var aiIntentValue = AIIntent(kind: "none")
    var aiFilterValue: AISearchFilter = .query("from:ana has:attachment")
    var aiPlanValue = AIAutomationPlan(supported: true, name: "Rechnungen", instruction: "Ist es eine offene Rechnung?",
                                       actions: [AIAutomationAction(kind: "route_to", value: "important")],
                                       summary: "Leitet Rechnungen nach Wichtig.", issues: [])
    var aiAskValue = AskResult(answer: "Am 3. März.", citations: [
        AskCitation(messageId: 11, threadId: 7, subject: "Termin", from: "ana@example.test",
                    date: 1_700_000_000_000, snippet: "am 3. März")
    ])

    /// The last values the keychain-writing commands received. Test-only
    /// memory: nothing serializes or logs them, and they never leave the fake.
    private(set) var savedAIKey: String?
    private(set) var savedDecisionKey: (provider: String, key: String)?
    private(set) var aiDraftRequest: (threadId: Int64?, instruction: String, currentDraft: String?)?
    private(set) var aiAskRequest: (question: String, requestId: String, accountId: Int64?)?
    private(set) var aiSearchHistory: [[AIFilterTurn]] = []

    func setAIError(_ error: CoraxClientError?) { aiError = error }
    func setQuickReplies(_ values: [String]) { aiQuickRepliesValue = values }
    func setDraftActions(_ values: [AIDraftAction]) { aiDraftActionsValue = values }
    func setProofreadValue(_ text: String) { aiProofreadValue = text }
    func setAIDraftValue(_ text: String) { aiDraftValue = text }
    func setAISignatureValue(_ text: String) { aiSignatureValue = text }
    func setAIPlan(_ plan: AIAutomationPlan) { aiPlanValue = plan }
    func setAIDelay(_ delay: Duration) { aiDelay = delay }
    func setAIIntent(_ intent: AIIntent) { aiIntentValue = intent }
    func setAIFilter(_ filter: AISearchFilter) { aiFilterValue = filter }

    private func recordAI(_ command: String) async throws {
        aiCalls.append(command)
        if aiDelay > .zero { try? await Task.sleep(for: aiDelay) }
        if let aiError { throw aiError }
    }

    func aiStatus() async throws -> AIStatus { try await recordAI("ai_status"); return aiStatusValue }
    func aiListModels() async throws -> [String] { try await recordAI("ai_list_models"); return aiModelsValue }
    func aiUsageStats() async throws -> AIUsageStats { try await recordAI("ai_usage_stats"); return aiUsageValue }
    func setAIKey(_ apiKey: String) async throws {
        try await recordAI("set_ai_key")
        savedAIKey = apiKey
        aiStatusValue = AIStatus(configured: !apiKey.isEmpty, model: aiStatusValue.model,
                                 baseUrl: aiStatusValue.baseUrl)
    }
    func setDecisionKey(provider: String, apiKey: String) async throws {
        try await recordAI("set_decision_key")
        savedDecisionKey = (provider, apiKey)
    }
    func testDecisionProviders() async throws -> [DecisionTestResult] {
        try await recordAI("test_decision_provider")
        return aiDecisionResults
    }
    func learnVoice() async throws -> String { try await recordAI("ai_learn_voice"); return aiVoiceValue }
    func embeddingStatus() async throws -> EmbeddingStatus {
        try await recordAI("embedding_status")
        return aiEmbeddingValue
    }
    func semanticReindex() async throws -> Int64 { try await recordAI("semantic_reindex"); return aiReindexValue }

    func summarizeThread(_ threadId: Int64) async throws -> AIThreadSummary {
        try await recordAI("ai_summarize")
        return aiSummaryValue
    }
    func quickReplies(_ threadId: Int64) async throws -> [String] {
        try await recordAI("ai_quick_replies")
        return aiQuickRepliesValue
    }
    func aiDraft(threadId: Int64?, replyToMessageId: Int64?, instruction: String, currentDraft: String?,
                 senderName: String?, voice: Bool?, hasSignature: Bool?, requestId: String?) async throws -> String {
        try await recordAI("ai_draft")
        aiDraftRequest = (threadId, instruction, currentDraft)
        return aiDraftValue
    }
    func aiDraftActions(threadId: Int64?, draft: String) async throws -> [AIDraftAction] {
        try await recordAI("ai_draft_actions")
        return aiDraftActionsValue
    }
    func proofread(_ body: String) async throws -> String {
        try await recordAI("ai_proofread")
        return aiProofreadValue
    }
    func aiSignature(name: String, email: String) async throws -> String {
        try await recordAI("ai_signature")
        return aiSignatureValue
    }
    func aiCommand(_ query: String) async throws -> AIIntent { try await recordAI("ai_command"); return aiIntentValue }
    func aiSearchFilter(request: String, history: [AIFilterTurn]) async throws -> AISearchFilter {
        try await recordAI("ai_search_filter")
        aiSearchHistory.append(history)
        return aiFilterValue
    }
    func aiPlanAutomation(_ prompt: String) async throws -> AIAutomationPlan {
        try await recordAI("ai_plan_automation")
        return aiPlanValue
    }
    func aiAsk(question: String, requestId: String, accountId: Int64?) async throws -> AskResult {
        try await recordAI("ai_ask")
        aiAskRequest = (question, requestId, accountId)
        return aiAskValue
    }

    // MARK: - M2.4 (avatars, verification codes, unsubscribing)

    /// `sender_avatar` answers this per address (nil = no picture).
    var senderAvatarValue: String?
    private(set) var avatarQueries: [String] = []
    /// `latest_verification_code` answers this; nil = none found.
    var verificationCodeValue: VerificationCode?
    private(set) var verificationCodeMaxAge: Int?
    /// `thread_unsubscribe_message` answers this; nil = the thread offers none.
    var unsubscribeMessageId: Int64?
    var unsubscribeOutcome: UnsubscribeOutcome = .oneClick
    private(set) var unsubscribeCalls: [Int64] = []

    func setSenderAvatar(_ value: String?) { senderAvatarValue = value }
    func setVerificationCode(_ value: VerificationCode?) { verificationCodeValue = value }
    func setUnsubscribe(messageId: Int64?, outcome: UnsubscribeOutcome = .oneClick) {
        unsubscribeMessageId = messageId
        unsubscribeOutcome = outcome
    }

    func senderAvatar(_ email: String) async throws -> String? {
        avatarQueries.append(email)
        return senderAvatarValue
    }

    func latestVerificationCode(maxAgeMinutes: Int?) async throws -> VerificationCode? {
        verificationCodeMaxAge = maxAgeMinutes
        return verificationCodeValue
    }

    func threadUnsubscribeMessage(threadId: Int64) async throws -> Int64? { unsubscribeMessageId }

    func unsubscribeMessage(messageId: Int64) async throws -> UnsubscribeOutcome {
        unsubscribeCalls.append(messageId)
        return unsubscribeOutcome
    }
}
