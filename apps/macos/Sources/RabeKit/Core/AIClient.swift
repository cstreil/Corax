import Foundation

// MARK: - Arguments of the AI commands (M2.3)

/// One type per command, encoded by `IPCContractTests` and compared with
/// `src/ipc/types.ts`. `rabe-host`'s dispatch parses every AI command with
/// `deny_unknown_fields`, so these match the Rust input structs exactly.
extension IPCArgs {
    /// `set_ai_key(args)`: `{apiKey}`. The value is written to the keychain and
    /// never logged or shown again.
    struct SetAIKey: Encodable, Sendable { let apiKey: String }

    /// `set_decision_key(args)`: `{provider, apiKey}`. Also keychain-only.
    struct SetDecisionKey: Encodable, Sendable {
        let provider: String
        let apiKey: String
    }

    /// `ai_summarize(args)` / `ai_quick_replies(args)`: `{threadId}`.
    struct AIThreadID: Encodable, Sendable { let threadId: Int64 }

    /// `ai_draft(args)`.
    struct AIDraft: Encodable, Sendable {
        let threadId: Int64?
        let replyToMessageId: Int64?
        let instruction: String
        let currentDraft: String?
        let senderName: String?
        let voice: Bool?
        let hasSignature: Bool?
        let requestId: String?
    }

    /// `ai_draft_actions(args)`: `{threadId?, draft}`.
    struct AIDraftActions: Encodable, Sendable {
        let threadId: Int64?
        let draft: String
    }

    /// `ai_proofread(args)`: `{body}` (no camelCase rename in the host).
    struct AIProofread: Encodable, Sendable { let body: String }

    /// `ai_signature(args)`: `{name, email}`.
    struct AISignature: Encodable, Sendable {
        let name: String
        let email: String
    }

    /// `ai_command(args)`: `{query}`.
    struct AICommand: Encodable, Sendable { let query: String }

    /// `ai_search_filter(args)`: `{request, history?}`.
    struct AISearchFilterArgs: Encodable, Sendable {
        let request: String
        let history: [AIFilterTurn]
    }

    /// `ai_plan_automation(args)`: `{prompt}`.
    struct AIPlanAutomation: Encodable, Sendable { let prompt: String }

    /// `ai_ask(args)`: `{question, requestId, accountId?}`. The host accepts
    /// `accountId` and ignores it, like Tauri does; it is sent for parity with
    /// `types.ts`.
    struct AIAsk: Encodable, Sendable {
        let question: String
        let requestId: String
        let accountId: Int64?
    }
}

// MARK: - The part of the core client the AI features use

/// A protocol so `AIStore` and `AIAssistStore` can run against `FakeAICore`
/// without a running Rust core or a real provider (M2.3, requirement 9).
public protocol AICore: Sendable {
    // Status and configuration
    func aiStatus() async throws -> AIStatus
    func aiListModels() async throws -> [String]
    func aiUsageStats() async throws -> AIUsageStats
    /// Writes the chat key to the keychain. The value never comes back out.
    func setAIKey(_ apiKey: String) async throws
    /// Writes a decision-provider key to the keychain.
    func setDecisionKey(provider: String, apiKey: String) async throws
    func testDecisionProviders() async throws -> [DecisionTestResult]
    func learnVoice() async throws -> String
    func embeddingStatus() async throws -> EmbeddingStatus
    func semanticReindex() async throws -> Int64

    // Thread and compose features
    func summarizeThread(_ threadId: Int64) async throws -> AIThreadSummary
    func quickReplies(_ threadId: Int64) async throws -> [String]
    func aiDraft(threadId: Int64?, replyToMessageId: Int64?, instruction: String, currentDraft: String?,
                 senderName: String?, voice: Bool?, hasSignature: Bool?, requestId: String?) async throws -> String
    func aiDraftActions(threadId: Int64?, draft: String) async throws -> [AIDraftAction]
    func proofread(_ body: String) async throws -> String
    func aiSignature(name: String, email: String) async throws -> String

    // Palette, search, rules, ask
    func aiCommand(_ query: String) async throws -> AIIntent
    func aiSearchFilter(request: String, history: [AIFilterTurn]) async throws -> AISearchFilter
    func aiPlanAutomation(_ prompt: String) async throws -> AIAutomationPlan
    func aiAsk(question: String, requestId: String, accountId: Int64?) async throws -> AskResult
}

// MARK: - Typed wrappers (names and argument shapes from the host)

extension RabeClient: AICore {
    public func aiStatus() async throws -> AIStatus { try await call("ai_status") }

    public func aiListModels() async throws -> [String] { try await call("ai_list_models") }

    public func aiUsageStats() async throws -> AIUsageStats { try await call("ai_usage_stats") }

    public func setAIKey(_ apiKey: String) async throws {
        try await send("set_ai_key", IPCArgs.SetAIKey(apiKey: apiKey))
    }

    public func setDecisionKey(provider: String, apiKey: String) async throws {
        try await send("set_decision_key", IPCArgs.SetDecisionKey(provider: provider, apiKey: apiKey))
    }

    public func testDecisionProviders() async throws -> [DecisionTestResult] {
        try await call("test_decision_provider")
    }

    public func learnVoice() async throws -> String { try await call("ai_learn_voice") }

    public func embeddingStatus() async throws -> EmbeddingStatus { try await call("embedding_status") }

    public func semanticReindex() async throws -> Int64 { try await call("semantic_reindex") }

    public func summarizeThread(_ threadId: Int64) async throws -> AIThreadSummary {
        try await call("ai_summarize", IPCArgs.AIThreadID(threadId: threadId))
    }

    public func quickReplies(_ threadId: Int64) async throws -> [String] {
        try await call("ai_quick_replies", IPCArgs.AIThreadID(threadId: threadId))
    }

    public func aiDraft(threadId: Int64?, replyToMessageId: Int64?, instruction: String, currentDraft: String?,
                        senderName: String?, voice: Bool?, hasSignature: Bool?, requestId: String?) async throws -> String {
        try await call("ai_draft", IPCArgs.AIDraft(
            threadId: threadId, replyToMessageId: replyToMessageId, instruction: instruction,
            currentDraft: currentDraft, senderName: senderName, voice: voice,
            hasSignature: hasSignature, requestId: requestId))
    }

    public func aiDraftActions(threadId: Int64?, draft: String) async throws -> [AIDraftAction] {
        try await call("ai_draft_actions", IPCArgs.AIDraftActions(threadId: threadId, draft: draft))
    }

    public func proofread(_ body: String) async throws -> String {
        try await call("ai_proofread", IPCArgs.AIProofread(body: body))
    }

    public func aiSignature(name: String, email: String) async throws -> String {
        try await call("ai_signature", IPCArgs.AISignature(name: name, email: email))
    }

    public func aiCommand(_ query: String) async throws -> AIIntent {
        try await call("ai_command", IPCArgs.AICommand(query: query))
    }

    public func aiSearchFilter(request: String, history: [AIFilterTurn] = []) async throws -> AISearchFilter {
        try await call("ai_search_filter", IPCArgs.AISearchFilterArgs(request: request, history: history))
    }

    public func aiPlanAutomation(_ prompt: String) async throws -> AIAutomationPlan {
        try await call("ai_plan_automation", IPCArgs.AIPlanAutomation(prompt: prompt))
    }

    public func aiAsk(question: String, requestId: String, accountId: Int64? = nil) async throws -> AskResult {
        try await call("ai_ask", IPCArgs.AIAsk(question: question, requestId: requestId, accountId: accountId))
    }
}
