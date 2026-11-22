import Foundation

// Codable mirrors of the settings-related DTOs in `src/ipc/types.ts` and
// `corax-host/src/dispatch.rs` (M2.1). Field names are the JSON names the host
// expects (`rename_all = "camelCase"`), and every payload struct matches the
// dispatcher's `deny_unknown_fields` input structs exactly.

// MARK: - Signatures (part of `Settings`)

/// A named, rich-HTML signature belonging to one account.
public struct Signature: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var accountId: Int64
    public var name: String
    /// Same HTML the composer emits.
    public var html: String

    public init(id: String, accountId: Int64, name: String, html: String) {
        self.id = id
        self.accountId = accountId
        self.name = name
        self.html = html
    }
}

/// Per-account default signature choice: one for new mail, one for reply.
public struct SignatureDefaults: Codable, Sendable, Hashable {
    public var newId: String?
    public var replyId: String?

    public init(newId: String? = nil, replyId: String? = nil) {
        self.newId = newId
        self.replyId = replyId
    }

    public var isEmpty: Bool { newId == nil && replyId == nil }
}

// MARK: - Snippets

public struct Snippet: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public var name: String
    /// Typed as `;shortcut` in the composer to expand it.
    public var shortcut: String?
    public var subject: String?
    public var bodyText: String
    public let usageCount: Int64
}

/// `SnippetInput` in the dispatcher (`deny_unknown_fields`: exactly these keys).
public struct SnippetInput: Codable, Sendable {
    public var id: Int64?
    public var name: String
    public var shortcut: String?
    public var subject: String?
    public var bodyText: String

    public init(id: Int64?, name: String, shortcut: String?, subject: String?, bodyText: String) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.subject = subject
        self.bodyText = bodyText
    }
}

// MARK: - Labels

/// `LabelInput` in the dispatcher: id, name, color, position. `isAuto` and
/// `keyword` are server-side and deliberately not part of a save.
public struct LabelInput: Codable, Sendable {
    public var id: Int64?
    public var name: String
    public var color: String
    public var position: Int64

    public init(id: Int64?, name: String, color: String, position: Int64) {
        self.id = id
        self.name = name
        self.color = color
        self.position = position
    }
}

// MARK: - Split rules and their conditions

/// How a text condition compares (case-insensitive; subjects are also
/// accent-folded).
public enum TextOp: String, Codable, Sendable, CaseIterable {
    case contains, equals, startsWith, endsWith
}

/// The legacy flat query of a split rule; only read when `condition` is unset.
public struct SplitRuleQuery: Codable, Sendable, Hashable {
    public var senders: [String]?
    public var excludeSenders: [String]?
    public var recipients: [String]?
    public var subjectContains: [String]?
    public var labels: [Int64]?
    public var isAutomated: Bool?
    public var hasAttachment: Bool?

    public init(senders: [String]? = nil, excludeSenders: [String]? = nil, recipients: [String]? = nil,
                subjectContains: [String]? = nil, labels: [Int64]? = nil, isAutomated: Bool? = nil,
                hasAttachment: Bool? = nil) {
        self.senders = senders
        self.excludeSenders = excludeSenders
        self.recipients = recipients
        self.subjectContains = subjectContains
        self.labels = labels
        self.isAutomated = isAutomated
        self.hasAttachment = hasAttachment
    }

    public var isFlatEmpty: Bool {
        (senders?.isEmpty ?? true) && (excludeSenders?.isEmpty ?? true) && (recipients?.isEmpty ?? true)
            && (subjectContains?.isEmpty ?? true) && (labels?.isEmpty ?? true)
            && isAutomated == nil && hasAttachment == nil
    }
}

/// A yes/no question answered by the decision model (or the chat fallback).
public struct AiCheck: Codable, Sendable, Hashable {
    public var instruction: String
    public var minConfidence: Double?

    public init(instruction: String, minConfidence: Double? = nil) {
        self.instruction = instruction
        self.minConfidence = minConfidence
    }
}

/// Typed condition tree (`RuleCondition` in the core). A tree only matches when
/// some leaf sits under an even number of `not`s.
public indirect enum RuleCondition: Sendable, Hashable, Codable {
    case all([RuleCondition])
    case any([RuleCondition])
    case not(RuleCondition)
    case sender(TextOp, String)
    case recipient(TextOp, String)
    case subject(TextOp, String)
    case label(Int64)
    case isAutomated(Bool)
    case hasAttachment(Bool)

    private enum CodingKeys: String, CodingKey { case kind, of, cond, op, value, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "all": self = .all(try c.decode([RuleCondition].self, forKey: .of))
        case "any": self = .any(try c.decode([RuleCondition].self, forKey: .of))
        case "not": self = .not(try c.decode(RuleCondition.self, forKey: .cond))
        case "sender": self = .sender(try c.decode(TextOp.self, forKey: .op), try c.decode(String.self, forKey: .value))
        case "recipient":
            self = .recipient(try c.decode(TextOp.self, forKey: .op), try c.decode(String.self, forKey: .value))
        case "subject": self = .subject(try c.decode(TextOp.self, forKey: .op), try c.decode(String.self, forKey: .value))
        case "label": self = .label(try c.decode(Int64.self, forKey: .id))
        case "isAutomated": self = .isAutomated(try c.decode(Bool.self, forKey: .value))
        case "hasAttachment": self = .hasAttachment(try c.decode(Bool.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unbekannte Bedingung „\(kind)“")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all(let of):
            try c.encode("all", forKey: .kind)
            try c.encode(of, forKey: .of)
        case .any(let of):
            try c.encode("any", forKey: .kind)
            try c.encode(of, forKey: .of)
        case .not(let cond):
            try c.encode("not", forKey: .kind)
            try c.encode(cond, forKey: .cond)
        case .sender(let op, let value):
            try c.encode("sender", forKey: .kind)
            try c.encode(op, forKey: .op)
            try c.encode(value, forKey: .value)
        case .recipient(let op, let value):
            try c.encode("recipient", forKey: .kind)
            try c.encode(op, forKey: .op)
            try c.encode(value, forKey: .value)
        case .subject(let op, let value):
            try c.encode("subject", forKey: .kind)
            try c.encode(op, forKey: .op)
            try c.encode(value, forKey: .value)
        case .label(let id):
            try c.encode("label", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .isAutomated(let value):
            try c.encode("isAutomated", forKey: .kind)
            try c.encode(value, forKey: .value)
        case .hasAttachment(let value):
            try c.encode("hasAttachment", forKey: .kind)
            try c.encode(value, forKey: .value)
        }
    }

    /// True for `.all` — used when the editor round-trips a condition tree.
    public var isAll: Bool {
        if case .all = self { return true }
        return false
    }

    /// One and-ed group of text conditions per field: what the simple editor
    /// builds, and what the condition builder shows as its top-level `all`.
    public static func allOf(_ list: [RuleCondition]) -> RuleCondition? {
        switch list.count {
        case 0: return nil
        case 1: return list[0]
        default: return .all(list)
        }
    }
}

/// `SplitInput` in the dispatcher (`deny_unknown_fields`: exactly these keys).
public struct SplitInput: Codable, Sendable {
    public var id: Int64?
    public var name: String
    public var position: Int64
    public var query: SplitRuleQuery
    public var condition: RuleCondition?
    public var target: String?
    public var ai: AiCheck?
    public var countAll: Bool

    public init(id: Int64?, name: String, position: Int64, query: SplitRuleQuery = SplitRuleQuery(),
                condition: RuleCondition? = nil, target: String? = nil, ai: AiCheck? = nil,
                countAll: Bool = false) {
        self.id = id
        self.name = name
        self.position = position
        self.query = query
        self.condition = condition
        self.target = target
        self.ai = ai
        self.countAll = countAll
    }
}

/// One reorderable tab: `kind` is "split" or "label", `id` its row id.
public struct TabRef: Codable, Sendable, Hashable {
    public var kind: String
    public var id: Int64

    public init(kind: String, id: Int64) {
        self.kind = kind
        self.id = id
    }

    public static func split(_ id: Int64) -> TabRef { TabRef(kind: "split", id: id) }
    public static func label(_ id: Int64) -> TabRef { TabRef(kind: "label", id: id) }
}

/// `preview_split_condition`: a dry run of one condition against recent mail.
public struct ConditionPreview: Codable, Sendable {
    public struct Sample: Codable, Sendable, Hashable {
        public let id: Int64
        public let subject: String
        public let fromAddr: String
        public let lastMessageAt: Int64
    }

    /// Matches among the `scanned` most recent threads.
    public let total: Int64
    public let scanned: Int64
    public let samples: [Sample]
}

// MARK: - MCP

public struct McpStatus: Codable, Sendable, Hashable {
    public let running: Bool
    /// Name im MCP-Handshake und als Schlüssel in Client-Konfigurationen
    /// (`corax`, im Standard noch `comail`). Kommt vom Host.
    public let name: String
    public let port: Int64
    public let url: String
    public let error: String?
    /// Distinct clients that connected since the server started.
    public let clientCount: Int64
}

public struct McpCall: Codable, Sendable, Hashable, Identifiable {
    public let at: Int64
    public let client: String
    public let tool: String
    public let ok: Bool
    public let error: String?

    public var id: String { "\(at)-\(client)-\(tool)" }
}

public enum McpInstallMethod: String, Codable, Sendable {
    case command, deeplink, write, copy
}

public enum McpSnippetLang: String, Codable, Sendable {
    case json, toml, yaml, shell, text
}

public struct McpClientInfo: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let method: McpInstallMethod
    public let detected: Bool
    public let configPath: String?
    public let snippetLang: McpSnippetLang
}

public struct McpInstallResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let message: String
    public let path: String?
    public let openUrl: String?
}
