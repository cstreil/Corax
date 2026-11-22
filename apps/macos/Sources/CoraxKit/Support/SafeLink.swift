import Foundation

/// Which links may be opened from text the app renders (W4 aus dem Audit M2).
///
/// A model answer is content from a mail, so a prompt injection can make it
/// write `[Rechnung](file:///…)`, `smb://…` or an app scheme. `Text` with a
/// Markdown `AttributedString` makes those links clickable and hands them to
/// the system `openURL` — which launches the Finder, a network share or an app.
/// Only a web address is a link the reader can follow.
public enum SafeLink {
    /// `http` or `https` with a host; everything else stays text.
    public static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return !(url.host ?? "").isEmpty
    }

    public static func isOpenable(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return isOpenable(url)
    }
}
