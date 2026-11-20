import Foundation
import Observation

/// Why an AI call failed, in the three shapes the UI distinguishes (M2.3):
/// not set up yet (no key), a provider/network error, or anything else.
public enum AIFailure: Sendable, Equatable {
    case notConfigured
    case message(String)

    /// From a thrown client error; `ai_not_configured` is the core's code.
    public init(_ error: Error) {
        let clientError = RabeClientError.from(error)
        if clientError.code == "ai_not_configured" {
            self = .notConfigured
        } else {
            self = .message(Strings.errorText(clientError))
        }
    }

    public var text: String {
        switch self {
        case .notConfigured: Strings.aiNotConfigured
        case .message(let text): text
        }
    }
}

// MARK: - Settings, status and configuration

/// State behind Settings → Intelligenz (M2.3): is a model configured, which
/// models does the endpoint offer, what has it cost so far, how far is the
/// semantic index, and the keychain writes for the chat and decision keys.
///
/// The key values are write-only: they go straight into `set_ai_key` /
/// `set_decision_key` and are never stored, logged or read back.
@MainActor
@Observable
public final class AIStore {
    public var client: (any AICore)?
    public let toasts: ToastCenter

    public private(set) var status: AIStatus?
    public private(set) var models: [String] = []
    public private(set) var usage: AIUsageStats?
    public private(set) var embedding: EmbeddingStatus?
    /// Nil until the first `testDecisionProviders()`; then one row per provider.
    public private(set) var decisionResults: [DecisionTestResult]?
    public private(set) var decisionTestError: String?
    public private(set) var voiceProfile: String?
    public private(set) var loadingStatus = false
    public private(set) var loadingUsage = false
    public private(set) var loadingEmbedding = false
    public private(set) var testingDecision = false
    public private(set) var learningVoice = false
    public private(set) var reindexing = false
    /// Set when the last provider call said "no key" — the settings page then
    /// points at the key field instead of showing a bare error.
    public private(set) var lastFailure: AIFailure?

    public init(toasts: ToastCenter = ToastCenter()) {
        self.toasts = toasts
    }

    public var isConfigured: Bool { status?.configured ?? false }
    public var usesAppleIntelligence: Bool { status?.usesAppleIntelligence ?? false }
    public var decisionConfigured: Bool { status?.decisionConfigured ?? false }

    /// Status, usage and the index: everything the page shows on appear.
    public func refresh() async {
        await refreshStatus()
        await refreshUsage()
        await refreshEmbedding()
    }

    public func refreshStatus() async {
        guard let client, !loadingStatus else { return }
        loadingStatus = true
        defer { loadingStatus = false }
        do {
            status = try await client.aiStatus()
            lastFailure = nil
        } catch {
            lastFailure = AIFailure(error)
            status = nil
        }
    }

    /// Model ids from the endpoint. Works keyless on OpenRouter and for local
    /// endpoints, so it is not tied to `configured`.
    public func refreshModels() async {
        guard let client else { return }
        do {
            models = try await client.aiListModels()
            decisionTestError = nil
        } catch {
            models = []
            decisionTestError = AIFailure(error).text
        }
    }

    public func refreshUsage() async {
        guard let client, !loadingUsage else { return }
        loadingUsage = true
        defer { loadingUsage = false }
        usage = try? await client.aiUsageStats()
    }

    public func refreshEmbedding() async {
        guard let client, !loadingEmbedding else { return }
        loadingEmbedding = true
        defer { loadingEmbedding = false }
        embedding = try? await client.embeddingStatus()
    }

    /// `set_ai_key` — the value comes from a `SecureField`, is passed straight
    /// through and is never kept in this store.
    public func saveKey(_ key: String) async -> Bool {
        guard let client else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.setAIKey(trimmed)
            toasts.show(trimmed.isEmpty ? "Schlüssel entfernt" : "Schlüssel gespeichert")
            await refreshStatus()
            await refreshModels()
            return true
        } catch {
            lastFailure = AIFailure(error)
            toasts.error(error)
            return false
        }
    }

    /// `set_decision_key` — same write-only rule as the chat key.
    public func saveDecisionKey(provider: String, key: String) async -> Bool {
        guard let client else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toasts.show("Schlüssel fehlt", isError: true)
            return false
        }
        do {
            try await client.setDecisionKey(provider: provider, apiKey: trimmed)
            toasts.show("Schlüssel für \(provider) gespeichert")
            await refreshStatus()
            decisionResults = nil
            return true
        } catch {
            lastFailure = AIFailure(error)
            toasts.error(error)
            return false
        }
    }

    /// `test_decision_provider`: one probe per provider in the chain.
    @discardableResult
    public func testDecisionProviders() async -> [DecisionTestResult]? {
        guard let client, !testingDecision else { return decisionResults }
        testingDecision = true
        decisionTestError = nil
        defer { testingDecision = false }
        do {
            let results = try await client.testDecisionProviders()
            decisionResults = results
            return results
        } catch {
            decisionResults = nil
            decisionTestError = AIFailure(error).text
            return nil
        }
    }

    /// `ai_learn_voice`: rewrites `voiceProfile` in the settings object.
    @discardableResult
    public func learnVoice() async -> String? {
        guard let client, !learningVoice else { return voiceProfile }
        learningVoice = true
        defer { learningVoice = false }
        do {
            let profile = try await client.learnVoice()
            voiceProfile = profile
            toasts.show("Schreibstil gelernt")
            return profile
        } catch {
            lastFailure = AIFailure(error)
            toasts.error(error)
            return nil
        }
    }

    /// `semantic_reindex`: requeues the mailbox; returns the number queued.
    @discardableResult
    public func reindex() async -> Int64? {
        guard let client, !reindexing else { return nil }
        reindexing = true
        defer { reindexing = false }
        do {
            let queued = try await client.semanticReindex()
            toasts.show("\(queued) Nachrichten werden neu indiziert")
            await refreshEmbedding()
            return queued
        } catch {
            lastFailure = AIFailure(error)
            toasts.error(error)
            return nil
        }
    }
}

// MARK: - Thread summary

/// One thread's summary as the thread view shows it: running, done or failed.
public struct ThreadSummaryState: Sendable, Equatable {
    public var pending = false
    public var summary: AIThreadSummary?
    /// M2.4: while the answer streams in, the parts that are already complete.
    /// Replaced by `summary` when the call returns.
    public var partial: AIThreadSummary?
    /// How much text the stream has delivered (tests, debug log).
    public var streamedCharacters = 0
    public var failure: AIFailure?
    /// The last call failed because no key is set — the block offers the setup
    /// hint instead of a retry.
    public var needsSetup: Bool { failure == .notConfigured }
}

// MARK: - Assist: summary, ask, palette, search, rules, signature

/// The per-feature AI calls of M2.3 that are not about settings: the thread
/// summary, "Ask your inbox", the natural-language palette command, the AI
/// search filter, the rule planner and the signature suggestion.
@MainActor
@Observable
public final class AIAssistStore {
    public enum AskStatus: Sendable, Equatable {
        case idle, pending, streaming, done, error
    }

    public var client: (any AICore)?
    public let toasts: ToastCenter

    public private(set) var summaries: [Int64: ThreadSummaryState] = [:]

    // „Ask" surface (`model.askOpen` in the app).
    public var askQuestion = ""
    public private(set) var askStatus: AskStatus = .idle
    public private(set) var askAnswer = ""
    public private(set) var askCitations: [AskCitation] = []
    public private(set) var askFailure: AIFailure?
    /// The id of the running question; streamed tokens carry it (M2.4).
    public private(set) var askRequestId: String?

    // M2.4: streaming state. One throttle per running call; the trailing flush
    // publishes what a 33 ms window held back.
    private var summaryRaw: [Int64: String] = [:]
    private var summaryThrottles: [Int64: TokenThrottle] = [:]
    private var summaryFlush: [Int64: Task<Void, Never>] = [:]
    private var askThrottle = TokenThrottle()
    private var askFlush: Task<Void, Never>?

    public init(toasts: ToastCenter = ToastCenter()) {
        self.toasts = toasts
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Streaming (M2.4, requirement 4)

    /// One `ai:*:token` event from the host. Draft tokens go to the composer
    /// instead (`AppModel` routes them by `requestId`).
    public func receive(_ token: AIStreamToken) {
        switch token.kind {
        case .summary: receiveSummaryToken(token)
        case .ask: receiveAskToken(token)
        case .draft: break
        }
    }

    private func receiveSummaryToken(_ token: AIStreamToken) {
        guard let threadId = token.threadId else { return }
        var state = summaries[threadId] ?? ThreadSummaryState(pending: true)
        guard state.pending else { return }   // a finished summary keeps its text
        state.streamedCharacters += token.delta.count
        summaries[threadId] = state
        summaryRaw[threadId, default: ""] += token.delta
        var throttle = summaryThrottles[threadId] ?? TokenThrottle()
        let publish = throttle.append(token.delta, at: Self.now())
        summaryThrottles[threadId] = throttle
        if publish {
            _ = summaryThrottles[threadId]?.take()
            publishSummary(threadId)
        } else {
            scheduleSummaryFlush(threadId, after: throttle.interval)
        }
    }

    /// Publishes the complete parts of the streamed JSON (Tauri's behaviour:
    /// the card fills in while the model is still writing).
    private func publishSummary(_ threadId: Int64) {
        guard var state = summaries[threadId] else { return }
        state.partial = PartialSummary.parse(summaryRaw[threadId] ?? "")
        summaries[threadId] = state
    }

    private func scheduleSummaryFlush(_ threadId: Int64, after interval: TimeInterval) {
        guard summaryFlush[threadId] == nil else { return }
        let milliseconds = max(1, Int(interval * 1000))
        summaryFlush[threadId] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard let self else { return }
            self.summaryFlush[threadId] = nil
            var throttle = self.summaryThrottles[threadId] ?? TokenThrottle()
            guard throttle.flush(at: Self.now()) != nil else { return }
            self.summaryThrottles[threadId] = throttle
            self.publishSummary(threadId)
        }
    }

    private func receiveAskToken(_ token: AIStreamToken) {
        guard let requestId = token.requestId, requestId == askRequestId else { return }
        askStatus = .streaming
        var throttle = askThrottle
        let publish = throttle.append(token.delta, at: Self.now())
        askThrottle = throttle
        if publish {
            // Take from the stored throttle, not from the copy: otherwise the
            // buffered text stays and the next flush would repeat it.
            askAnswer += askThrottle.take()
        } else {
            scheduleAskFlush(after: throttle.interval)
        }
    }

    private func scheduleAskFlush(after interval: TimeInterval) {
        guard askFlush == nil else { return }
        let milliseconds = max(1, Int(interval * 1000))
        askFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard let self, self.askFlush != nil else { return }
            self.askFlush = nil
            var throttle = self.askThrottle
            if let text = throttle.flush(at: Self.now()) {
                self.askThrottle = throttle
                self.askAnswer += text
            }
        }
    }

    /// Flushes what the window still holds and ends the stream.
    private func finishAskStream() {
        askFlush?.cancel()
        askFlush = nil
        if let text = askThrottle.flush(at: Self.now()) { askAnswer += text }
        askThrottle = TokenThrottle()
    }

    public func receiveAskCitations(_ citations: [AskCitation], requestId: String) {
        guard requestId == askRequestId else { return }
        askCitations = citations
    }

    /// The streamed text was a preamble to a tool call: drop it.
    public func receiveAskReset(requestId: String) {
        guard requestId == askRequestId else { return }
        askFlush?.cancel()
        askFlush = nil
        askThrottle = TokenThrottle()
        askAnswer = ""
        askStatus = .pending
    }

    /// The token stream ended; the answer still arrives with the command result.
    public func receiveAskDone(requestId: String) {
        guard requestId == askRequestId else { return }
        finishAskStream()
        if askStatus == .streaming { askStatus = .pending }
    }

    // MARK: Summary

    public func summaryState(_ threadId: Int64) -> ThreadSummaryState? { summaries[threadId] }

    /// `ai_summarize`. A running call for the same thread is not restarted.
    /// While it runs, the streamed text fills the card in part by part; the
    /// answer replaces it at the end.
    public func summarize(_ threadId: Int64) async {
        guard let client, summaries[threadId]?.pending != true else { return }
        summaries[threadId] = ThreadSummaryState(pending: true)
        summaryRaw[threadId] = ""
        summaryThrottles[threadId] = TokenThrottle()
        do {
            let summary = try await client.summarizeThread(threadId)
            finishSummaryStream(threadId)
            summaries[threadId] = ThreadSummaryState(pending: false, summary: summary,
                                                     streamedCharacters: summaryRaw[threadId]?.count ?? 0)
            summaryRaw[threadId] = nil
        } catch {
            finishSummaryStream(threadId)
            let failure = AIFailure(error)
            summaries[threadId] = ThreadSummaryState(pending: false, streamedCharacters: summaryRaw[threadId]?.count ?? 0,
                                                     failure: failure)
            if failure != .notConfigured { toasts.show(failure.text, isError: true) }
        }
    }

    private func finishSummaryStream(_ threadId: Int64) {
        summaryFlush[threadId]?.cancel()
        summaryFlush[threadId] = nil
        summaryThrottles[threadId] = nil
    }

    public func dismissSummary(_ threadId: Int64) {
        finishSummaryStream(threadId)
        summaryRaw[threadId] = nil
        summaries[threadId] = nil
    }

    // MARK: Ask

    /// `ai_ask`. The answer replaces the previous one; citations come with it.
    /// Tokens that arrive meanwhile grow `askAnswer` (M2.4).
    public func ask(_ question: String, accountId: Int64? = nil) async {
        guard let client else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        askQuestion = trimmed
        askStatus = .pending
        askAnswer = ""
        askCitations = []
        askFailure = nil
        askFlush?.cancel()
        askFlush = nil
        askThrottle = TokenThrottle()
        let requestId = UUID().uuidString
        askRequestId = requestId
        do {
            let result = try await client.aiAsk(question: trimmed, requestId: requestId, accountId: accountId)
            guard askRequestId == requestId else { return }   // a newer question took over
            finishAskStream()
            askAnswer = result.answer
            askCitations = result.citations
            askStatus = .done
        } catch {
            guard askRequestId == requestId else { return }
            finishAskStream()
            askFailure = AIFailure(error)
            askStatus = .error
        }
    }

    public func resetAsk() {
        askFlush?.cancel()
        askFlush = nil
        askThrottle = TokenThrottle()
        askRequestId = nil
        askStatus = .idle
        askAnswer = ""
        askCitations = []
        askFailure = nil
    }

    // MARK: Palette in plain language

    /// `ai_command`: the caller executes the returned intent.
    public func runCommand(_ query: String) async -> AIIntent? {
        guard let client else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return try await client.aiCommand(trimmed)
        } catch {
            toasts.show(AIFailure(error).text, isError: true)
            return nil
        }
    }

    // MARK: Search filter

    /// `ai_search_filter`: a ready query, or a question to answer first.
    public func searchFilter(_ request: String, history: [AIFilterTurn] = []) async -> AISearchFilter? {
        guard let client else { return nil }
        do {
            return try await client.aiSearchFilter(request: request, history: history)
        } catch {
            toasts.show(AIFailure(error).text, isError: true)
            return nil
        }
    }

    // MARK: Rules

    /// `ai_plan_automation`: the validated plan for a rule in plain language.
    public func planAutomation(_ prompt: String) async -> AIAutomationPlan? {
        guard let client else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return try await client.aiPlanAutomation(trimmed)
        } catch {
            toasts.show(AIFailure(error).text, isError: true)
            return nil
        }
    }

    // MARK: Signature

    /// `ai_signature`: a plain-text signature for a name and address.
    public func signature(name: String, email: String) async -> String? {
        guard let client else { return nil }
        do {
            return try await client.aiSignature(name: name, email: email)
        } catch {
            toasts.show(AIFailure(error).text, isError: true)
            return nil
        }
    }
}
