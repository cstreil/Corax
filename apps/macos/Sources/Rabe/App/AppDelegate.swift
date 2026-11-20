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
        // M2.5: staged previews of an earlier run (a crash leaves them behind).
        AttachmentPreview.removeStalePreviews()
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
        // M2.9: `⌃Tab` / `⌃⇧Tab` wechselt den Fokus auch aus dem Editor des
        // Verfassen-Panels heraus; `NSTextView` würde sonst nur ins nächste
        // Feld springen (§3.5, §5).
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, flags.contains(.control), !flags.contains(.command), !flags.contains(.option) {
            guard window.attachedSheet == nil, !model.paletteOpen else { return false }
            model.cycleDraftFocus(backward: flags.contains(.shift))
            return true
        }
        // M2.9: `⌘⇧M` und `⌘⇧⌫` gelten auch im Editor des Panels. Als Monitor
        // vor der Menüleiste, damit sie nicht von einem Feld geschluckt werden;
        // die Menüpunkte im Menü „Entwurf" zeigen dieselben Kürzel an.
        if flags == [.command, .shift], event.keyCode == 46, !model.compose.isEmpty {
            model.toggleComposeDock()
            return true
        }
        if flags == [.command, .shift], event.keyCode == 51,
           !model.compose.isEmpty || model.mailbox.inlineCompose != nil {
            model.discardOpenDraft()
            return true
        }
        // M2.14b: Menü-Kürzel mit Satzzeichen legt SwiftUI physisch aus (im
        // Menü stand `⌘ß` für `⌘/`, `⌥⌘ü` für `⌥⌘;`). Hier zählt das Zeichen
        // der gedrückten Taste, damit es auf deutscher und US-Tastatur trifft.
        let inText = window.firstResponder is NSText || window.firstResponder is NSTextView
        if let action = MonitorKeys.handle(KeyPress(event), inText: inText) {
            ActionDispatcher.perform(action)
            return true
        }
        if inText { return false }
        // M2.12: im Kalender gehören die Einzeltasten dem Kalender (Raster oder
        // Karte), nicht der Mailliste. Ohne diese Sperre leitete `W` eine Mail
        // weiter, `M` schlösse den Kalender und die Leertaste öffnete einen
        // Thread — der Kalender hat dafür eigenen Empfänger und Monitor.
        if model.calendarOpen { return false }
        if window.attachedSheet != nil || model.paletteOpen || model.accountSheetOpen { return false }
        if model.shortcutsOpen {
            if event.keyCode == 53 || event.characters == "?" { model.shortcutsOpen = false; return true }
            return false
        }
        // Eine Taste hier heißt: die Liste hat den Fokus, nicht das Panel
        // (§3.6.1) — sonst blieben die Listenkürzel nach einem Klick gesperrt.
        model.compose.takeListFocus()
        return ActionDispatcher.handleListKey(event)
    }

    /// Coming back to the app: re-check the notification permission (N3) and put
    /// the keyboard on the list at the first activation (R6).
    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.didBecomeActive()
    }

    /// N2 aus dem Audit M2: a label action holds `mark_read` back for up to
    /// 30 s. Quitting inside that window would leave the mails unread on the
    /// server, so the app sends them first and waits at most 2 s.
    ///
    /// A second ⌘Q while the flush runs quits at once — the user asked twice.
    private var terminationPrepared = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPrepared else { return .terminateNow }
        terminationPrepared = true
        Task { @MainActor in
            await AppModel.shared.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
        // M2.5: Quick Look previews live in an app-owned temp directory.
        AttachmentPreview.removeAll()
    }

    /// M2.4: the menu bar icon keeps the app alive, as Tauri's tray does — a
    /// closed window ends the window, not the process. "Rabe beenden" and ⌘Q
    /// still quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click with no window: bring the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .rabeShowMainWindow, object: nil) }
        return true
    }

    // Clicking a notification opens its thread, or the calendar on the meeting.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let eventId = (info["calendarEventId"] as? NSNumber)?.int64Value {
            let start = (info["occurrenceStart"] as? NSNumber)?.int64Value ?? 0
            await MainActor.run { AppModel.shared.openEventFromNotification(eventId: eventId, occurrenceStart: start) }
            return
        }
        guard let threadId = (info["threadId"] as? NSNumber)?.int64Value else { return }
        await MainActor.run { AppModel.shared.openThreadFromNotification(threadId) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
