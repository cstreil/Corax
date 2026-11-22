import Foundation

/// What a draft needs from the editor that shows it (M2.6).
///
/// `CoraxKit` stays free of AppKit, so the route from a command ("Baustein
/// einfügen", "Zitat", `⇧R`) into the caret is this small protocol: the
/// `NSTextView` side implements it, and a draft without an editor (tests, hook
/// runs, a closed inline composer) falls back to appending.
@MainActor
public protocol ComposeEditorHost: AnyObject {
    /// Replaces the selection with parsed HTML (a snippet, a quote).
    func insertHTML(_ html: String)
    /// Puts the caret into the editor.
    func focusEditor()
    /// `true` while the editor holds the keyboard of its window.
    var isEditorFocused: Bool { get }
}
