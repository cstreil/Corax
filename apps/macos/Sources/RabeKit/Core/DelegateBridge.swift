import Foundation
import RabeBindings
import UserNotifications

/// Rust → Swift callbacks. They arrive on background threads; the platform work
/// (opening a link, clipboard) is handed to `PlatformServices`, whose Mac
/// implementation hops to the main thread (audit P1, items 3 and 5).
public final class DelegateBridge: RabeDelegate, @unchecked Sendable {
    private let onEventJSON: @Sendable (String) -> Void
    private let onRefused: @Sendable (String) -> Void
    private let onComposeMailto: @Sendable (URL) -> Void
    private let platform: any PlatformServices

    /// Cached `UNUserNotificationCenter` authorization. `false` only after the
    /// user denied notifications for good: `false` makes the host drop them,
    /// so an unknown or undetermined status counts as allowed.
    private let lock = NSLock()
    private var allowed = true

    public init(
        platform: any PlatformServices,
        onEventJSON: @escaping @Sendable (String) -> Void,
        onRefused: @escaping @Sendable (String) -> Void,
        onComposeMailto: @escaping @Sendable (URL) -> Void
    ) {
        self.platform = platform
        self.onEventJSON = onEventJSON
        self.onRefused = onRefused
        self.onComposeMailto = onComposeMailto
    }

    public func setNotificationsAllowed(_ value: Bool) {
        lock.lock(); allowed = value; lock.unlock()
    }

    public func notificationsAllowed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed
    }

    public func openUrl(url: String) {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased() else {
            onRefused(url); return
        }
        switch scheme {
        case "http", "https":
            platform.open(target)
        case "mailto":
            onComposeMailto(target)
        default:
            onRefused(url)
        }
    }

    public func openPath(path: String) {
        platform.open(URL(fileURLWithPath: path))
    }

    public func onEvent(eventJson: String) { onEventJSON(eventJson) }

    /// The host retries when this returns `false`, so it reports the real
    /// outcome: blocked until `add` has answered (we are on a host thread).
    public func notify(notification: RabeNotification) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if let threadId = notification.threadId { content.userInfo = ["threadId": threadId] }
        let request = UNNotificationRequest(identifier: "rabe.outbox.\(notification.id)", content: content, trigger: nil)

        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        UNUserNotificationCenter.current().add(request) { error in
            result.ok = (error == nil)
            if let error { PerfLog.shared.write("notification_failed id=\(notification.id) \(error.localizedDescription)") }
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else { return false }
        return result.ok
    }

    /// Called from a host thread. `DispatchQueue.main.sync` here could block the
    /// main thread until a host call times out (N5), so the copy is queued and
    /// reports success for the queueing itself.
    public func copyToClipboard(text: String) -> Bool {
        platform.copyToClipboard(text)
    }

    private final class ResultBox: @unchecked Sendable { var ok = false }
}
