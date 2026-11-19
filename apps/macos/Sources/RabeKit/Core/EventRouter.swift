import Foundation

/// Typed UI events. Names and payloads follow the Tauri events
/// (`{"name","payload"}`, see rabe-host/src/events.rs).
public enum HostEvent: Sendable {
    case ready(coreStartMs: Double)
    case failed(code: String, message: String)
    case mailUpdated(threadIds: [Int64])
    case mailNew(accountId: Int64, threadIds: [Int64])
    case syncProgress
    case networkState(online: Bool)
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
        case "network:state":
            let online = (payload["online"] as? Bool) ?? ((object["payload"] as? Bool) ?? true)
            return .networkState(online: online)
        default:
            return .other(name)
        }
    }
}
