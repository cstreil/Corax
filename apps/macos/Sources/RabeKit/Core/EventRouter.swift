import Foundation

/// One streamed AI token (M2.4): a piece of the summary, the draft or the
/// answer being written. `requestId` ties draft/ask tokens to their call;
/// `threadId` does the same for the summary.
public struct AIStreamToken: Sendable, Equatable {
    public enum Kind: String, Sendable { case summary, draft, ask }

    public let kind: Kind
    public let requestId: String?
    public let threadId: Int64?
    public let delta: String

    public init(kind: Kind, requestId: String? = nil, threadId: Int64? = nil, delta: String) {
        self.kind = kind
        self.requestId = requestId
        self.threadId = threadId
        self.delta = delta
    }
}

/// `calendar:reminder` (core scheduler → host): a meeting starts within the
/// configured lead time. Tauri shows it as a desktop notification on the
/// frontend; the native app does the same in `AppModel`.
public struct CalendarReminder: Sendable, Equatable {
    public let event: CalendarEvent
    /// Start of this occurrence (recurrences fire per occurrence).
    public let occurrenceStart: Int64

    public init(event: CalendarEvent, occurrenceStart: Int64) {
        self.event = event
        self.occurrenceStart = occurrenceStart
    }
}

/// Typed UI events. Names and payloads follow the Tauri events
/// (`{"name","payload"}`, see rabe-host/src/events.rs).
public enum HostEvent: Sendable {
    case ready(coreStartMs: Double)
    case failed(code: String, message: String)
    case mailUpdated(threadIds: [Int64])
    case mailNew(accountId: Int64, threadIds: [Int64])
    case syncProgress
    case networkState(online: Bool)
    /// A move-family action failed for good (`action:failed`); the app tells
    /// the user instead of letting the mail jump back silently (M2.16).
    case actionFailed(actionId: Int64, threadId: Int64?, kind: String, reason: String, error: String)
    /// A CalDAV sync changed the stored events (`calendar:updated`).
    case calendarUpdated
    /// A meeting starts soon (`calendar:reminder`).
    case calendarReminder(CalendarReminder)
    /// Streaming text of a running AI call (M2.4).
    case aiToken(AIStreamToken)
    /// Sources of an `ai_ask` answer, usually before the answer is complete.
    case aiCitations(requestId: String, citations: [AskCitation])
    /// The text streamed so far was a preamble to a tool call: drop it.
    case aiAskReset(requestId: String)
    /// The token stream of one `ai_ask` ended.
    case aiAskDone(requestId: String)
    case other(String)
}

public enum EventRouter {
    /// Parses one event line. Unknown events are kept by name so they can be
    /// logged; the UI ignores them.
    public static func parse(_ json: String) -> HostEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let name = object["name"] as? String
        else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]
        func ids(_ key: String) -> [Int64] {
            (payload[key] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value }
        }
        func text(_ key: String) -> String? { payload[key] as? String }
        switch name {
        case "host:ready":
            return .ready(coreStartMs: (payload["coreStartMs"] as? NSNumber)?.doubleValue ?? -1)
        case "host:failed":
            return .failed(code: payload["code"] as? String ?? "unknown", message: payload["message"] as? String ?? "")
        case "mail:updated":
            return .mailUpdated(threadIds: ids("threadIds"))
        case "mail:new":
            return .mailNew(accountId: (payload["accountId"] as? NSNumber)?.int64Value ?? 0, threadIds: ids("threadIds"))
        case "sync:progress", "sync:status", "account:state":
            return .syncProgress
        case "thread:woke":
            return .mailUpdated(threadIds: [(payload["threadId"] as? NSNumber)?.int64Value ?? 0])
        case "action:failed":
            return .actionFailed(
                actionId: (payload["actionId"] as? NSNumber)?.int64Value ?? 0,
                threadId: (payload["threadId"] as? NSNumber)?.int64Value,
                kind: text("kind") ?? "",
                reason: text("reason") ?? "",
                error: text("error") ?? ""
            )
        case "calendar:updated":
            return .calendarUpdated
        case "calendar:reminder":
            guard let eventObject = payload["event"] as? [String: Any],
                  let eventData = try? JSONSerialization.data(withJSONObject: eventObject),
                  let event = try? JSONDecoder().decode(CalendarEvent.self, from: eventData) else { return nil }
            let start = (payload["occurrenceStart"] as? NSNumber)?.int64Value ?? event.startsAt
            return .calendarReminder(CalendarReminder(event: event, occurrenceStart: start))
        case "ai:summary:token":
            guard let delta = text("delta") else { return nil }
            return .aiToken(AIStreamToken(kind: .summary,
                                          threadId: (payload["threadId"] as? NSNumber)?.int64Value,
                                          delta: delta))
        case "ai:draft:token":
            guard let delta = text("delta") else { return nil }
            return .aiToken(AIStreamToken(kind: .draft, requestId: text("requestId"), delta: delta))
        case "ai:ask:token":
            guard let delta = text("delta") else { return nil }
            return .aiToken(AIStreamToken(kind: .ask, requestId: text("requestId"), delta: delta))
        case "ai:ask:citations":
            guard let requestId = text("requestId"),
                  let raw = payload["citations"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let citations = try? JSONDecoder().decode([AskCitation].self, from: data) else { return nil }
            return .aiCitations(requestId: requestId, citations: citations)
        case "ai:ask:reset":
            guard let requestId = text("requestId") else { return nil }
            return .aiAskReset(requestId: requestId)
        case "ai:ask:done":
            guard let requestId = text("requestId") else { return nil }
            return .aiAskDone(requestId: requestId)
        case "network:state":
            let online = (payload["online"] as? Bool) ?? ((object["payload"] as? Bool) ?? true)
            return .networkState(online: online)
        default:
            return .other(name)
        }
    }
}
