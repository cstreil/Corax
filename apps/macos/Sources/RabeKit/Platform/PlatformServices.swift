import Foundation

/// What `Core` and `State` need from the platform that would otherwise pull
/// AppKit into `RabeKit` (M2.0, requirement 4).
///
/// One protocol for the three cases — open a link, copy text, ask where a file
/// goes. The Mac implementation is `MacPlatformServices` in the app target;
/// `AppModel` creates it and hands it to the objects that need it, so there is
/// no global.
///
/// `open` and `copyToClipboard` are called from the Rust host's threads (see
/// `DelegateBridge`); an implementation does its own hop to the main thread.
/// `chooseSaveLocation` runs on the main actor, where the panel belongs.
public protocol PlatformServices: AnyObject, Sendable {
    /// Opens a URL with the system handler (`NSWorkspace.open` on the Mac).
    /// Whether the URL may be opened at all is the caller's decision.
    func open(_ url: URL)

    /// Puts `text` on the clipboard (`NSPasteboard` on the Mac). `true` when
    /// the text was handed over.
    func copyToClipboard(_ text: String) -> Bool

    /// Asks for a destination file name and returns the chosen path, or `nil`
    /// when the user cancels (`NSSavePanel` on the Mac).
    @MainActor func chooseSaveLocation(suggestedName: String) async -> String?
}
