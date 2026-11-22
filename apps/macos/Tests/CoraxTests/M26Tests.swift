import AppKit
import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.6: the rich composer. Two halves — the AppKit bridge (what the editor
/// reads and writes) and the draft flow (what a draft stores and sends).
@MainActor
final class M26BridgeTests: XCTestCase {

    private let theme = Theme.graphite

    private func roundTrip(_ document: RichDocument, file: StaticString = #filePath, line: UInt = #line) -> RichDocument {
        let attributed = RichTextBridge.attributedString(from: document, theme: theme)
        return RichTextBridge.document(from: attributed)
    }

    func testEveryElementSurvivesTheBridge() {
        let link = "https://example.test/a?b=c"
        let document = RichDocument(blocks: [
            RichBlock(runs: [RichRun(text: "fett", bold: true),
                             RichRun(text: " kursiv", italic: true),
                             RichRun(text: " unter", underline: true),
                             RichRun(text: " durch", strike: true)]),
            RichBlock(runs: [RichRun(text: "Link", link: link)]),
            RichBlock(kind: .listItem(.bullet, depth: 1), runs: [RichRun(text: "Punkt")]),
            RichBlock(kind: .listItem(.ordered, depth: 2), runs: [RichRun(text: "tief")]),
            RichBlock(quoteDepth: 1, runs: [RichRun(text: "zitiert")]),
            RichBlock(isSignature: true, runs: [RichRun(text: "Gruß")]),
        ])
        let back = roundTrip(document)
        XCTAssertEqual(back, document)
    }

    func testSoftBreakStaysInsideItsParagraph() {
        let document = RichDocument(blocks: [RichBlock(runs: [RichRun(text: "a\nb")])])
        let attributed = RichTextBridge.attributedString(from: document, theme: theme)
        XCTAssertEqual(attributed.string, "a\u{2028}b\n")
        XCTAssertEqual(RichTextBridge.document(from: attributed), document)
    }

    func testEmptyParagraphsSurvive() {
        let document = RichDocument(blocks: [
            RichBlock(runs: [RichRun(text: "a")]), RichBlock(), RichBlock(runs: [RichRun(text: "b")]),
        ])
        XCTAssertEqual(roundTrip(document), document)
    }

    func testFormattingIsReadFromTheFont() throws {
        let manager = NSFontManager.shared
        let bold = manager.convert(RichTextBridge.bodyFont(), toHaveTrait: .boldFontMask)
        let italic = manager.convert(RichTextBridge.bodyFont(), toHaveTrait: .italicFontMask)
        let attributed = NSMutableAttributedString(string: "x", attributes: [.font: bold])
        attributed.append(NSAttributedString(string: "y", attributes: [.font: italic]))
        attributed.append(NSAttributedString(string: "\n"))
        let document = RichTextBridge.document(from: attributed)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].runs.map(\.bold), [true, false])
        XCTAssertEqual(document.blocks[0].runs.map(\.italic), [false, true])
    }

    func testImageAndMentionSurviveTheBridge() throws {
        let png = try XCTUnwrap(RichImage.parse(dataURL: RichHTMLTests.pngURL, alt: "Punkt"))
        let document = RichDocument(blocks: [
            RichBlock(runs: [.image(png)]),
            RichBlock(runs: [RichRun(text: "@Ana", mention: "ana@example.test")]),
        ])
        let back = roundTrip(document)
        XCTAssertEqual(back.blocks.first?.runs.first?.image?.data, png.data)
        XCTAssertEqual(back.blocks.first?.runs.first?.image?.alt, "Punkt")
        XCTAssertEqual(back.blocks.last?.runs.first?.mention, "ana@example.test")
    }

    func testParagraphStyleCarriesListAndQuote() throws {
        let document = RichDocument(blocks: [
            RichBlock(kind: .listItem(.ordered, depth: 1), runs: [RichRun(text: "eins")]),
            RichBlock(quoteDepth: 2, runs: [RichRun(text: "zwei")]),
        ])
        let attributed = RichTextBridge.attributedString(from: document, theme: theme)
        let first = try XCTUnwrap(attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(first.textLists.count, 1)
        let last = try XCTUnwrap(attributed.attribute(.paragraphStyle, at: attributed.length - 2,
                                                      effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(last.headIndent, 28)
        XCTAssertEqual(attributed.attribute(RichTextBridge.Key.quote, at: attributed.length - 2,
                                            effectiveRange: nil) as? Int, 2)
    }

    func testAttributedStringOfAnEmptyDocumentIsEmpty() {
        XCTAssertEqual(RichTextBridge.attributedString(from: RichDocument(), theme: theme).length, 0)
        XCTAssertEqual(RichTextBridge.document(from: NSAttributedString(string: "")).blocks.count, 0)
    }

    func testMentionChipRoundTripIsStable() {
        // A chip plus the space after it: the space must not wander into the
        // span, otherwise the HTML changes on every save (found in the M2.6
        // walkthrough: roundtrip equal=0, one byte apart).
        let document = RichDocument(blocks: [
            RichBlock(runs: [RichRun(text: "@Jana Petersen", mention: "jana@studio-peters.de"),
                             RichRun(text: " hallo")]),
        ])
        let first = RichHTML.html(from: document)
        XCTAssertEqual(first,
                       "<p><span class=\"co-mention\" data-email=\"jana@studio-peters.de\">@Jana Petersen</span> hallo</p>")
        let second = RichHTML.html(from: RichHTML.parse(first))
        XCTAssertEqual(second, first)
        let attributed = RichTextBridge.attributedString(from: RichHTML.parse(first), theme: .graphite)
        let back = RichTextBridge.document(from: attributed)
        XCTAssertEqual(back, RichHTML.parse(first))
        XCTAssertEqual(RichHTML.html(from: back), first)
    }

    func testMentionRangeDetection() {
        // The editor's `@` detection: only at a word boundary, only short words.
        XCTAssertEqual(RichEditorController.mentionRange(in: "Hallo @an", caret: 9), 6)
        XCTAssertEqual(RichEditorController.mentionRange(in: "@ana", caret: 4), 0)
        XCTAssertNil(RichEditorController.mentionRange(in: "Hallo an", caret: 8))
        XCTAssertNil(RichEditorController.mentionRange(in: "a@b", caret: 3))
        XCTAssertNil(RichEditorController.mentionRange(in: "Hallo @ana mueller", caret: 18))
    }

    func testImageEncodingLimits() throws {
        // A tiny picture is stored as it is; a huge one is refused, not stored
        // as a 3 MB data URL (the draft would die in other clients).
        let small = NSImage(size: NSSize(width: 20, height: 20))
        small.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        small.unlockFocus()
        let encoded = try XCTUnwrap(RichTextBridge.encode(small))
        XCTAssertLessThanOrEqual(encoded.data.count, RichLimits.maxImageBytes)
        XCTAssertTrue(encoded.mime == .png || encoded.mime == .jpeg)

        let large = NSImage(size: NSSize(width: 6000, height: 4000))
        large.lockFocus()
        for _ in 0..<120 {
            NSColor(calibratedHue: CGFloat.random(in: 0...1), saturation: 1, brightness: 1, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 6000, height: 4000).fill()
        }
        large.unlockFocus()
        let scaled = RichTextBridge.downscaled(large, maxPixel: RichTextBridge.maxPixelSize)
        XCTAssertLessThanOrEqual(max(scaled.size.width, scaled.size.height), RichTextBridge.maxPixelSize)
        let bigEncoded = RichTextBridge.encode(large)
        if let bigEncoded {
            XCTAssertLessThanOrEqual(bigEncoded.data.count, RichLimits.maxImageBytes)
        }
    }
}

/// The composer's data flow: what a draft stores, what it sends, and how the
/// AI, snippets and quotes keep signature and quote in place.
@MainActor
final class M26ComposerTests: XCTestCase {
    private var core: FakeCore!
    private var toasts: ToastCenter!

    override func setUp() {
        super.setUp()
        core = FakeCore()
        toasts = ToastCenter()
    }

    private func settings(with signature: String?) async throws -> SettingsStore {
        let settings = SettingsStore()
        settings.client = core
        settings.toasts = toasts
        var object: [String: Any] = [:]
        if let signature {
            object["signatureList"] = [["id": "s1", "accountId": 1, "name": "Privat", "html": signature]]
            object["signatureDefaults"] = ["1": ["newId": "s1", "replyId": "s1"]]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await core.setSettingsJSON(String(decoding: data, as: UTF8.self))
        await settings.load()
        return settings
    }

    private func draft(_ settings: SettingsStore, mode: ComposeMode = .new, body: String = "",
                       to: [Address] = [Address(name: nil, email: "ana@example.test")]) -> ComposeDraft {
        ComposeDraft(mode: mode, accountId: 1, inReplyTo: mode == .new ? nil : 5,
                     to: to, cc: [], subject: "Termin",
                     body: body, threadId: mode == .new ? nil : 7, senderName: "Christian",
                     client: core, aiClient: core, toasts: toasts, settings: settings)
    }

    // MARK: Was gespeichert wird

    func testDraftSendsHTMLAndTextPart() async throws {
        let settings = try await settings(with: nil)
        let text = draft(settings, body: "Hallo Welt")
        text.syncEditorBody("<p><b>Hallo</b> Welt</p>")
        await text.saveNow()
        let sent = await core.savedDrafts
        // The text part is the plain text of the HTML, the HTML the rich body.
        XCTAssertEqual(sent.last?.bodyText, "Hallo Welt")
        XCTAssertEqual(sent.last?.bodyHtml, "<p><b>Hallo</b> Welt</p>")
    }

    func testQuoteAndSignatureReachTheTextPart() async throws {
        let settings = try await settings(with: "<p>Viele Grüße</p>")
        let reply = draft(settings, mode: .reply, body: "")
        reply.quoteOriginal("<blockquote><p>Original</p></blockquote>")
        await reply.saveNow()
        let sent = await core.savedDrafts
        let text = try XCTUnwrap(sent.last)
        XCTAssertEqual(text.bodyText, "Viele Grüße\n\n> Original".isEmpty ? "" : "Viele Grüße\n\n> Original")
        XCTAssertEqual(text.bodyHtml?.contains("class=\"co-signature\""), true)
        XCTAssertEqual(text.bodyHtml?.contains("<blockquote>"), true)
    }

    func testSignatureIsNotContent() async throws {
        let settings = try await settings(with: "<p>Gruß</p>")
        let empty = draft(settings, body: "", to: [])
        XCTAssertEqual(empty.aiBodyText, "")
        XCTAssertFalse(RichHTML.hasSignature(html: empty.bodyHtml) == false, "signature is in the body")
        // …and a saved draft carries it, without counting as typed text.
        _ = await empty.saveNow()
        let args = await core.savedDrafts
        XCTAssertTrue(args.isEmpty, "a signature alone is not saved as a draft")
    }

    func testDefaultSignaturePicksByMode() async throws {
        let settings = try await settings(with: "<p>Gruß</p>")
        XCTAssertNotNil(ComposeDraft.defaultSignature(settings: settings, accountId: 1, mode: .new))
        XCTAssertNotNil(ComposeDraft.defaultSignature(settings: settings, accountId: 1, mode: .reply))
        XCTAssertNil(ComposeDraft.defaultSignature(settings: settings, accountId: 2, mode: .new))
    }

    // MARK: KI, Baustein, Zitat

    func testAIDraftKeepsSignatureAndQuote() async throws {
        let settings = try await settings(with: "<p>Gruß</p>")
        let reply = draft(settings, mode: .reply)
        reply.quoteOriginal("<blockquote><p>Original</p></blockquote>")
        let ok = await reply.aiDraft(instruction: "Zusagen")
        XCTAssertTrue(ok)
        let request = await core.aiDraftRequest
        // The model sees the typed text only — no signature, no quoted mail.
        XCTAssertNil(request?.currentDraft)
        XCTAssertTrue(reply.bodyHtml.contains("class=\"co-signature\""))
        XCTAssertTrue(reply.bodyHtml.contains("<blockquote>"))
        XCTAssertTrue(reply.body.contains("Guten Tag, ich sage zu."))
    }

    func testAIUndoRestoresTheHTML() async throws {
        let settings = try await settings(with: "<p>Gruß</p>")
        let reply = draft(settings, mode: .reply, body: "Alter Text")
        let before = reply.bodyHtml
        _ = await reply.aiDraft(instruction: "Kürzer")
        XCTAssertTrue(reply.canUndoAIChange)
        XCTAssertTrue(reply.undoAIChange())
        XCTAssertEqual(reply.bodyHtml, before)
    }

    func testSnippetAndQuoteGoToTheEditor() async throws {
        let settings = try await settings(with: nil)
        let reply = draft(settings, mode: .reply, body: "Text")
        let host = FakeEditorHost()
        reply.editorHost = host
        reply.insertSnippet(Snippet(id: 1, name: "Zusage", shortcut: nil, subject: "Termin",
                                    bodyText: "Gerne.", usageCount: 0))
        reply.insertQuote("Das ist zitiert.")
        XCTAssertEqual(host.insertions.count, 2)
        XCTAssertEqual(host.insertions.first, "<p>Gerne.</p>")
        XCTAssertTrue(host.insertions.last?.contains("<blockquote>") ?? false)
        XCTAssertTrue(host.insertions.last?.contains("Das ist zitiert.") ?? false)
    }

    func testQuoteWithoutEditorGoesAboveTheText() async throws {
        let settings = try await settings(with: nil)
        let reply = draft(settings, mode: .reply, body: "Meine Antwort")
        reply.insertQuote("Das ist zitiert.")
        XCTAssertTrue(reply.body.hasPrefix("> Das ist zitiert."))
        XCTAssertTrue(reply.body.contains("Meine Antwort"))
    }

    // MARK: Zitate von außen

    func testReplyQuoteHasAttributionAndBlockquote() throws {
        let html = Quoting.replyHTML(bodyHTML: "<p>Hallo <b>du</b></p>", bodyText: nil,
                                     from: Address(name: "Ana", email: "ana@example.test"),
                                     date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(html.contains("schrieb Ana &lt;ana@example.test&gt;:"))
        let document = RichHTML.parse(html)
        XCTAssertEqual(document.blocks.first?.quoteDepth, 0, "the attribution is not quoted")
        XCTAssertTrue(document.blocks.contains { $0.quoteDepth == 1 && $0.runs.contains { $0.bold } },
                      "the quoted text keeps its formatting")
    }

    func testReplyQuoteFallsBackToTextAndDropsImages() throws {
        let withImage = "<p>vor <img src=\"\(RichHTMLTests.pngURL)\"> nach</p>"
        let html = Quoting.replyHTML(bodyHTML: withImage, bodyText: "egal",
                                     from: Address(name: nil, email: "ana@example.test"),
                                     date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(html.contains("data:image"), "pictures are not quoted into every draft")
        let text = Quoting.replyHTML(bodyHTML: nil, bodyText: "Zeile 1\nZeile 2",
                                     from: Address(name: nil, email: "ana@example.test"),
                                     date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(RichHTML.parse(text).blocks.contains { $0.quoteDepth == 1 })
        XCTAssertTrue(RichHTML.plainText(html: text).contains("Zeile 1"))
    }

    func testForwardBlockHasTaurisHeader() throws {
        let html = Quoting.forwardHTML(bodyHTML: "<p>Inhalt</p>", bodyText: nil,
                                       from: Address(name: "Ana", email: "ana@example.test"),
                                       to: [Address(name: nil, email: "ich@example.test")],
                                       subject: "Termin", date: Date(timeIntervalSince1970: 1_800_000_000))
        let text = RichHTML.plainText(html: html)
        XCTAssertTrue(text.contains("---------- Weitergeleitete Nachricht ----------"))
        XCTAssertTrue(text.contains("Von: Ana <ana@example.test>"))
        XCTAssertTrue(text.contains("Betreff: Termin"))
        XCTAssertTrue(text.contains("An: ich@example.test"))
        XCTAssertTrue(text.hasSuffix("Inhalt"))
    }

    // MARK: Inhalt ersetzen

    func testReplacingContentKeepsQuoteAndSignature() throws {
        let body = RichHTML.settingSignature(html: "<p>Antwort</p>", signatureHTML: "<p>Gruß</p>")
        let withQuote = RichHTML.settingQuote(html: body, quoteHTML: "<blockquote><p>Original</p></blockquote>")
        let replaced = RichHTML.replacingContent(html: withQuote, withText: "Neuer Text")
        let document = RichHTML.parse(replaced)
        XCTAssertEqual(document.blocks.filter { !$0.isSignature && $0.quoteDepth == 0 && !$0.isEmpty }
            .map(\.text), ["Neuer Text"])
        XCTAssertEqual(document.blocks.filter(\.isSignature).count, 1)
        XCTAssertEqual(document.blocks.filter { $0.quoteDepth > 0 }.count, 1)
    }

    func testAiPlainTextIgnoresQuoteAndSignature() throws {
        let body = "<p>Mein Text</p><div class=\"co-signature\"><p>Gruß</p></div>"
        let withQuote = RichHTML.settingQuote(html: body, quoteHTML: "<blockquote><p>Alte Mail</p></blockquote>")
        XCTAssertEqual(RichHTML.aiPlainText(html: withQuote), "Mein Text")
        XCTAssertTrue(RichHTML.plainText(html: withQuote).contains("Alte Mail"))
    }
}

/// Records what a draft asks the editor to insert.
@MainActor
final class FakeEditorHost: ComposeEditorHost {
    var insertions: [String] = []
    var focused = false

    func insertHTML(_ html: String) { insertions.append(html) }
    func focusEditor() { focused = true }
    var isEditorFocused: Bool { focused }
}
