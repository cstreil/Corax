import RabeKit
import SwiftUI

/// Markdown as plain `AttributedString` — the subset models actually write:
/// paragraphs, lists, **bold**, *italic*, `code`, links and #-headings.
///
/// `AttributedString(markdown:)` parses in-process and loads nothing, so there is
/// no network and no HTML: model output cannot inject anything. Links stay
/// clickable, but only as a web address (W4 aus dem Audit M2): `Text` hands a
/// link to the system `openURL`, and a prompt injection could smuggle in
/// `file:`, `smb:` or an app scheme that way. Everything else is discarded.
struct MarkdownText: View {
    let markdown: String
    var fontSize: CGFloat = 13
    let theme: Theme

    var body: some View {
        Text(attributed)
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                SafeLink.isOpenable(url) ? .systemAction : .discarded
            })
    }

    private var attributed: AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        // Model answers wrap inline code in backticks; interpret them.
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }
        return parsed
    }
}
