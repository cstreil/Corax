import AppKit
import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.8a — the findings from the user's first live test, mail and AI side.
///
/// Point 1 is the important one: the path from the format bar (or ⌘B) through
/// the editor's attributed string into `save_draft`'s `bodyHtml`. The editor is
/// a real `NSTextView` here, not just the bridge, because the live report said
/// the formatting is lost on the way out.
@MainActor
final class M28aTests: XCTestCase {
    private let theme = Theme.graphite

    private func editor(_ html: String) -> (RichEditorController, RichTextEditorView, NSWindow) {
        let view = RichTextEditorView.make(theme: theme)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scroll.documentView = view
        window.contentView = scroll
        let controller = RichEditorController()
        controller.textView = view
        view.controller = controller
        window.makeFirstResponder(view)
        controller.load(html: html, revision: 0, theme: theme)
        return (controller, view, window)
    }

    // MARK: Punkt 1 — Formatierung bis zum Entwurf

    /// Text first, mark it, then the format bar: the click moves the first
    /// responder to the button, and the marked range must still be the target.
    func testBoldItalicUnderlineFromTheBarReachTheSavedDraft() async {
        let core = FakeCore()
        let (controller, view, window) = editor("<p>Hallo Welt</p>")
        let storage = try! XCTUnwrap(view.textStorage)
        let marked = (storage.string as NSString).range(of: "Welt")
        view.setSelectedRange(marked)

        // What a click on a SwiftUI button does: the first responder moves away
        // from the text view before the action runs.
        let button = NSButton(title: "B", target: nil, action: nil)
        window.contentView?.addSubview(button)
        window.makeFirstResponder(button)
        XCTAssertEqual(view.selectedRange(), marked, "the marked range survives the click")

        controller.toggleBold()
        controller.toggleItalic()
        controller.toggleUnderline()

        let html = controller.html
        // All three traits wrap the marked word (`<b><i><u>Welt</u></i></b>`).
        for tag in ["<b>", "<i>", "<u>"] {
            XCTAssertTrue(html.contains(tag + "<i><u>Welt") || html.contains(tag), "missing \(tag): \(html)")
        }
        XCTAssertTrue(html.contains("Welt</u></i></b>"), "the word keeps every trait: \(html)")

        // And the draft that goes out carries the same HTML.
        let draft = ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil,
                                 to: [Address(name: nil, email: "a@b.de")], cc: [],
                                 subject: "s", body: "", client: core,
                                 toasts: ToastCenter(), settings: SettingsStore())
        draft.syncEditorBody(html)
        _ = await draft.saveNow()
        let saved = await core.savedDrafts.last
        let body = try! XCTUnwrap(saved?.bodyHtml)
        XCTAssertTrue(body.contains("Welt</u></i></b>"), "all traits in bodyHtml: \(body)")
        XCTAssertTrue(body.contains("<i>"), "italic in bodyHtml: \(body)")
        XCTAssertTrue(body.contains("<u>"), "underline in bodyHtml: \(body)")
    }

    /// The keyboard path (⌘B with no mark) works through the typing attributes;
    /// the text typed afterwards is bold.
    func testBoldTypedAfterTheShortcutIsBoldInTheDraft() async throws {
        let core = FakeCore()
        let (controller, view, _) = editor("<p>normal </p>")
        view.setSelectedRange(NSRange(location: 7, length: 0))
        controller.toggleBold()
        view.insertText("fett", replacementRange: view.selectedRange())

        let html = controller.html
        XCTAssertTrue(html.contains("<b>fett</b>"), "typed bold text in the HTML: \(html)")

        let draft = ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil,
                                 to: [Address(name: nil, email: "a@b.de")], cc: [],
                                 subject: "s", body: "", client: core,
                                 toasts: ToastCenter(), settings: SettingsStore())
        draft.syncEditorBody(html)
        _ = await draft.saveNow()
        let saved = await core.savedDrafts.last
        let body = try XCTUnwrap(saved?.bodyHtml)
        XCTAssertTrue(body.contains("<b>fett</b>"), "in bodyHtml: \(body)")
    }

    // MARK: Punkt 2 — Cursor und Zitat

    private func thread(html: String?, text: String?) -> ThreadDetail {
        let summary = ThreadSummary(id: 1, accountId: 1, accountEmail: "me@example.test",
                                    subject: "Plan", snippet: "s", participants: [],
                                    lastMessageAt: 1_700_000_000_000, messageCount: 1,
                                    unreadCount: 0, isStarred: false, hasAttachments: false,
                                    snoozedUntil: nil, labels: [])
        let message = MessageDetail(id: 5, threadId: 1, accountId: 1,
                                    from: Address(name: "Ana Müller", email: "ana@example.test"),
                                    to: [Address(name: nil, email: "me@example.test")], cc: [],
                                    subject: "Plan", date: 1_700_000_000_000, isRead: true,
                                    isStarred: false, isDraft: false, isOutgoing: false,
                                    snippet: "s", bodyState: "ready", textBody: text, htmlBody: html,
                                    attachments: [], sendState: nil, sendError: nil,
                                    listUnsubscribe: nil, listUnsubscribePost: nil)
        return ThreadDetail(thread: summary, messages: [message])
    }

    /// The attribution line stays *above* the blockquote (Tauri's `quoteToHtml`),
    /// and the caret gets its own empty paragraph with two blank lines below it.
    func testReplyStartsWithAnEmptyParagraphAndKeepsTheQuoteApart() {
        let detail = thread(html: "<p>Bis Freitag?</p>", text: "Bis Freitag?")
        let draft = ComposeDraft.reply(mode: .reply, to: detail, selfEmails: ["me@example.test"],
                                       client: FakeCore(), toasts: ToastCenter(),
                                       settings: SettingsStore())
        let html = draft.bodyHtml

        // Three empty paragraphs at the top: the caret line plus two blank lines.
        XCTAssertTrue(html.hasPrefix("<p></p><p></p><p></p>") || html.hasPrefix("<p><br></p><p><br></p><p><br></p>"),
                      "caret paragraph and two blank lines: \(html.prefix(120))")
        // The header is a plain paragraph, the original is the blockquote.
        let headerIndex = try! XCTUnwrap(html.range(of: "schrieb Ana Müller")).lowerBound
        let quoteIndex = try! XCTUnwrap(html.range(of: "<blockquote>")).lowerBound
        XCTAssertLessThan(headerIndex, quoteIndex, "attribution above the quote: \(html)")
        XCTAssertFalse(html.contains("<blockquote><p>Am "),
                       "the attribution must not sit inside the quote: \(html)")
        XCTAssertTrue(html.contains("<blockquote><p>Bis Freitag?</p></blockquote>"), html)
    }

    func testForwardKeepsTheHeaderOutsideTheBody() {
        let detail = thread(html: "<p>Der Text</p>", text: "Der Text")
        let draft = ComposeDraft.reply(mode: .forward, to: detail, selfEmails: ["me@example.test"],
                                       client: FakeCore(), toasts: ToastCenter(),
                                       settings: SettingsStore())
        let html = draft.bodyHtml
        XCTAssertTrue(html.contains("Weitergeleitete Nachricht"), html)
        XCTAssertTrue(html.hasPrefix("<p><br></p>"), "caret paragraph on top: \(html.prefix(80))")
        // A forward carries no blockquote: the original reads unchanged.
        XCTAssertFalse(html.contains("<blockquote>"), html)
    }

    /// The editor puts the caret into the first (empty) paragraph, so typing
    /// starts above the quote.
    func testCaretSitsInTheEmptyParagraphOfAReply() {
        let detail = thread(html: "<p>Bis Freitag?</p>", text: "Bis Freitag?")
        let draft = ComposeDraft.reply(mode: .reply, to: detail, selfEmails: ["me@example.test"],
                                       client: FakeCore(), toasts: ToastCenter(),
                                       settings: SettingsStore())
        let (_, view, _) = editor(draft.bodyHtml)
        let storage = try! XCTUnwrap(view.textStorage)
        XCTAssertEqual(view.selectedRange().location, 0)
        // The first line of the editor is empty, the quote comes later.
        let firstLine = (storage.string as NSString).components(separatedBy: "\n").first ?? "x"
        XCTAssertEqual(firstLine, "", "the caret line is empty")
    }

    /// A quote that arrives with blockquote markup is not promoted a second
    /// time — that is what pulled the attribution into the block.
    func testQuoteMarkupIsNotPromotedAgain() {
        let quoted = "<p>Am 3. März schrieb Ana:</p><blockquote><p>Hallo</p></blockquote>"
        let html = RichHTML.settingQuote(html: "", quoteHTML: quoted)
        XCTAssertTrue(html.contains("<p>Am 3. März schrieb Ana:</p>"), html)
        XCTAssertFalse(html.contains("<blockquote><p>Am 3. März"), html)
        // Input without any quote markup is still quoted whole.
        let plain = RichHTML.settingQuote(html: "", quoteHTML: "<p>nur Text</p>")
        XCTAssertTrue(plain.contains("<blockquote><p>nur Text</p></blockquote>"), plain)
    }
}
