import Foundation

/// Holds streamed AI tokens back so a view repaints at most N times a second
/// (M2.4, requirement 4: streaming with a throttle of at most 30 updates/s).
///
/// The host sends `ai:summary:token`, `ai:draft:token` and `ai:ask:token` as
/// small deltas. Publishing each one would rebuild the summary card or the
/// composer dozens of times a second for no visible gain; publishing at most
/// every 33 ms is smooth and leaves the frame loop alone.
///
/// The type is a value so a test drives it with a fake clock instead of
/// sleeping.
public struct TokenThrottle: Sendable {
    /// Minimum distance between two publishes.
    public let interval: TimeInterval
    private var pending = ""
    private var lastPublish: TimeInterval?

    public init(maxUpdatesPerSecond: Int = 30) {
        interval = 1 / Double(max(1, maxUpdatesPerSecond))
    }

    /// Adds one delta. Returns true when the caller should publish now; the
    /// text to show is `take()`.
    public mutating func append(_ delta: String, at now: TimeInterval) -> Bool {
        pending += delta
        guard !pending.isEmpty else { return false }
        if let lastPublish, now - lastPublish < interval { return false }
        lastPublish = now
        return true
    }

    /// The text buffered since the last publish, and clears it.
    public mutating func take() -> String {
        defer { pending = "" }
        return pending
    }

    /// True while tokens are waiting for the next window.
    public var hasPending: Bool { !pending.isEmpty }

    /// Publishes what is buffered, whatever the window says. Returns nil when
    /// nothing waited — the trailing flush after the last token, and the final
    /// answer, use this so no character is lost.
    public mutating func flush(at now: TimeInterval) -> String? {
        guard hasPending else { return nil }
        lastPublish = now
        return take()
    }
}
