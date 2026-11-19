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
    let provider: String
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
    public let isAuto: Bool?
}

public struct SplitRule: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let position: Int64
    /// Route target; `nil` means the rule is its own tab.
    public let target: String?
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

struct SyncStatus: Codable, Sendable, Hashable {
    public let accountId: Int64
    public let state: String
    let foregroundPhase: String
    public let background: SyncBackground?
}

public enum ActionKind: String, Codable, Sendable {
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case star, unstar, archive, unarchive, trash, snooze, unsnooze
}

public struct ActionResult: Codable, Sendable { public let actionIds: [Int64] }
struct UndoResult: Codable, Sendable { let undone: Bool }

public struct ContactSuggestion: Codable, Sendable, Hashable {
    public let name: String?
    public let email: String
    let interactions: Int64

    public var address: Address { Address(name: name, email: email) }
}

public struct SearchResults: Codable, Sendable { let threads: [ThreadSummary] }

public enum ComposeMode: String, Codable, Sendable { case new, reply, replyAll = "reply_all", forward }

public struct DraftAttachment: Codable, Sendable, Hashable { let filePath: String; let filename: String }

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
