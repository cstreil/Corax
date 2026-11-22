import AppKit
import Foundation
import CoraxKit

/// AppKit side of `PlatformServices` (M2.0, requirement 4). Created once by
/// `AppModel` and handed to `DelegateBridge` and `MailboxStore`; there is no
/// global instance.
final class MacPlatformServices: PlatformServices, @unchecked Sendable {
    /// Called from a host thread (`DelegateBridge.openUrl`/`openPath`), so the
    /// AppKit call is hopped to the main thread here.
    func open(_ url: URL) {
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// Called from a host thread. `DispatchQueue.main.sync` here could block the
    /// main thread until a host call times out (N5), so from a background thread
    /// the copy is queued and reports success for the queueing itself.
    func copyToClipboard(_ text: String) -> Bool {
        if Thread.isMainThread { return Self.writeToPasteboard(text) }
        DispatchQueue.main.async { _ = Self.writeToPasteboard(text) }
        return true
    }

    private static func writeToPasteboard(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }

    @MainActor
    func chooseSaveLocation(suggestedName: String) async -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        #if DEBUG || CORAX_TEST_HOOKS
        // Sandbox walkthrough: no pointer input, so the panel starts in /tmp.
        if let dir = ProcessInfo.processInfo.environment["CORAX_SAVE_PANEL_DIR"] {
            panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }
        #endif
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
