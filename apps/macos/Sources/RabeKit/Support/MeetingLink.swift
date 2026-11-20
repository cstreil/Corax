import Foundation

/// `join-next-meeting` (M2.6): which event the action opens, and whether its
/// link may leave the app.
///
/// Tauri fetches `list_events(now − 1h … now + 24h)`, drops events without a
/// join link, cancelled ones and ones that already ended, then takes the
/// earliest start. The same rules live here so they can be tested without a
/// host.
public enum MeetingLink {
    /// How far back a running meeting still counts as "the next one".
    public static let lookBack: Int64 = 3_600_000
    /// How far ahead the action looks.
    public static let lookAhead: Int64 = 86_400_000

    public static func range(now: Date) -> (start: Int64, end: Int64) {
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        return (millis - lookBack, millis + lookAhead)
    }

    /// The event to join, or nil when there is none.
    ///
    /// An event counts when it has a join link, is not cancelled, and has not
    /// ended yet (`endsAt`, else start + the default duration). The earliest
    /// start wins, so a running meeting beats one later today.
    public static func next(from events: [CalendarEvent], now: Date) -> CalendarEvent? {
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        return events
            .filter { event in
                guard let url = event.joinUrl, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                guard !CalendarEventRules.isCancelled(event) else { return false }
                return CalendarEventRules.eventEnd(event) > millis
            }
            .sorted { $0.startsAt < $1.startsAt }
            .first
    }

    /// A join link may only be `http`/`https`: the URL comes from a calendar
    /// event somebody else wrote, and handing any scheme to the system opener
    /// would let an invite launch a local application.
    public static func url(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let scheme = trimmed[..<colon].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }
}
