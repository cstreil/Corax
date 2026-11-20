import Foundation

// Codable mirrors of the M1 subset of `src/ipc/types.ts`.
//
// The Rust DTOs serialize with `serde(rename_all = "camelCase")`, so the JSON
// keys already match Swift property names; the decoder uses the default key
// strategy (a snake-case conversion would break `threadIds` and friends).

public struct Address: Codable, Sendable, Hashable {
    public var name: String?
    public var email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }

    /// `addressName` in `src/lib/format.ts`.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name.trimmingCharacters(in: .whitespaces)
        }
        return email.split(separator: "@").first.map(String.init) ?? email
    }

    public var firstName: String {
        displayName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? displayName
    }
}

public struct Account: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let email: String
    public let displayName: String?
    public let provider: String
    let authKind: String
    let syncState: String

    public var label: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty { return displayName }
        return email.split(separator: "@").first.map(String.init) ?? email
    }
}

public enum MailView: String, Codable, Sendable, CaseIterable, Identifiable {
    case inbox, starred, snoozed, sent, drafts, done, trash, spam, all
    public var id: String { rawValue }
}

public struct ThreadSummary: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let accountId: Int64
    public let accountEmail: String
    public var subject: String
    public var snippet: String
    public var participants: [Address]
    var lastMessageAt: Int64
    public var messageCount: Int64
    var unreadCount: Int64
    public var isStarred: Bool
    public var hasAttachments: Bool
    var snoozedUntil: Int64?
    public var labels: [Int64]

    public var isUnread: Bool { unreadCount > 0 }
    public var date: Date { Date(timeIntervalSince1970: Double(lastMessageAt) / 1000) }
}

public struct ThreadPage: Codable, Sendable {
    public let threads: [ThreadSummary]
    public let nextCursor: Int64?
}

public struct AttachmentMeta: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let filename: String?
    public let mimeType: String?
    public let size: Int64?
    public let isInline: Bool
}

public struct MessageDetail: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let threadId: Int64
    public let accountId: Int64
    public let from: Address
    public let to: [Address]
    public let cc: [Address]
    public let subject: String
    public let date: Int64
    var isRead: Bool
    public var isStarred: Bool
    public let isDraft: Bool
    public let isOutgoing: Bool
    public let snippet: String
    public var bodyState: String
    public var textBody: String?
    public var htmlBody: String?
    public let attachments: [AttachmentMeta]
    public let sendState: String?
    let sendError: String?
    /// Raw `List-Unsubscribe` header (M2.4); nil when the message has none.
    public let listUnsubscribe: String?
    /// `List-Unsubscribe=One-Click` marks the HTTPS URI as an RFC 8058 endpoint.
    public let listUnsubscribePost: String?

    /// The thread header offers "Abmelden" for such a message (Tauri's
    /// `latestUnsubscribeMessage`).
    public var canUnsubscribe: Bool { !(listUnsubscribe ?? "").isEmpty }

    public var dateValue: Date { Date(timeIntervalSince1970: Double(date) / 1000) }
}

public struct ThreadDetail: Codable, Sendable {
    public var thread: ThreadSummary
    public var messages: [MessageDetail]
}

public struct Label: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let color: String
    /// IMAP keyword atom this label maps to on the server.
    public let keyword: String
    public let position: Int64
    /// System auto-category (Marketing/News/Social/Pitch); local-only.
    public let isAuto: Bool?
}

public struct SplitRule: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let position: Int64
    /// Legacy flat query; evaluated only when `condition` is unset.
    public var query: SplitRuleQuery
    /// Typed condition tree; replaces `query` when present.
    public var condition: RuleCondition?
    /// Route target; `nil` means the rule is its own tab ("important", "other",
    /// "label:<id>").
    public let target: String?
    /// Optional AI check (decision model, else the chat model).
    public var ai: AiCheck?
    /// Badge every conversation in the tab, not only the unread ones.
    public var countAll: Bool

    public init(id: Int64, name: String, position: Int64, query: SplitRuleQuery = SplitRuleQuery(),
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

public struct UnreadCounts: Codable, Sendable {
    public let inbox: Int64
    let important: Int64
    public let other: Int64
    let splits: [String: Int64]
    public let labels: [String: Int64]
    let views: [String: Int64]
}

public struct SyncBackground: Codable, Sendable, Hashable {
    public let phase: String
    public let done: Int64
    let total: Int64
    public let failed: Int64
}

public struct SyncStatus: Codable, Sendable, Hashable {
    public let accountId: Int64
    public let state: String
    let foregroundPhase: String
    public let background: SyncBackground?
}

/// `ActionKind` in `comail-core/src/models.rs`. The M2 audit released the
/// M2.5 kinds too; `CommandPolicy.actionKinds` still keeps the door shut for
/// kinds the UI never sends.
public enum ActionKind: String, Codable, Sendable {
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case star, unstar, archive, unarchive, trash, snooze, unsnooze
    // M2.5
    case deletePermanently = "delete_permanently"
    case spam
    case notSpam = "not_spam"
    case move
    case addLabel = "add_label"
    case removeLabel = "remove_label"
}

/// `PerformActionArgs.params` (`deny_unknown_fields` on the Rust side):
/// `wakeAt` for snooze, `targetFolderId` for move, `labelId` for add/remove.
public struct ActionParams: Codable, Sendable, Hashable {
    public var wakeAt: Int64?
    public var targetFolderId: Int64?
    public var labelId: Int64?

    public init(wakeAt: Int64? = nil, targetFolderId: Int64? = nil, labelId: Int64? = nil) {
        self.wakeAt = wakeAt
        self.targetFolderId = targetFolderId
        self.labelId = labelId
    }
}

public struct ActionResult: Codable, Sendable { public let actionIds: [Int64] }

/// `FolderInfo` in the core: IMAP folder names for the move popover (M2.5).
public struct FolderInfo: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let accountId: Int64
    public let imapName: String
    public let delimiter: String?
    public let role: String?
}
struct UndoResult: Codable, Sendable { let undone: Bool }

public struct ContactSuggestion: Codable, Sendable, Hashable {
    public let name: String?
    public let email: String
    let interactions: Int64

    public var address: Address { Address(name: name, email: email) }
}

public struct SearchResults: Codable, Sendable { let threads: [ThreadSummary] }

public enum ComposeMode: String, Codable, Sendable { case new, reply, replyAll = "reply_all", forward }

public struct DraftAttachment: Codable, Sendable, Hashable {
    public let filePath: String
    public let filename: String

    public init(filePath: String, filename: String) {
        self.filePath = filePath
        self.filename = filename
    }
}

public struct SaveDraftArgs: Codable, Sendable {
    var draftId: Int64?
    public var accountId: Int64
    public var to: [Address]
    public var cc: [Address]
    var bcc: [Address]
    public var subject: String
    var bodyText: String
    var bodyHtml: String?
    public var mode: ComposeMode
    var inReplyToMessageId: Int64?
    public var attachments: [DraftAttachment]
}

struct SaveDraftResult: Codable, Sendable { let draftId: Int64 }
public struct QueueSendResult: Codable, Sendable { let actionId: Int64; let dispatchAt: Int64 }

public struct AddPasswordAccountArgs: Codable, Sendable {
    public var email: String
    public var displayName: String?
    public var username: String
    public var password: String
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int

    public init(email: String, displayName: String?, username: String, password: String,
                imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int) {
        self.email = email
        self.displayName = displayName
        self.username = username
        self.password = password
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
    }
}

public struct ConnectionTestResult: Codable, Sendable { public let ok: Bool; public let error: String? }

/// Wrapper some commands expect: `{"args": {...}}` (`WithArgs<T>` in dispatch.rs).
struct WithArgs<T: Encodable & Sendable>: Encodable, Sendable { let args: T }

// MARK: - M2.4: verification code, unsubscribe, avatars

/// `VerificationCode` in `types.ts`: the newest one-time code from the mail
/// (`latest_verification_code`), used by the palette command.
public struct VerificationCode: Codable, Sendable, Hashable {
    public let code: String
    public let messageId: Int64
    public let threadId: Int64
    public let sender: String
    public let subject: String
    public let receivedAt: Int64
}

/// `UnsubscribeOutcome` in `types.ts`, an enum-like union on the wire.
/// "Unsubscribed" may only be claimed for `oneClick` and `mailtoSent`; a
/// `needsBrowser` answer hands the URL to the user.
public enum UnsubscribeOutcome: Decodable, Sendable, Equatable {
    case oneClick
    case mailtoSent
    case needsBrowser(url: String)

    private enum CodingKeys: String, CodingKey { case kind, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "oneClick": self = .oneClick
        case "mailtoSent": self = .mailtoSent
        case "needsBrowser": self = .needsBrowser(url: try c.decodeIfPresent(String.self, forKey: .url) ?? "")
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unbekanntes Ergebnis: \(other)")
        }
    }
}
