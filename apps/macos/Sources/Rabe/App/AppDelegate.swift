import AppKit
import RabeKit
import UserNotifications

/// Host lifetime and system callbacks. The host itself is started by
/// `AppModel.shared` (first touched in `RabeApp.init`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PerfLog.shared.write("phase did_finish_launching ms=\(PerfLog.shared.elapsedMilliseconds)")
        UNUserNotificationCenter.current().delegate = self
        DebugAutomation.install()
        WebViewPool.shared.warmUp(remoteAllowed: AppModel.shared.settings.loadRemoteImages)
        installKeyMonitor()
        AppModel.shared.requestNotificationPermission()
        // System appearance drives the `system` theme.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
            let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Task { @MainActor in AppModel.shared.systemDark = dark }
        }
        Task { await AppModel.shared.start() }
    }

    private var appearanceObservation: NSKeyValueObservation?
    private var keyMonitor: Any?

    /// Single-key shortcuts work wherever the focus is, except in text input:
    /// the list does not have to be first responder (e.g. after a search).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { AppDelegate.routeKey(e) }
            return consumed ? nil : event
        }
    }

    private static func routeKey(_ event: NSEvent) -> Bool {
        let model = AppModel.shared
        guard let window = event.window, window.title == Instance.title else { return false }
        if window.firstResponder is NSText || window.firstResponder is NSTextView { return false }
        if window.attachedSheet != nil || model.paletteOpen || model.accountSheetOpen { return false }
        if model.shortcutsOpen {
            if event.keyCode == 53 || event.characters == "?" { model.shortcutsOpen = false; return true }
            return false
        }
        return ActionDispatcher.handleListKey(event)
    }

    /// Coming back to the app: re-check the notification permission (N3) and put
    /// the keyboard on the list at the first activation (R6).
    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.didBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Clicking a notification opens its thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let threadId = (response.notification.request.content.userInfo["threadId"] as? NSNumber)?.int64Value
        guard let threadId else { return }
        await MainActor.run { AppModel.shared.openThreadFromNotification(threadId) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
