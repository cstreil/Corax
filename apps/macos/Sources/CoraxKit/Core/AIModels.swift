import Foundation

// Codable mirrors of the AI DTOs in `src/ipc/types.ts` / `models.rs` (M2.3).
// The Rust side serializes with `serde(rename_all = "camelCase")`; most of the
// structs carry `#[serde(default)]` on their fields, so every decode tolerates
// missing keys instead of failing the whole feature on one absent field.

// MARK: - Status, models, usage

/// `AiStatus` (`models.rs`): whether a chat model can be used at all.
public struct AIStatus: Decodable, Sendable, Equatable {
    public let configured: Bool
    public let model: String
    public let baseUrl: String
    /// "available", "deviceNotEligible", "notEnabled", "modelNotReady",
    /// "osTooOld" or "unsupported".
    public let appleIntelligence: String
    public let decisionConfigured: Bool
    /// The decision model in use ("" when off).
    public let decisionModel: String

    public init(configured: Bool, model: String, baseUrl: String, appleIntelligence: String = "unsupported",
                decisionConfigured: Bool = false, decisionModel: String = "") {
        self.configured = configured
        self.model = model
        self.baseUrl = baseUrl
        self.appleIntelligence = appleIntelligence
        self.decisionConfigured = decisionConfigured
        self.decisionModel = decisionModel
    }

    private enum CodingKeys: String, CodingKey {
        case configured, model, baseUrl, appleIntelligence, decisionConfigured, decisionModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        appleIntelligence = try c.decodeIfPresent(String.self, forKey: .appleIntelligence) ?? "unsupported"
        decisionConfigured = try c.decodeIfPresent(Bool.self, forKey: .decisionConfigured) ?? false
        decisionModel = try c.decodeIfPresent(String.self, forKey: .decisionModel) ?? ""
    }

    /// True when the on-device Apple model is the configured provider.
    public var usesAppleIntelligence: Bool { AIStatus.isAppleBaseURL(baseUrl) }

    /// The on-device provider sentinel (`ai::apple::BASE_URL`).
    public static func isAppleBaseURL(_ baseURL: String) -> Bool {
        baseURL.lowercased().hasPrefix("apple:")
    }
}

public struct AIUsageDay: Decodable, Sendable, Hashable, Identifiable {
    public let date: String
    public let totalTokens: Int64
    public let requests: Int64
    public var id: String { date }

    public init(date: String, totalTokens: Int64, requests: Int64) {
        self.date = date
        self.totalTokens = totalTokens
        self.requests = requests
    }
}

public struct AIUsageStats: Decodable, Sendable, Hashable {
    public let totalTokens: Int64
    public let totalRequests: Int64
    public let todayTokens: Int64
    public let yesterdayTokens: Int64
    public let last7DaysTokens: Int64
    public let last30DaysTokens: Int64
    public let days: [AIUsageDay]

    public init(totalTokens: Int64, totalRequests: Int64, todayTokens: Int64, yesterdayTokens: Int64,
                last7DaysTokens: Int64, last30DaysTokens: Int64, days: [AIUsageDay]) {
        self.totalTokens = totalTokens
        self.totalRequests = totalRequests
        self.todayTokens = todayTokens
        self.yesterdayTokens = yesterdayTokens
        self.last7DaysTokens = last7DaysTokens
        self.last30DaysTokens = last30DaysTokens
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case totalTokens, totalRequests, todayTokens, yesterdayTokens
        case last7DaysTokens, last30DaysTokens, days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try c.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        totalRequests = try c.decodeIfPresent(Int64.self, forKey: .totalRequests) ?? 0
        todayTokens = try c.decodeIfPresent(Int64.self, forKey: .todayTokens) ?? 0
        yesterdayTokens = try c.decodeIfPresent(Int64.self, forKey: .yesterdayTokens) ?? 0
        last7DaysTokens = try c.decodeIfPresent(Int64.self, forKey: .last7DaysTokens) ?? 0
        last30DaysTokens = try c.decodeIfPresent(Int64.self, forKey: .last30DaysTokens) ?? 0
        days = try c.decodeIfPresent([AIUsageDay].self, forKey: .days) ?? []
    }
}

/// `EmbeddingStatus` (`models.rs`): progress of the local semantic index.
public struct EmbeddingStatus: Decodable, Sendable, Hashable {
    public let enabled: Bool
    public let model: String
    public let total: Int64
    public let embedded: Int64
    public let pending: Int64
    public let ready: Bool

    public init(enabled: Bool, model: String, total: Int64, embedded: Int64, pending: Int64, ready: Bool) {
        self.enabled = enabled
        self.model = model
        self.total = total
        self.embedded = embedded
        self.pending = pending
        self.ready = ready
    }

    private enum CodingKeys: String, CodingKey { case enabled, model, total, embedded, pending, ready }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        total = try c.decodeIfPresent(Int64.self, forKey: .total) ?? 0
        embedded = try c.decodeIfPresent(Int64.self, forKey: .embedded) ?? 0
        pending = try c.decodeIfPresent(Int64.self, forKey: .pending) ?? 0
        ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
    }
}

/// `DecisionTestResult` (`models.rs`): one probe of the decision chain.
public struct DecisionTestResult: Decodable, Sendable, Hashable, Identifiable {
    public let provider: String
    public let model: String
    public let ok: Bool
    public let latencyMs: Int64
    /// The model's probability that the sample invoice is an invoice.
    public let probability: Double
    /// Why the provider failed ("" when ok).
    public let error: String

    public var id: String { "\(provider)/\(model)" }

    public init(provider: String, model: String, ok: Bool, latencyMs: Int64, probability: Double, error: String) {
        self.provider = provider
        self.model = model
        self.ok = ok
        self.latencyMs = latencyMs
        self.probability = probability
        self.error = error
    }
}

// MARK: - Thread summary (`ai_summarize`)

public struct AITimelineEntry: Decodable, Sendable, Hashable {
    public let actor: String
    public let event: String

    public init(actor: String, event: String) {
        self.actor = actor
        self.event = event
    }
}

/// A dated item the model proposed; the user reviews it before saving.
public struct AICalendarSuggestion: Decodable, Sendable, Hashable {
    public let title: String
    /// ISO-8601 from the model.
    public let start: String
    public let end: String?
    public let allDay: Bool
    public let location: String?
    public let description: String?

    private enum CodingKeys: String, CodingKey { case title, start, end, allDay, location, description }

    public init(title: String, start: String, end: String? = nil, allDay: Bool = false,
                location: String? = nil, description: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
        end = try c.decodeIfPresent(String.self, forKey: .end)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        location = try c.decodeIfPresent(String.self, forKey: .location)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }
}

/// The model's ISO-8601 strings ("2026-11-24T14:00:00+01:00", "2026-11-24",
/// "2026-11-24T14:00"), as epoch milliseconds. The calendar editor needs a
/// `Date`, and the model is free in how precise it is — so several shapes are
/// accepted and an unparsable value comes back as nil instead of a guess.
public enum AIDateParser {
    /// Formatters are created per call: `ISO8601DateFormatter` is not
    /// `Sendable`, and a static instance would be shared mutable state.
    private static let localFormats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"]

    public static func milliseconds(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = internet.date(from: trimmed) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: trimmed) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        for format in localFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }
}

/// `AiThreadSummary` (`models.rs`): the structured read of a thread.
public struct AIThreadSummary: Decodable, Sendable, Hashable, Equatable {
    public let timeline: [AITimelineEntry]
    public let keyPoints: [String]
    public let nextAction: String?
    public let proposedReply: String?
    public let calendarSuggestion: AICalendarSuggestion?

    private enum CodingKeys: String, CodingKey {
        case timeline, keyPoints, nextAction, proposedReply, calendarSuggestion
    }

    public init(timeline: [AITimelineEntry] = [], keyPoints: [String] = [], nextAction: String? = nil,
                proposedReply: String? = nil, calendarSuggestion: AICalendarSuggestion? = nil) {
        self.timeline = timeline
        self.keyPoints = keyPoints
        self.nextAction = nextAction
        self.proposedReply = proposedReply
        self.calendarSuggestion = calendarSuggestion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeline = try c.decodeIfPresent([AITimelineEntry].self, forKey: .timeline) ?? []
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        nextAction = try c.decodeIfPresent(String.self, forKey: .nextAction)
        proposedReply = try c.decodeIfPresent(String.self, forKey: .proposedReply)
        calendarSuggestion = try c.decodeIfPresent(AICalendarSuggestion.self, forKey: .calendarSuggestion)
    }

    /// Start of the suggested event as epoch milliseconds, if the model's
    /// string was readable.
    public var suggestedStart: Int64? { calendarSuggestion.flatMap { AIDateParser.milliseconds($0.start) } }
    public var suggestedEnd: Int64? { calendarSuggestion.flatMap { $0.end.flatMap(AIDateParser.milliseconds) } }

    /// Nothing the model considered worth reporting.
    public var isEmpty: Bool {
        keyPoints.isEmpty && timeline.isEmpty && nextAction == nil && proposedReply == nil
    }
}

// MARK: - Prompts and answers

/// A follow-up the core proposes for a finished draft (`ai_draft_actions`),
/// internally tagged by `kind`. Today only `create_event` exists.
public enum AIDraftAction: Decodable, Sendable, Hashable {
    case createEvent(AICalendarSuggestion)

    public var suggestion: AICalendarSuggestion {
        switch self {
        case .createEvent(let suggestion): suggestion
        }
    }

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        switch kind {
        case "create_event": self = .createEvent(try AICalendarSuggestion(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown AI draft action \(kind)")
        }
    }
}

/// `SearchFilter` (`ai/search_filter.rs`): a ready query, or a clarifying
/// question with selectable answers.
public enum AISearchFilter: Decodable, Sendable, Equatable {
    case query(String)
    case ask(AIFilterQuestion)

    private enum CodingKeys: String, CodingKey { case kind, query, question, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "" {
        case "query":
            self = .query(try c.decodeIfPresent(String.self, forKey: .query) ?? "")
        case "ask":
            self = .ask(AIFilterQuestion(question: try c.decodeIfPresent(String.self, forKey: .question) ?? "",
                                         options: try c.decodeIfPresent([AIFilterOption].self, forKey: .options) ?? []))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown search filter kind")
        }
    }
}

public struct AIFilterQuestion: Sendable, Equatable {
    public let question: String
    public let options: [AIFilterOption]

    public init(question: String, options: [AIFilterOption] = []) {
        self.question = question
        self.options = options
    }
}

public struct AIFilterOption: Decodable, Sendable, Equatable, Identifiable {
    public let label: String
    public let value: String
    public var id: String { value.isEmpty ? label : value }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One answered clarification round, sent back as `history`.
public struct AIFilterTurn: Encodable, Sendable, Equatable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// `AiIntent` (`models.rs`): the structured palette command.
public struct AIIntent: Decodable, Sendable, Hashable {
    /// "create_event" | "compose" | "search" | "go_to" | "none"
    public let kind: String
    public let summary: String?
    public let location: String?
    public let startsAt: Int64?
    public let endsAt: Int64?
    public let allDay: Bool?
    public let to: [String]?
    public let subject: String?
    public let body: String?
    public let query: String?
    public let view: String?

    private enum CodingKeys: String, CodingKey {
        case kind, summary, location, startsAt, endsAt, allDay, to, subject, body, query, view
    }

    public init(kind: String, summary: String? = nil, location: String? = nil, startsAt: Int64? = nil,
                endsAt: Int64? = nil, allDay: Bool? = nil, to: [String]? = nil, subject: String? = nil,
                body: String? = nil, query: String? = nil, view: String? = nil) {
        self.kind = kind
        self.summary = summary
        self.location = location
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.to = to
        self.subject = subject
        self.body = body
        self.query = query
        self.view = view
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "none"
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        startsAt = try c.decodeIfPresent(Int64.self, forKey: .startsAt)
        endsAt = try c.decodeIfPresent(Int64.self, forKey: .endsAt)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay)
        to = try c.decodeIfPresent([String].self, forKey: .to)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        view = try c.decodeIfPresent(String.self, forKey: .view)
    }
}

/// `AiAutomationPlan` (`models.rs`): the validated plan for a rule written in
/// plain language.
public struct AIAutomationAction: Codable, Sendable, Hashable {
    public let kind: String
    /// Route key, label id, or local annotation text, depending on `kind`.
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct AIAutomationPlan: Decodable, Sendable, Hashable {
    public let supported: Bool
    public let name: String
    /// The planner's normalized match condition; used as the rule's AI check.
    public let instruction: String
    public let actions: [AIAutomationAction]
    public let summary: String
    public let issues: [String]

    private enum CodingKeys: String, CodingKey { case supported, name, instruction, actions, summary, issues }

    public init(supported: Bool, name: String = "", instruction: String = "", actions: [AIAutomationAction] = [],
                summary: String = "", issues: [String] = []) {
        self.supported = supported
        self.name = name
        self.instruction = instruction
        self.actions = actions
        self.summary = summary
        self.issues = issues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        actions = try c.decodeIfPresent([AIAutomationAction].self, forKey: .actions) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        issues = try c.decodeIfPresent([String].self, forKey: .issues) ?? []
    }
}

// MARK: - Ask (`ai_ask`)

public struct AskCitation: Decodable, Sendable, Hashable, Identifiable {
    public let messageId: Int64
    public let threadId: Int64
    public let subject: String
    public let from: String
    public let date: Int64
    public let snippet: String

    public var id: Int64 { messageId }

    public init(messageId: Int64, threadId: Int64, subject: String, from: String, date: Int64, snippet: String) {
        self.messageId = messageId
        self.threadId = threadId
        self.subject = subject
        self.from = from
        self.date = date
        self.snippet = snippet
    }
}

public struct AskResult: Decodable, Sendable, Hashable {
    public let answer: String
    public let citations: [AskCitation]

    public init(answer: String, citations: [AskCitation]) {
        self.answer = answer
        self.citations = citations
    }
}
