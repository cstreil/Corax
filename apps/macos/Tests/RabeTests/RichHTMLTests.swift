import XCTest
@testable import RabeKit

/// M2.6: the composer's HTML subset. These tests are the security and the
/// round-trip half of the feature: whatever a draft, a signature or pasted
/// content contains, `RichHTML` has to come back with text, formatting and
/// pictures — and with nothing that could run in a mail client.
final class RichHTMLTests: XCTestCase {

    // MARK: Hilfen

    /// The smallest real PNG (1×1, transparent) as a `data:` URL.
    static let pngURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PzWvWQAAAABJRU5ErkJggg=="

    private func roundTrip(_ html: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let once = RichHTML.html(from: RichHTML.parse(html))
        let twice = RichHTML.html(from: RichHTML.parse(once))
        XCTAssertEqual(once, twice, "writer is not stable for \(html)", file: file, line: line)
        return once
    }

    private func blocks(_ html: String) -> [RichBlock] {
        RichHTML.parse(html).blocks
    }

    private func text(_ html: String) -> String {
        RichHTML.parse(html).plainText
    }

    // MARK: Jedes Element

    func testParagraphRoundTrip() {
        XCTAssertEqual(roundTrip("<p>Hallo Welt</p>"), "<p>Hallo Welt</p>")
        XCTAssertEqual(roundTrip("<p>a</p><p>b</p>"), "<p>a</p><p>b</p>")
        // A div is a block boundary too (Tauri's contenteditable writes divs).
        XCTAssertEqual(roundTrip("<div>a</div><div>b</div>"), "<p>a</p><p>b</p>")
    }

    func testInlineFormattingRoundTrip() {
        XCTAssertEqual(roundTrip("<p><b>fett</b></p>"), "<p><b>fett</b></p>")
        XCTAssertEqual(roundTrip("<p><strong>fett</strong></p>"), "<p><b>fett</b></p>")
        XCTAssertEqual(roundTrip("<p><i>kursiv</i></p>"), "<p><i>kursiv</i></p>")
        XCTAssertEqual(roundTrip("<p><em>kursiv</em></p>"), "<p><i>kursiv</i></p>")
        XCTAssertEqual(roundTrip("<p><u>unter</u></p>"), "<p><u>unter</u></p>")
        XCTAssertEqual(roundTrip("<p><s>durch</s></p>"), "<p><s>durch</s></p>")
        XCTAssertEqual(roundTrip("<p><strike>durch</strike></p>"), "<p><s>durch</s></p>")
        XCTAssertEqual(roundTrip("<p><del>durch</del></p>"), "<p><s>durch</s></p>")
    }

    func testNestedFormattingRoundTrip() {
        let html = "<p><b><i><u><s>alles</s></u></i></b></p>"
        XCTAssertEqual(roundTrip(html), html)
        // Mixed: the run splits where the formatting changes.
        XCTAssertEqual(roundTrip("<p><b>a</b>b<i>c</i></p>"), "<p><b>a</b>b<i>c</i></p>")
    }

    func testLinkRoundTrip() {
        XCTAssertEqual(roundTrip("<p><a href=\"https://example.test/x\">Link</a></p>"),
                       "<p><a href=\"https://example.test/x\">Link</a></p>")
        XCTAssertEqual(roundTrip("<p><a href=\"mailto:a@b.de\">a@b.de</a></p>"),
                       "<p><a href=\"mailto:a@b.de\">a@b.de</a></p>")
        // A link inside bold keeps both.
        XCTAssertEqual(roundTrip("<p><a href=\"https://x.test\"><b>fett</b></a></p>"),
                       "<p><a href=\"https://x.test\"><b>fett</b></a></p>")
        let block = blocks("<p><a href=\"tel:+49123\">anrufen</a></p>")[0]
        XCTAssertEqual(block.runs[0].link, "tel:+49123")
        XCTAssertEqual(block.runs[0].text, "anrufen")
    }

    func testListsRoundTrip() {
        XCTAssertEqual(roundTrip("<ul><li>a</li><li>b</li></ul>"), "<ul><li>a</li><li>b</li></ul>")
        XCTAssertEqual(roundTrip("<ol><li>eins</li><li>zwei</li></ol>"), "<ol><li>eins</li><li>zwei</li></ol>")
        // Nesting is a list inside the parent `<li>`.
        XCTAssertEqual(roundTrip("<ul><li>a<ul><li>b</li></ul></li></ul>"),
                       "<ul><li>a<ul><li>b</li></ul></li></ul>")
        let nested = blocks("<ul><li>a<ul><li>b</li></ul></li></ul>")
        XCTAssertEqual(nested.map(\.listDepth), [1, 2])
        XCTAssertEqual(nested.map(\.listKind), [.bullet, .bullet])
    }

    func testBlockquoteRoundTrip() {
        XCTAssertEqual(roundTrip("<blockquote><p>zitiert</p></blockquote>"),
                       "<blockquote><p>zitiert</p></blockquote>")
        XCTAssertEqual(roundTrip("<blockquote><p>a</p><p>b</p></blockquote>"),
                       "<blockquote><p>a</p><p>b</p></blockquote>")
        XCTAssertEqual(blocks("<blockquote><p>a</p></blockquote>")[0].quoteDepth, 1)
        XCTAssertEqual(blocks("<blockquote><blockquote><p>a</p></blockquote></blockquote>")[0].quoteDepth, 2)
    }

    func testQuoteInsideListAndListInsideQuote() {
        let html = "<blockquote><ul><li>a</li></ul></blockquote>"
        let parsed = blocks(html)
        XCTAssertEqual(parsed[0].quoteDepth, 1)
        XCTAssertEqual(parsed[0].listDepth, 1)
        // Whatever order the wrappers are written in, parsing them again gives
        // the same document.
        let written = roundTrip(html)
        XCTAssertEqual(RichHTML.parse(written).blocks, parsed)
    }

    func testLineBreaksAndEmptyParagraphs() {
        XCTAssertEqual(roundTrip("<p>a<br>b</p>"), "<p>a<br>b</p>")
        XCTAssertEqual(blocks("<p>a<br>b</p>")[0].runs.map(\.text).joined(), "a\nb")
        XCTAssertEqual(roundTrip("<p></p>"), "<p><br></p>")
        XCTAssertEqual(roundTrip("<div><br></div>"), "<p><br></p>")
        XCTAssertEqual(text("<p>a</p><p><br></p><p>b</p>"), "a\n\nb")
    }

    func testImageRoundTrip() {
        let html = "<p><img src=\"\(Self.pngURL)\"></p>"
        let parsed = blocks(html)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].runs.first?.image?.mime, .png)
        XCTAssertEqual(parsed[0].runs.first?.image?.data.count, 70)
        let written = roundTrip(html)
        XCTAssertEqual(written, html)
    }

    func testImageWithAltText() {
        let html = "<p>vor <img src=\"\(Self.pngURL)\" alt=\"Bild\"> nach</p>"
        let parsed = blocks(html)
        XCTAssertEqual(parsed[0].runs.count, 3)
        XCTAssertEqual(parsed[0].runs[1].image?.alt, "Bild")
        XCTAssertEqual(text(html), "vor [Bild] nach")
        XCTAssertEqual(roundTrip(html), html)
    }

    func testSignatureAndMentionMarkersSurvive() {
        let html = "<p>Text</p><div class=\"co-signature\"><p>Viele Grüße</p></div>"
        let document = RichHTML.parse(html)
        XCTAssertTrue(document.hasSignature)
        XCTAssertEqual(document.blocks.filter(\.isSignature).count, 1)
        XCTAssertEqual(document.withoutSignature.plainText, "Text")
        XCTAssertEqual(roundTrip(html), html)

        let mention = "<p><span class=\"co-mention\" data-email=\"ana@example.test\">@Ana</span> hallo</p>"
        let mentioned = blocks(mention)[0]
        XCTAssertEqual(mentioned.runs[0].mention, "ana@example.test")
        XCTAssertEqual(mentioned.runs[0].text, "@Ana")
        XCTAssertEqual(roundTrip(mention), mention)
    }

    // MARK: Sonderzeichen und Escaping

    func testSpecialCharactersAreEscaped() {
        let html = RichHTML.html(from: RichDocument(blocks: [
            RichBlock(runs: [RichRun(text: "1 < 2 & 3 > 2 \"zitiert\" 'apostroph'")]),
        ]))
        XCTAssertEqual(html, "<p>1 &lt; 2 &amp; 3 &gt; 2 \"zitiert\" 'apostroph'</p>")
        XCTAssertEqual(text(html), "1 < 2 & 3 > 2 \"zitiert\" 'apostroph'")
        XCTAssertEqual(roundTrip(html), html)
    }

    func testUmlautsAndEmojiSurvive() {
        let content = "Grüße aus Köln — 🎉 日本語"
        let html = RichHTML.html(from: RichDocument(blocks: [RichBlock(runs: [RichRun(text: content)])]))
        XCTAssertEqual(text(html), content)
        XCTAssertEqual(RichHTML.parse(html).blocks[0].runs[0].text, content)
    }

    func testNonBreakingSpaceAndSoftBreak() {
        // U+00A0 must not be collapsed into a normal space inside the rich text.
        let html = RichHTML.html(from: RichDocument(blocks: [RichBlock(runs: [RichRun(text: "a\u{00A0}b")])]))
        XCTAssertEqual(html, "<p>a&nbsp;b</p>")
        XCTAssertEqual(RichHTML.parse(html).blocks[0].runs[0].text, "a\u{00A0}b")
        // …but the text part uses a normal space, as Tauri does.
        XCTAssertEqual(text(html), "a b")
        // A soft break is a `<br>` inside the paragraph, not a new block.
        let broken = RichHTML.html(from: RichDocument(blocks: [RichBlock(runs: [RichRun(text: "a\nb")])]))
        XCTAssertEqual(broken, "<p>a<br>b</p>")
        XCTAssertEqual(RichHTML.parse(broken).blocks.count, 1)
    }

    func testEntitiesAreDecodedOnce() {
        XCTAssertEqual(text("<p>&amp;amp;</p>"), "&amp;")
        XCTAssertEqual(text("<p>&lt;script&gt;</p>"), "<script>")
        XCTAssertEqual(text("<p>&#65;&#x42;&#x63;</p>"), "ABc")
        XCTAssertEqual(RichHTML.parse("<p>a&nbsp;b</p>").blocks[0].runs[0].text, "a\u{00A0}b")
        // An unknown entity stays as it was written.
        XCTAssertEqual(text("<p>&unknown;</p>"), "&unknown;")
        // A broken reference is literal text, not a crash.
        XCTAssertEqual(text("<p>&#</p>"), "&#")
        XCTAssertEqual(text("<p>&#x;</p>"), "&#x;")
    }

    func testControlCharactersAreDropped() {
        let parsed = RichHTML.parse("<p>a\u{0000}b\u{0007}c</p>")
        XCTAssertEqual(parsed.blocks[0].runs.map(\.text).joined(), "abc")
    }

    // MARK: Feindliche Eingabe

    func testScriptAndStyleAreDroppedWithTheirContent() {
        XCTAssertEqual(RichHTML.html(from: RichHTML.parse("<p>a</p><script>alert(1)</script>")), "<p>a</p>")
        XCTAssertEqual(RichHTML.parse("<style>p{color:red}</style><p>b</p>").blocks.count, 1)
        XCTAssertEqual(text("<p>a</p><script>alert(1)</script><p>b</p>"), "a\nb")
        XCTAssertEqual(text("<iframe src=\"https://x\"><p>innen</p></iframe>"), "")
        XCTAssertEqual(text("<svg><text>innen</text></svg>nach"), "nach")
        XCTAssertEqual(text("<noscript>nein</noscript>ja"), "ja")
        XCTAssertEqual(text("<title>t</title>X"), "X")
    }

    func testEventHandlersNeverSurvive() {
        let html = "<p onclick=\"alert(1)\" onmouseover=alert(2)>text</p>"
        let written = RichHTML.html(from: RichHTML.parse(html))
        XCTAssertEqual(written, "<p>text</p>")
        XCTAssertFalse(written.lowercased().contains("onclick"))
        XCTAssertFalse(written.lowercased().contains("alert"))
    }

    func testDangerousLinksAreRefused() {
        for href in [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            " javascript:alert(1)",
            "java\tscript:alert(1)",
            "java\nscript:alert(1)",
            "\u{0001}javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "vbscript:msgbox(1)",
            "file:///etc/passwd",
            // Entity-encoded scheme: decoded before the check, so also refused.
            "&#106;avascript:alert(1)",
        ] {
            let parsed = RichHTML.parse("<p><a href=\"\(href)\">Text</a></p>")
            XCTAssertNil(parsed.blocks.first?.runs.first?.link, "link survived: \(href)")
            let written = RichHTML.html(from: parsed)
            XCTAssertFalse(written.contains("<a "), "anchor survived: \(href)")
            XCTAssertEqual(parsed.blocks.first?.runs.first?.text, "Text")
        }
    }

    func testAllowedLinksPass() {
        XCTAssertNotNil(RichHTML.allowedLink("https://example.test/a?b=c&d=e#f"))
        XCTAssertNotNil(RichHTML.allowedLink("http://example.test"))
        XCTAssertNotNil(RichHTML.allowedLink("mailto:ana@example.test"))
        XCTAssertNotNil(RichHTML.allowedLink("tel:+49 123"))
        XCTAssertNil(RichHTML.allowedLink("https:"))
        XCTAssertNil(RichHTML.allowedLink(""))
        XCTAssertNil(RichHTML.allowedLink(String(repeating: "a", count: 3000) + ":x"))
    }

    func testLinkInputHelp() {
        XCTAssertEqual(RichHTML.linkTarget(fromInput: "example.test"), "https://example.test")
        XCTAssertEqual(RichHTML.linkTarget(fromInput: "https://example.test"), "https://example.test")
        XCTAssertEqual(RichHTML.linkTarget(fromInput: "ana@example.test"), "mailto:ana@example.test")
        XCTAssertNil(RichHTML.linkTarget(fromInput: "javascript:alert(1)"))
        XCTAssertNil(RichHTML.linkTarget(fromInput: "   "))
    }

    func testRemoteImageIsDropped() {
        // Only `data:` pictures are part of the subset; the alt text stays.
        let parsed = RichHTML.parse("<p><img src=\"https://tracker.test/p.gif\" alt=\"Bild\"></p>")
        XCTAssertEqual(parsed.blocks.first?.runs.first?.text, "Bild")
        XCTAssertNil(parsed.blocks.first?.runs.first?.image)
        // A picture without alt text leaves nothing behind (an empty paragraph
        // is all that remains, and that is empty).
        XCTAssertTrue(RichHTML.parse("<p><img src=\"https://tracker.test/p.gif\"></p>").isEmpty)
    }

    func testHostileImageSources() {
        for source in [
            "data:text/html;base64,PHNjcmlwdD4=",
            "data:image/png;base64,@@notbase64@@",
            "data:image/png;base64,",
            // Claims PNG, carries HTML.
            "data:image/png;base64," + Data("<script>".utf8).base64EncodedString(),
            "javascript:alert(1)",
            "file:///etc/passwd",
        ] {
            let parsed = RichHTML.parse("<p><img src=\"\(source)\"></p>")
            XCTAssertNil(parsed.blocks.first?.runs.first?.image, "image survived: \(source)")
        }
    }

    /// B1 aus dem Audit M2: `lowercased()` darf die Länge ändern (KELVIN SIGN
    /// U+212A → "k", ẞ → "ß", İ → "i̇"), und ein Index aus dem Originalstring
    /// traf dann hinter dem Ende des kleingeschriebenen Strings — ein harter
    /// Trap. Eine fremde Mail kann so einen `img src` schicken.
    func testImageHeaderWithCharactersThatChangeLengthWhenLowercased() {
        for filler in ["K", "ẞ", "İ"] {
            let source = String(repeating: filler, count: 24) + ",x"
            XCTAssertNil(RichImage.parse(dataURL: source), "survived: \(filler)")
        }
        // A comma in front of the growing character must not shift the header either.
        XCTAssertNil(RichImage.parse(dataURL: ",İİİİİİİİİİİİİİİİİİİİİİİİ"))

        // Through the reply path: the mail is quoted, the picture is dropped,
        // and the text around it survives.
        for filler in ["K", "ẞ", "İ"] {
            let hostile = "<p>vor <img src=\"\(String(repeating: filler, count: 24)),x\"> nach</p>"
            let quote = Quoting.replyHTML(bodyHTML: hostile, bodyText: nil,
                                          from: Address(name: "Ana", email: "ana@example.test"),
                                          date: Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertTrue(quote.contains("vor"), "text lost for \(filler)")
            XCTAssertFalse(quote.contains("<img"), "picture survived for \(filler)")
        }
    }

    func testOversizedImageIsDropped() {
        let big = Data(repeating: 0x89, count: RichLimits.maxImageBytes + 1)
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(big)
        let url = "data:image/png;base64," + data.base64EncodedString()
        XCTAssertNil(RichImage.parse(dataURL: url))
        XCTAssertNotNil(RichImage.parse(dataURL: url, limit: data.count))
    }

    func testAttributesWithOddQuotes() {
        // A double quote inside a single-quoted value must be escaped on output.
        let parsed = RichHTML.parse("<p><a href='https://x.test/?a=\"b\"'>T</a></p>")
        let link = parsed.blocks.first?.runs.first?.link
        XCTAssertEqual(link, "https://x.test/?a=\"b\"")
        let written = RichHTML.html(from: parsed)
        XCTAssertFalse(written.contains("a=\"b\""))       // escaped, so not a new attribute
        XCTAssertEqual(RichHTML.parse(written).blocks.first?.runs.first?.link, link)
        // Unquoted values are read too.
        XCTAssertEqual(RichHTML.parse("<p><a href=https://x.test>U</a></p>").blocks.first?.runs.first?.link,
                       "https://x.test")
    }

    func testSolelyBrokenMarkupDoesNotThrow() {
        for input in [
            "</p>", "<p", "<", "<<p>>", "<p>a</b>", "<b>offen", "<ul><li>a", "</ul></li>",
            "<!-- ohne Ende", "<!--><p>x</p>-->", "<![CDATA[x]]>y", "<?xml version=\"1.0\"?><p>z</p>",
            "<p attr='unclosed>text", "<a href=>leer</a>", "<img src>", "<p class=\"\">x</p>",
            "<div><div><div>tief", "<ul><li>a<ul><li>b",
        ] {
            // No crash, and the writer produces nothing that parses differently.
            _ = RichHTML.parse(input)
            _ = roundTrip(input)
        }
    }

    /// K1 aus dem Audit M2: die Grenze `maxHTMLBytes` zählt Bytes. `prefix` auf
    /// dem String zählt Zeichen und ließe 4-Byte-Zeichen mit der vierfachen
    /// Menge durch.
    func testLargeInputIsBoundedByBytesNotCharacters() {
        let big = String(repeating: "🙂", count: RichLimits.maxHTMLBytes / 4 + 1000)
        let parsed = RichHTML.parse(big)
        XCTAssertLessThanOrEqual(parsed.plainText.utf8.count, RichLimits.maxHTMLBytes)
    }

    /// K1: HTML-Namen sind unabhängig von der Schreibweise. `<B>` bleibt fett,
    /// `<SCRIPT>` fällt mit seinem Inhalt weg, statt als Text zu erscheinen.
    func testUppercaseTagsAreUnderstood() {
        let bold = RichHTML.parse("<P><B>fett</B></P>")
        XCTAssertEqual(bold.blocks.first?.runs.first?.text, "fett")
        XCTAssertEqual(bold.blocks.first?.runs.first?.bold, true)
        XCTAssertEqual(RichHTML.plainText(html: "<P>a</P>"), "a")
        XCTAssertTrue(RichHTML.parse("<SCRIPT>alert(1)</SCRIPT>").isEmpty, "kein Skripttext als Inhalt")
        XCTAssertTrue(RichHTML.parse("<STYLE>p{}</STYLE>").isEmpty)
    }

    func testDeepNestingIsCutOffInsteadOfWalked() {
        let deep = String(repeating: "<div>", count: RichLimits.maxNestingDepth * 40) + "tief"
        let parsed = RichHTML.parse(deep)
        XCTAssertTrue(parsed.blocks.isEmpty, "content below the depth limit must not appear")
        let inline = String(repeating: "<b><i>", count: 5000) + "x"
        _ = RichHTML.parse(inline)      // no recursion, no crash
    }

    func testManyTokensAreBounded() {
        let input = String(repeating: "<p>a</p>", count: RichLimits.maxTokens + 1000)
        let parsed = RichHTML.parse(input)
        XCTAssertLessThanOrEqual(parsed.blocks.count, RichLimits.maxBlocks)
        XCTAssertLessThanOrEqual(parsed.blocks.count, RichLimits.maxTokens)
    }

    func testVeryLargeInputIsTruncatedNotRejected() {
        let input = "<p>" + String(repeating: "a", count: RichLimits.maxHTMLBytes + 1000)
        let parsed = RichHTML.parse(input)
        XCTAssertFalse(parsed.isEmpty)
        XCTAssertLessThanOrEqual(parsed.blocks.first?.text.count ?? 0, RichLimits.maxTextCharacters)
    }

    // MARK: Text-Teil

    func testPlainTextMatchesTaurisShape() {
        XCTAssertEqual(text("<p>a</p><p>b</p>"), "a\nb")
        XCTAssertEqual(text("<ul><li>a</li><li>b</li></ul>"), "- a\n- b")
        XCTAssertEqual(text("<blockquote><p>zitat</p></blockquote>"), "> zitat")
        XCTAssertEqual(text("<p>a<a href=\"https://x.test\">link</a></p>"), "alink")
        XCTAssertEqual(text("<p>a<br>b</p>"), "a\nb")
        XCTAssertEqual(text("<p>a</p><p></p><p></p><p>b</p>"), "a\n\nb")
    }

    func testPlainTextToHTMLRoundTrip() {
        let html = RichHTML.html(fromPlainText: "Zeile 1\nZeile 2")
        XCTAssertEqual(html, "<p>Zeile 1</p><p>Zeile 2</p>")
        XCTAssertEqual(text(html), "Zeile 1\nZeile 2")
        XCTAssertEqual(RichHTML.html(fromPlainText: ""), "")
        XCTAssertEqual(text(RichHTML.html(fromPlainText: "a < b & c")), "a < b & c")
    }

    func testIsEmpty() {
        XCTAssertTrue(RichHTML.isEmpty(html: ""))
        XCTAssertTrue(RichHTML.isEmpty(html: "<p></p>"))
        XCTAssertTrue(RichHTML.isEmpty(html: "<p>  </p>"))
        XCTAssertTrue(RichHTML.isEmpty(html: "<script>x</script>"))
        XCTAssertFalse(RichHTML.isEmpty(html: "<p>a</p>"))
        XCTAssertFalse(RichHTML.isEmpty(html: "<p><img src=\"\(Self.pngURL)\"></p>"))
    }

    // MARK: Signatur

    func testSettingSignatureAppendsAndReplaces() {
        let signature = "<p>Viele Grüße<br>Ana</p>"
        let once = RichHTML.settingSignature(html: "<p>Text</p>", signatureHTML: signature)
        XCTAssertTrue(once.contains("class=\"co-signature\""))
        XCTAssertTrue(RichHTML.hasSignature(html: once))
        XCTAssertEqual(RichHTML.contentPlainText(html: once), "Text")
        // Setting the same signature again changes nothing.
        XCTAssertEqual(RichHTML.settingSignature(html: once, signatureHTML: signature), once)
        // A new signature replaces the old block.
        let other = RichHTML.settingSignature(html: once, signatureHTML: "<p>Anders</p>")
        XCTAssertEqual(RichHTML.contentPlainText(html: other), "Text")
        XCTAssertTrue(other.contains("Anders"))
        XCTAssertFalse(other.contains("Ana"))
        // An empty signature removes the block.
        let removed = RichHTML.settingSignature(html: once, signatureHTML: "")
        XCTAssertFalse(RichHTML.hasSignature(html: removed))
        XCTAssertEqual(RichHTML.plainText(html: removed), "Text")
    }

    func testSettingSignatureOnEmptyBodyDoesNotAddBlankLines() {
        let html = RichHTML.settingSignature(html: "", signatureHTML: "<p>Gruß</p>")
        XCTAssertEqual(html, "<div class=\"co-signature\"><p>Gruß</p></div>")
    }

    func testStrippingSignatureKeepsTheText() {
        let html = "<p>Text</p><div class=\"co-signature\"><p>Gruß</p></div>"
        let stripped = RichHTML.strippingSignature(html: html)
        XCTAssertEqual(RichHTML.plainText(html: stripped), "Text")
        XCTAssertFalse(stripped.contains("co-signature"))
        // Without a signature nothing changes.
        XCTAssertEqual(RichHTML.strippingSignature(html: "<p>x</p>"), "<p>x</p>")
    }

    func testAppendingKeepsTheSignatureAtTheBottom() {
        // A snippet lands in the body's own text; the signature stays below it.
        let body = RichHTML.settingSignature(html: "<p>Antwort</p>", signatureHTML: "<p>Gruß</p>")
        let result = RichHTML.appending(html: body, html: "<p>Gerne.</p>")
        let document = RichHTML.parse(result)
        XCTAssertEqual(document.blocks.filter(\.isSignature).count, 1)
        XCTAssertTrue(document.blocks.last?.isSignature ?? false, "signature must stay at the bottom")
        XCTAssertEqual(RichHTML.contentPlainText(html: result), "Antwort\n\nGerne.")
        // Appending nothing changes nothing.
        XCTAssertEqual(RichHTML.appending(html: body, html: ""), body)
    }

    func testWriterTrimsWhatTheParserTrims() {
        // A trailing space or soft break at the end of a block is collapsed by
        // HTML; writing it out again made the body change on every save (the
        // M2.6 walkthrough caught it after a mention chip).
        XCTAssertEqual(roundTrip("<p>a<br></p>"), "<p>a</p>")
        XCTAssertEqual(roundTrip("<p>a </p>"), "<p>a</p>")
        XCTAssertEqual(roundTrip("<p> a</p>"), "<p>a</p>")
        XCTAssertEqual(roundTrip("<ul><li>a </li></ul>"), "<ul><li>a</li></ul>")
        // …but a space inside stays where it belongs.
        XCTAssertEqual(roundTrip("<p>a b</p>"), "<p>a b</p>")
        XCTAssertEqual(roundTrip("<p>a <b>b</b></p>"), "<p>a<b> b</b></p>")
    }

    func testSettingQuotePutsTheOriginalBelowTextAndSignature() {
        let body = RichHTML.settingSignature(html: "<p>Antwort</p>", signatureHTML: "<p>Gruß</p>")
        let result = RichHTML.settingQuote(html: body, quoteHTML: "<blockquote><p>Original</p></blockquote>")
        let document = RichHTML.parse(result)
        // Mail order: text, signature, quote.
        XCTAssertEqual(document.blocks.filter(\.isSignature).count, 1)
        XCTAssertEqual(document.blocks.filter { $0.quoteDepth == 1 }.map(\.text), ["Original"])
        XCTAssertEqual(RichHTML.plainText(html: result), "Antwort\n\nGruß\n\n> Original")
        XCTAssertEqual(RichHTML.aiPlainText(html: result), "Antwort")
        // A second call does not stack two quotes.
        let again = RichHTML.settingQuote(html: result, quoteHTML: "<blockquote><p>Original</p></blockquote>")
        XCTAssertEqual(RichHTML.parse(again).blocks.filter { $0.quoteDepth == 1 }.count, 1)
    }

    func testPrependingPutsTheQuoteAboveTheText() {
        let body = RichHTML.settingSignature(html: "<p>Antwort</p>", signatureHTML: "<p>Gruß</p>")
        let result = RichHTML.prepending(html: body, html: "<blockquote><p>Zitat</p></blockquote>")
        XCTAssertEqual(RichHTML.plainText(html: result), "> Zitat\n\nAntwort\n\nGruß")
    }

}

/// The image handling in isolation: the type checks the parser relies on.
final class RichImageTests: XCTestCase {
    func testSniffAndMagic() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(contentsOf: [0, 0, 0, 0])
        XCTAssertEqual(RichMime.sniff(png), .png)
        XCTAssertEqual(RichMime.sniff(Data([0xFF, 0xD8, 0xFF, 0x00])), .jpeg)
        XCTAssertEqual(RichMime.sniff(Data("GIF89a".utf8)), .gif)
        XCTAssertNil(RichMime.sniff(Data("hello".utf8)))
        XCTAssertEqual(RichMime.parse("image/jpg"), .jpeg)
        XCTAssertNil(RichMime.parse("image/svg+xml"))
    }

    func testParseRejectsWrongTypeAndKeepsData() {
        let image = RichImage.parse(dataURL: RichHTMLTests.pngURL, alt: "x")
        XCTAssertEqual(image?.mime, .png)
        XCTAssertEqual(image?.alt, "x")
        XCTAssertNotNil(image)
        let rebuilt = image.map { "data:\($0.mime.rawValue);base64,\($0.data.base64EncodedString())" }
        XCTAssertEqual(rebuilt, RichHTMLTests.pngURL)
    }
}
