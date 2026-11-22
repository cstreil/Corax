import Foundation

// MARK: - HTML-Teilmenge

/// The composer's HTML subset (M2.6): reading and writing the rich body.
///
/// Written by hand instead of `NSAttributedString.DocumentType.html` because
/// that exporter emits a whole CSS document, and mail wants one small body.
/// Both directions only know this subset:
///
/// ```
/// p  br  b/strong  i/em  u  s/strike/del  a[href]  ul  ol  li  blockquote
/// img[src=data:image/…;base64,…][alt]  div.co-signature  span.co-mention[data-email]
/// ```
///
/// The last two are markers Tauri writes itself (`wrapSignature`, the `@`
/// chip). Keeping them means a draft moves between the Tauri app and the native
/// app without losing its signature or its mention chips.
///
/// Everything else is either transparent (an unknown element keeps its text),
/// flattened to a block boundary (headings, tables, …) or dropped with its
/// content (`script`, `style`, `iframe`, …). Attributes other than `href`,
/// `src`, `alt`, `class` and `data-email` are never read, so `on*=` handlers
/// cannot survive a round trip; `javascript:`/`data:` links are refused.
public enum RichHTML {

    // MARK: Einstiege

    /// Parses stored HTML (draft, signature, snippet, pasted content) into the
    /// block model. Never throws, never recurses: hostile input is dropped, not
    /// walked.
    public static func parse(_ html: String) -> RichDocument {
        guard !html.isEmpty else { return RichDocument() }
        // The limit is bytes (`maxHTMLBytes`), so cut bytes: `prefix` on the
        // string counts characters and would let 4-byte scalars through at four
        // times the size (K1 aus dem Audit M2).
        let bounded = html.utf8.count > RichLimits.maxHTMLBytes
            ? String(decoding: html.utf8.prefix(RichLimits.maxHTMLBytes), as: UTF8.self)
            : html
        var parser = Parser(bounded)
        return parser.run()
    }

    /// Writes the block model as the subset above. The only place that knows
    /// how a mail body is serialised, so the output cannot carry markup the
    /// editor does not have.
    public static func html(from document: RichDocument) -> String {
        var writer = Writer()
        for block in document.blocks { writer.write(block) }
        writer.finish()
        return writer.parts.joined()
    }

    /// The `text/plain` part that goes out next to the HTML, built the way
    /// Tauri's `htmlToText` builds it.
    public static func plainText(html: String) -> String {
        guard !html.isEmpty else { return "" }
        return parse(html).plainText
    }

    /// Plain text to HTML: one paragraph per line. Tauri uses `<br>` only; a
    /// paragraph per line reads the same and keeps the block model honest.
    public static func html(fromPlainText text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return "" }
        let document = RichDocument(blocks: normalized.components(separatedBy: "\n").map { line in
            RichBlock(runs: line.isEmpty ? [] : [RichRun(text: line)])
        })
        return html(from: document)
    }

    public static func isEmpty(html: String) -> Bool {
        parse(html).isEmpty
    }

    // MARK: Signatur, Zitat, Inhalt

    /// The three parts a composed body has: what the user wrote, the signature
    /// block, and the quoted original. Keeping them apart means a new AI text
    /// never eats the signature or the quote (M2.6).
    public struct Parts: Sendable {
        public var content: [RichBlock]
        public var signature: [RichBlock]
        public var quote: [RichBlock]
        public var isEmpty: Bool { content.isEmpty && signature.isEmpty && quote.isEmpty }
    }

    public static func split(_ html: String) -> Parts {
        var parts = Parts(content: [], signature: [], quote: [])
        for block in parse(html).blocks {
            if block.isSignature {
                parts.signature.append(block)
            } else if block.quoteDepth > 0 {
                parts.quote.append(block)
            } else {
                parts.content.append(block)
            }
        }
        return parts
    }

    /// Writes the parts in mail order — text, signature, quote — with one blank
    /// line between them, as Tauri's `<br><br>` separators do.
    public static func compose(_ parts: Parts) -> String {
        compose(parts, blankLinesBeforeSignature: 1, blankLinesBeforeQuote: 1, keepContentEdge: false)
    }

    /// `blankLinesBeforeQuote` is 2 for a fresh reply: Tauri writes
    /// `body + "<br><br>" + quote`, so the caret line is followed by two blank
    /// lines and the original is clearly apart from the answer (M2.8a).
    /// `keepContentEdge` keeps a leading empty paragraph that the trimming
    /// below would otherwise fold away — that is the paragraph the caret sits in.
    static func compose(_ parts: Parts, blankLinesBeforeSignature: Int, blankLinesBeforeQuote: Int,
                        keepContentEdge: Bool) -> String {
        var blocks: [RichBlock] = []
        func add(_ group: [RichBlock], blanks: Int, keepEdges: Bool = false) {
            var group = group
            if !keepEdges {
                while let last = group.last, last.isEmpty, !last.hasImages { group.removeLast() }
                while let first = group.first, first.isEmpty, !first.hasImages { group.removeFirst() }
            }
            guard !group.isEmpty else { return }
            if !blocks.isEmpty {
                for _ in 0..<max(0, blanks) { blocks.append(RichBlock()) }
            }
            blocks += group
        }
        add(parts.content, blanks: 0, keepEdges: keepContentEdge)
        add(parts.signature, blanks: blankLinesBeforeSignature)
        add(parts.quote, blanks: blankLinesBeforeQuote)
        return html(from: RichDocument(blocks: blocks))
    }

    /// A reply ready for typing (M2.8a): the caret gets its own empty
    /// paragraph, two blank lines follow, then the signature and the quote.
    ///
    /// Tauri writes `body + "<br><br>" + quoteToHtml(quote)`, and `quoteToHtml`
    /// is `div(attribution) + blockquote(original)`. Building the tail from the
    /// parts directly — instead of re-splitting a composed body — keeps the
    /// attribution out of the blockquote; `settingQuote`'s promotion had pulled
    /// it in, so the caret stood on the original's first line.
    public static func replyFooter(quoteHTML: String, signatureHTML: String) -> String {
        footer(tail: parse(quoteHTML).blocks.filter { !$0.isSignature }, signatureHTML: signatureHTML)
    }

    /// A forward ready for typing: same opening, but the forwarded block keeps
    /// its own shape — Tauri's `forwardBlock` has no blockquote.
    public static func forwardFooter(forwardHTML: String, signatureHTML: String) -> String {
        footer(tail: parse(forwardHTML).blocks, signatureHTML: signatureHTML)
    }

    private static func footer(tail: [RichBlock], signatureHTML: String) -> String {
        var blocks = [RichBlock(), RichBlock(), RichBlock()]   // caret line + two blank lines
        if !signatureHTML.isEmpty {
            blocks += signatureDocument(signatureHTML).blocks
            // One blank line between the signature and the tail: the wire text
            // reads `Viele Grüße\n\n> Original`, as Tauri's `\n\n` separator.
            blocks.append(RichBlock())
        }
        blocks += tail
        return html(from: RichDocument(blocks: blocks))
    }

    /// A signature's HTML as document blocks, every block marked as signature.
    public static func signatureDocument(_ html: String) -> RichDocument {
        var document = parse(html)
        for index in document.blocks.indices { document.blocks[index].isSignature = true }
        return document
    }

    public static func hasSignature(html: String) -> Bool {
        parse(html).hasSignature
    }

    /// The body without its signature block (what the AI is shown).
    public static func strippingSignature(html: String) -> String {
        let parts = split(html)
        guard parse(html).hasSignature else { return html }
        return compose(Parts(content: parts.content, signature: [], quote: parts.quote))
    }

    /// The body's text without the signature (Tauri's `htmlToText(stripSignature(…))`).
    public static func contentPlainText(html: String) -> String {
        parse(html).withoutSignature.plainText
    }

    /// What the AI is shown and what counts as "the user wrote something": the
    /// text without signature and without the quoted original, because the model
    /// must not rewrite the mail it is answering and a reply that only carries
    /// the quote is an empty draft.
    public static func aiPlainText(html: String) -> String {
        RichDocument(blocks: split(html).content).plainText
    }

    public static func hasImages(html: String) -> Bool {
        parse(html).blocks.contains { block in block.runs.contains { $0.image != nil } }
    }

    /// The quoted original as a blockquote (Tauri's `quoteToHtml` /
    /// `selectionQuoteHtml`): one quote level deeper than the source.
    public static func quoted(_ document: RichDocument) -> RichDocument {
        var quoted = document
        for index in quoted.blocks.indices {
            quoted.blocks[index].quoteDepth = min(max(quoted.blocks[index].quoteDepth + 1, 1),
                                                  RichLimits.maxQuoteDepth)
            quoted.blocks[index].isSignature = false
        }
        return quoted
    }

    /// Puts `signatureHTML` in as the body's signature: an existing block is
    /// replaced, an empty one removes it.
    public static func settingSignature(html: String, signatureHTML: String) -> String {
        var parts = split(html)
        parts.signature = signatureHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : signatureDocument(signatureHTML).blocks
        return compose(parts)
    }

    /// Puts the quoted original at the bottom of a fresh reply.
    public static func settingQuote(html: String, quoteHTML: String) -> String {
        var parts = split(html)
        var quote = parse(quoteHTML).blocks.filter { !$0.isSignature }
        // A quote that already carries blockquote markup keeps its shape: Tauri's
        // reply writes the attribution line as its own paragraph *above* the
        // quote (`quoteToHtml`). Promoting every paragraph here folded that line
        // into the blockquote, so the caret's line started the original text
        // (Live-Test 1, M2.8a). Input without any quote markup is quoted whole.
        if !quote.isEmpty, !quote.contains(where: { $0.quoteDepth > 0 }) {
            for index in quote.indices { quote[index].quoteDepth = 1 }
        }
        parts.quote = quote
        return compose(parts)
    }

    /// Appends `html` to the body's own text (a snippet at the end), keeping
    /// signature and quote where they are.
    public static func appending(html body: String, html addition: String) -> String {
        let extra = parse(addition).blocks.filter { !$0.isSignature && $0.quoteDepth == 0 }
        guard !extra.isEmpty else { return body }
        var parts = split(body)
        parts.content += extra
        return compose(parts)
    }

    /// Puts `addition` above the body's own text (a quote at the caret in a
    /// fresh reply), keeping the signature at the bottom.
    public static func prepending(html body: String, html addition: String) -> String {
        let extra = parse(addition).blocks.filter { !$0.isSignature }
        guard !extra.isEmpty else { return body }
        var parts = split(body)
        parts.content = extra + [RichBlock()] + parts.content
        return compose(parts)
    }

    /// Replaces the body's own text (AI result, proofread, quick reply) and
    /// keeps the signature and the quoted original.
    public static func replacingContent(html: String, withText text: String) -> String {
        var parts = split(html)
        parts.content = parse(RichHTML.html(fromPlainText: text)).blocks
        return compose(parts)
    }

    // MARK: Links

    /// The schemes a link in a mail may have. Anything else (`javascript:`,
    /// `data:`, `file:`, `vbscript:`) is not a link.
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// Returns `raw` when it is a link the composer may store, else nil.
    ///
    /// The scheme is read from a copy with every ASCII control character and
    /// space removed, because `java\nscript:` and ` javascript:` are the
    /// classic ways past a naive check; the returned value is the cleaned
    /// original, so nothing hidden survives.
    public static func allowedLink(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= RichLimits.maxURLCharacters else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let compact = String(trimmed.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })
        guard let colon = compact.firstIndex(of: ":") else { return nil }
        let scheme = compact[..<colon].lowercased()
        guard allowedSchemes.contains(scheme) else { return nil }
        // A URL needs something after the scheme ("https:" alone is no target).
        let rest = compact[compact.index(after: colon)...]
        guard !rest.isEmpty else { return nil }
        return trimmed
    }

    /// What the link popover accepts: a bare host becomes `https://…`, a scheme
    /// keeps it, and everything unsafe is refused.
    public static func linkTarget(fromInput raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            return allowedLink(trimmed)
        }
        if trimmed.contains("@"), !trimmed.contains(" ") {
            return allowedLink("mailto:" + trimmed)
        }
        return allowedLink("https://" + trimmed)
    }

    // MARK: Zeichen

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[rest.index(after: amp)...]
            if let (decoded, length) = entity(in: tail) {
                out += decoded
                rest = tail.dropFirst(length)
            } else {
                out.append("&")
                rest = tail
            }
        }
        out += rest
        return out
    }

    /// One `&…;` at the start of `tail`: the character and how many characters
    /// it used (nil when this is not an entity we know).
    private static func entity(in tail: Substring) -> (String, Int)? {
        let named: [String: String] = [
            "amp;": "&", "lt;": "<", "gt;": ">", "quot;": "\"", "apos;": "'", "nbsp;": "\u{00A0}",
        ]
        for (name, value) in named where tail.hasPrefix(name) {
            return (value, name.count)
        }
        if tail.hasPrefix("#") {
            let body = tail.dropFirst()
            let hex = body.first == "x" || body.first == "X"
            let digits = hex ? body.dropFirst() : body
            var value = 0
            var used = 0
            for scalar in digits.unicodeScalars {
                let digit: Int
                switch scalar {
                case "0"..."9": digit = Int(scalar.value - 48)
                case "a"..."f" where hex: digit = Int(scalar.value - 87)
                case "A"..."F" where hex: digit = Int(scalar.value - 55)
                default: digit = -1
                }
                if digit < 0 { break }
                value = value * (hex ? 16 : 10) + digit
                used += 1
                if used > 8 { return nil }
            }
            guard used > 0 else { return nil }
            let afterDigits = digits.dropFirst(used)
            guard afterDigits.first == ";" else { return nil }
            let length = used + (hex ? 3 : 2)   // "#" ["x"] digits ";"
            guard let scalar = Unicode.Scalar(value), value != 0,
                  !(0xD800...0xDFFF).contains(value) else { return ("\u{FFFD}", length) }
            return (String(scalar), length)
        }
        return nil
    }

    /// Escapes text for the body. `\n` becomes `<br>` (a soft break inside its
    /// block), `U+00A0` becomes `&nbsp;` so no client collapses it.
    static func escapeText(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count + 8)
        for character in text.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\n": out += "<br>"
            case "\u{00A0}": out += "&nbsp;"
            case "\u{2028}": out += "<br>"
            default:
                if character.value < 0x20 && character != "\t" { continue }
                out.unicodeScalars.append(character)
            }
        }
        return out
    }

    static func escapeAttribute(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count + 8)
        for character in text.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:
                if character.value < 0x20 && character != "\t" { continue }
                out.unicodeScalars.append(character)
            }
        }
        return out
    }
}

// MARK: - Tokenizer

private enum RawToken {
    case text(String)
    case start(name: String, attributes: [(String, String)], selfClosing: Bool)
    case end(String)
    /// A comment, doctype or processing instruction: nothing to build.
    case skipped
}

private struct Tokenizer {
    let scalars: String.UnicodeScalarView
    var index: String.Index

    init(_ html: String) {
        scalars = html.unicodeScalars
        index = scalars.startIndex
    }

    var isAtEnd: Bool { index >= scalars.endIndex }

    mutating func next() -> RawToken? {
        while !isAtEnd {
            if scalars[index] == "<" {
                if let token = markup() { return token }
                continue
            }
            let start = index
            while !isAtEnd, scalars[index] != "<" { index = scalars.index(after: index) }
            return .text(String(scalars[start..<index]))
        }
        return nil
    }

    /// Reads one `<…>` construct. Returns nil when the construct was consumed
    /// without producing anything worth handling (a stray "<" as text).
    private mutating func markup() -> RawToken? {
        let after = scalars.index(after: index)
        guard after < scalars.endIndex else {
            index = scalars.endIndex
            return .text("<")
        }
        let first = scalars[after]
        if first == "!" {
            // `<!--…-->`, `<!DOCTYPE …>`, `<![CDATA[…]]>`
            if matches("!--", from: after) {
                index = scalars.index(after, offsetBy: 3)
                while !isAtEnd, !matches("-->", from: index) {
                    index = scalars.index(after: index)
                }
                if !isAtEnd { index = scalars.index(index, offsetBy: 3) }
                return .skipped
            }
            skipUntilGreaterThan()
            return .skipped
        }
        if first == "?" {
            skipUntilGreaterThan()
            return .skipped
        }
        if first == "/" {
            index = scalars.index(after: after)
            let name = readName()
            skipUntilGreaterThan()
            return name.isEmpty ? .skipped : .end(name.lowercased())
        }
        guard isNameStart(first) else {
            index = after
            return .text("<")
        }
        index = after
        let name = readName()
        var attributes: [(String, String)] = []
        var selfClosing = false
        while !isAtEnd {
            skipWhitespace()
            guard !isAtEnd else { break }
            let character = scalars[index]
            if character == ">" {
                index = scalars.index(after: index)
                break
            }
            if character == "/" {
                index = scalars.index(after: index)
                if !isAtEnd, scalars[index] == ">" {
                    selfClosing = true
                    index = scalars.index(after: index)
                    break
                }
                continue
            }
            guard isNameStart(character) else {
                index = scalars.index(after: index)
                continue
            }
            let attributeName = readName().lowercased()
            skipWhitespace()
            var value = ""
            if !isAtEnd, scalars[index] == "=" {
                index = scalars.index(after: index)
                skipWhitespace()
                value = readAttributeValue()
            }
            // A tag with a thousand attributes is not a mail body.
            if attributes.count < 64, !attributeName.isEmpty,
               !attributes.contains(where: { $0.0 == attributeName }) {
                attributes.append((attributeName, value))
            }
        }
        // HTML tag names are case-insensitive: `<B>` from a foreign signature is
        // bold, `<SCRIPT>` from a draft is dropped (K1). End tags are already
        // lowercased above.
        return .start(name: name.lowercased(), attributes: attributes, selfClosing: selfClosing)
    }

    private mutating func readAttributeValue() -> String {
        guard !isAtEnd else { return "" }
        var start = index
        if scalars[index] == "\"" || scalars[index] == "'" {
            let quote = scalars[index]
            index = scalars.index(after: index)
            start = index
            while !isAtEnd, scalars[index] != quote { index = scalars.index(after: index) }
            let value = String(scalars[start..<index])
            if !isAtEnd { index = scalars.index(after: index) }
            return value
        }
        while !isAtEnd {
            let character = scalars[index]
            if character == ">" || character == " " || character == "\t" || character == "\n"
                || character == "\r" || character == "\u{0C}" {
                break
            }
            index = scalars.index(after: index)
        }
        return String(scalars[start..<index])
    }

    /// True when `literal` starts at `start` (ASCII comparison on scalars).
    private func matches(_ literal: String, from start: String.Index) -> Bool {
        var cursor = start
        for scalar in literal.unicodeScalars {
            guard cursor < scalars.endIndex, scalars[cursor] == scalar else { return false }
            cursor = scalars.index(after: cursor)
        }
        return true
    }

    private mutating func readName() -> String {
        let start = index
        while !isAtEnd, isNameCharacter(scalars[index]) { index = scalars.index(after: index) }
        return String(scalars[start..<index])
    }

    private mutating func skipWhitespace() {
        while !isAtEnd {
            let character = scalars[index]
            guard character == " " || character == "\t" || character == "\n" || character == "\r"
                    || character == "\u{0C}" else { return }
            index = scalars.index(after: index)
        }
    }

    private mutating func skipUntilGreaterThan() {
        while !isAtEnd, scalars[index] != ">" { index = scalars.index(after: index) }
        if !isAtEnd { index = scalars.index(after: index) }
    }

    private func isNameStart(_ character: Unicode.Scalar) -> Bool {
        (character.value >= 97 && character.value <= 122) || (character.value >= 65 && character.value <= 90)
    }

    private func isNameCharacter(_ character: Unicode.Scalar) -> Bool {
        isNameStart(character) || (character.value >= 48 && character.value <= 57)
            || character == "-" || character == "_" || character == ":"
    }
}

// MARK: - Parser

/// Builds the block model from the token stream. Iterative on purpose: the
/// element stack is bounded by `RichLimits.maxNestingDepth`, and input that
/// goes deeper is cut off instead of walked.
private struct Parser {
    private let tokens: Tokenizer
    private var blocks: [RichBlock] = []
    private var runs: [RichRun] = []

    private enum Frame: Equatable {
        case bold, italic, underline, strike
        case link, mention
        case quote
        case list(RichListKind)
        case item
        case signature
        case block
        case transparent
    }

    private var stack: [Frame] = []
    private var bold = 0, italic = 0, underline = 0, strike = 0
    private var link: String?
    private var mention: String?
    private var quote = 0
    private var signature = 0
    private var lists: [RichListKind] = []
    /// Open block-level elements; `true` once one of them received content.
    private var openBlocks: [Bool] = []
    private var preformatted = 0
    private var blockKind: RichBlock.Kind = .paragraph
    private var textCharacters = 0
    private var tokenCount = 0
    private var spacePending = false
    /// Set when the element stack hit its limit; stops the parse.
    private var overflowing = false

    /// Elements whose content is not text: skipped whole.
    private static let dropped: Set<String> = [
        "script", "style", "head", "title", "noscript", "iframe", "object", "embed", "template",
        "svg", "math", "form", "select", "textarea", "video", "audio", "canvas", "applet", "map",
    ]
    private var dropTag: String?
    private var dropDepth = 0

    private static let void: Set<String> = [
        "br", "img", "hr", "wbr", "meta", "link", "base", "col", "embed", "source", "track",
        "input", "area", "param", "frame",
    ]
    private static let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "section", "article", "aside",
        "header", "footer", "main", "nav", "figure", "figcaption", "address", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "fieldset", "center", "body", "html",
        "caption", "summary", "details", "legend", "hgroup",
    ]
    private static let inlineTransparent: Set<String> = [
        "span", "font", "code", "kbd", "samp", "var", "small", "big", "mark", "sup", "sub", "abbr",
        "cite", "q", "time", "bdi", "bdo", "data", "ins", "ruby", "rt", "rp", "label", "article",
    ]

    init(_ html: String) {
        tokens = Tokenizer(html)
    }

    mutating func run() -> RichDocument {
        var tokenizer = tokens
        while tokenCount < RichLimits.maxTokens, !overflowing, let token = tokenizer.next() {
            tokenCount += 1
            switch token {
            case .text(let text):
                if dropTag == nil { appendText(text) }
            case .start(let name, let attributes, let selfClosing):
                start(name: name, attributes: attributes, selfClosing: selfClosing)
            case .end(let name):
                end(name: name)
            case .skipped:
                break
            }
            if textCharacters > RichLimits.maxTextCharacters { break }
        }
        closeAllBlocks()
        if blocks.count > RichLimits.maxBlocks {
            blocks.removeLast(blocks.count - RichLimits.maxBlocks)
        }
        return RichDocument(blocks: blocks)
    }

    // MARK: Struktur

    private mutating func start(name: String, attributes: [(String, String)], selfClosing: Bool) {
        if let drop = dropTag {
            if name == drop, !selfClosing { dropDepth += 1 }
            return
        }
        if Self.dropped.contains(name) {
            if !selfClosing {
                dropTag = name
                dropDepth = 1
            }
            return
        }
        switch name {
        case "br":
            appendBreak()
        case "hr":
            flushBlock(); markEmptyBlock()
        case "img":
            appendImage(attributes: attributes)
        default:
            if Self.void.contains(name) { return }
            if name == "ul" || name == "ol" {
                flushBlock()
                let kind: RichListKind = name == "ol" ? .ordered : .bullet
                guard lists.count < RichLimits.maxListDepth else { return }
                lists.append(kind)
                push(.list(kind))
                return
            }
            if name == "li" {
                flushBlock()
                blockKind = lists.isEmpty ? .paragraph : .listItem(lists[lists.count - 1], depth: lists.count)
                push(.item)
                return
            }
            if name == "blockquote" {
                flushBlock()
                quote = min(quote + 1, RichLimits.maxQuoteDepth)
                push(.quote)
                return
            }
            if name == "div", classTokens(attributes).contains("co-signature") {
                flushBlock()
                signature += 1
                push(.signature)
                return
            }
            if name == "span", classTokens(attributes).contains("co-mention") {
                let email = attribute("data-email", attributes).map(RichHTML.decodeEntities) ?? ""
                mention = email
                push(.mention)
                return
            }
            if Self.blockElements.contains(name) {
                flushBlock()
                openBlocks.append(false)
                if name == "pre" { preformatted += 1 }
                push(.block)
                return
            }
            if name == "a" {
                let href = attribute("href", attributes).map(RichHTML.decodeEntities).flatMap(RichHTML.allowedLink)
                link = href
                push(href == nil ? .transparent : .link)
                return
            }
            if name == "b" || name == "strong" {
                bold += 1; push(.bold); return
            }
            if name == "i" || name == "em" {
                italic += 1; push(.italic); return
            }
            if name == "u" {
                underline += 1; push(.underline); return
            }
            if name == "s" || name == "strike" || name == "del" {
                strike += 1; push(.strike); return
            }
            push(.transparent)
        }
    }

    private mutating func end(name: String) {
        if let drop = dropTag {
            if name == drop {
                dropDepth -= 1
                if dropDepth <= 0 {
                    dropTag = nil
                    dropDepth = 0
                }
            }
            return
        }
        if Self.dropped.contains(name) { return }
        switch name {
        case "ul", "ol":
            flushBlock()
            guard let index = stack.lastIndex(where: { frame in
                if case .list = frame { return true }
                return false
            }) else { return }
            pop(until: index)
            if !lists.isEmpty { lists.removeLast() }
        case "li":
            flushBlock()
            if let index = stack.lastIndex(of: .item) { pop(until: index) }
            blockKind = .paragraph
        case "blockquote":
            flushBlock()
            if let index = stack.lastIndex(of: .quote) { pop(until: index) }
            quote = max(0, quote - 1)
        case "a":
            popNearest(.link, .transparent)
        case "span":
            popNearest(.mention, .transparent)
        case "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "section", "article",
             "aside", "header", "footer", "main", "nav", "figure", "figcaption", "address", "dl",
             "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "fieldset", "center",
             "body", "html", "caption", "summary", "details", "legend", "hgroup":
            closeBlockElement(named: name)
        case "b", "strong", "i", "em", "u", "s", "strike", "del":
            let frame: Frame
            switch name {
            case "b", "strong": frame = .bold
            case "i", "em": frame = .italic
            case "u": frame = .underline
            default: frame = .strike
            }
            if let index = stack.lastIndex(of: frame) { pop(until: index) }
        default:
            if let index = stack.lastIndex(of: .transparent) { pop(until: index) }
        }
    }

    /// Closes one block-level element: its content is flushed, and an element
    /// that stayed empty leaves one blank paragraph behind — but only when it
    /// was the outermost one, so nested wrappers do not each add a line.
    private mutating func closeBlockElement(named name: String) {
        // A `</div>` closes the signature only when the signature is the
        // innermost open div; a plain div inside it is a block like any other.
        if name == "div", let sigIndex = stack.lastIndex(of: .signature),
           sigIndex > (stack.lastIndex(of: .block) ?? -1) {
            flushBlock()
            signature = max(0, signature - 1)
            pop(until: sigIndex)
            return
        }
        guard !openBlocks.isEmpty else {
            flushBlock()
            return
        }
        flushBlock()
        let wrote = openBlocks.removeLast()
        if name == "pre" { preformatted = max(0, preformatted - 1) }
        if let index = stack.lastIndex(of: .block) { pop(until: index) }
        // An element that closed without any text or picture is a blank line of
        // its own (`<p></p>`), but only at the outermost level: nested wrappers
        // must not each add one.
        if !wrote, openBlocks.isEmpty, !lastBlockWasBlank { markEmptyBlock() }
    }

    /// Closes the nearest of `candidates` (nearest = highest stack index), so a
    /// `</span>` closes the chip it belongs to and not some other span.
    private mutating func popNearest(_ candidates: Frame...) {
        let indexes = candidates.compactMap { stack.lastIndex(of: $0) }
        guard let nearest = indexes.max() else { return }
        pop(until: nearest)
    }

    private mutating func pop(until index: Int) {
        while stack.count > index {
            let frame = stack.removeLast()
            switch frame {
            case .bold: bold = max(0, bold - 1)
            case .italic: italic = max(0, italic - 1)
            case .underline: underline = max(0, underline - 1)
            case .strike: strike = max(0, strike - 1)
            case .link: link = nil
            case .mention: mention = nil
            case .quote, .list, .item, .signature, .block, .transparent: break
            }
        }
    }

    private mutating func push(_ frame: Frame) {
        guard stack.count < RichLimits.maxNestingDepth else {
            // Deeper than any real mail: the rest of the input is not read.
            overflowing = true
            return
        }
        stack.append(frame)
    }

    // MARK: Inhalt

    private mutating func appendText(_ raw: String) {
        let remaining = RichLimits.maxTextCharacters - textCharacters
        guard remaining > 0 else { return }
        var text = RichHTML.decodeEntities(raw)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = text.filter { scalar in
            !(scalar.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" })
        }
        guard !text.isEmpty else { return }
        if text.count > remaining { text = String(text.prefix(remaining)) }
        if preformatted > 0 {
            append(text)
            return
        }
        let collapsed = collapseWhitespace(text)
        guard !collapsed.isEmpty else {
            if text.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) { spacePending = true }
            return
        }
        append(collapsed)
    }

    /// HTML collapses every run of ASCII whitespace into one space, and a space
    /// that was pending from a previous text node still belongs between the
    /// words (`hello <b>world</b>`).
    private mutating func collapseWhitespace(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var sawWhitespace = spacePending
        for character in text {
            let isSpace = character == " " || character == "\n" || character == "\t" || character == "\u{0C}"
            if isSpace {
                sawWhitespace = true
                continue
            }
            if sawWhitespace, !out.isEmpty || !runs.isEmpty {
                out.append(" ")
            } else if sawWhitespace, out.isEmpty, runs.isEmpty {
                // At the very start of a block a space is dropped.
            }
            sawWhitespace = false
            out.append(character)
        }
        spacePending = sawWhitespace
        return out
    }

    private mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        textCharacters += text.count
        markContent()
        let run = RichRun(text: text, bold: bold > 0, italic: italic > 0, underline: underline > 0,
                          strike: strike > 0, link: link, mention: mention)
        if var last = runs.last, last.image == nil, last.formattingKey == run.formattingKey {
            last.text += text
            runs[runs.count - 1] = last
        } else {
            runs.append(run)
        }
    }

    private mutating func appendBreak() {
        spacePending = false
        markContent()
        append("\n")
    }

    private mutating func appendImage(attributes: [(String, String)]) {
        let alt = attribute("alt", attributes).map(RichHTML.decodeEntities) ?? ""
        guard let source = attribute("src", attributes).map(RichHTML.decodeEntities),
              let image = RichImage.parse(dataURL: source, alt: alt) else {
            if !alt.isEmpty { append(alt) }
            return
        }
        if spacePending, var last = runs.last, last.image == nil {
            last.text += " "
            runs[runs.count - 1] = last
        }
        spacePending = false
        markContent()
        runs.append(.image(image))
    }

    private mutating func markContent() {
        for index in openBlocks.indices { openBlocks[index] = true }
    }

    // MARK: Blöcke schreiben

    private mutating func flushBlock() {
        spacePending = false
        let hadBreak = runs.contains { $0.image == nil && $0.text.contains("\n") }
        let trimmed = Self.trim(runs)
        if !trimmed.isEmpty {
            blocks.append(RichBlock(kind: blockKind, quoteDepth: quote, isSignature: signature > 0, runs: trimmed))
        } else if hadBreak {
            // `<div><br></div>`: an explicitly empty line.
            markEmptyBlock()
        }
        runs = []
        blockKind = .paragraph
    }

    /// True when the last block written is already a blank line; keeps two
    /// closing elements from each adding one.
    private var lastBlockWasBlank: Bool { blocks.last?.runs.isEmpty ?? false }

    private mutating func markEmptyBlock() {
        blocks.append(RichBlock(kind: .paragraph, quoteDepth: quote, isSignature: signature > 0, runs: []))
        blockKind = .paragraph
    }

    private mutating func closeAllBlocks() {
        flushBlock()
        while let index = stack.lastIndex(where: { frame in
            if case .signature = frame { return true }
            return false
        }) {
            pop(until: index)
        }
        openBlocks = []
    }

    /// Drops leading and trailing whitespace of a block and the empty runs that
    /// leaves behind; images are content, so they stay.
    private static func trim(_ runs: [RichRun]) -> [RichRun] {
        var result = runs
        guard !result.isEmpty else { return [] }
        if result.first?.image == nil {
            var first = result[0]
            first.text = first.text.drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" }).description
            result[0] = first
        }
        if result.last?.image == nil {
            var last = result[result.count - 1]
            while let character = last.text.last, character == " " || character == "\n" || character == "\t" {
                last.text.removeLast()
            }
            result[result.count - 1] = last
        }
        return result.filter { $0.image != nil || !$0.text.isEmpty }
    }

    private func attribute(_ name: String, _ attributes: [(String, String)]) -> String? {
        attributes.first { $0.0 == name }?.1
    }

    private func classTokens(_ attributes: [(String, String)]) -> Set<String> {
        guard let raw = attribute("class", attributes) else { return [] }
        return Set(raw.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init))
    }
}

// MARK: - Writer

private struct Writer {
    var parts: [String] = []
    private var inSignature = false
    private var quoteDepth = 0
    private var levels: [(kind: RichListKind, itemOpen: Bool)] = []

    mutating func write(_ block: RichBlock) {
        if block.isSignature != inSignature {
            closeLists()
            setQuote(0)
            parts.append(block.isSignature ? "<div class=\"co-signature\">" : "</div>")
            inSignature = block.isSignature
        }
        let depth = min(max(block.quoteDepth, 0), RichLimits.maxQuoteDepth)
        if let kind = block.listKind {
            setQuote(depth)
            openListItem(kind: kind, depth: min(max(block.listDepth, 1), RichLimits.maxListDepth))
            appendInline(Self.trimmed(block.runs))
        } else {
            closeLists()
            setQuote(depth)
            parts.append("<p>")
            let runs = Self.trimmed(block.runs)
            let visible = runs.contains { $0.image != nil || !$0.text.isEmpty }
            if visible {
                appendInline(runs)
            } else {
                parts.append("<br>")
            }
            parts.append("</p>")
        }
    }

    /// The parser trims spaces and soft breaks at the edges of a block (HTML
    /// collapses them anyway). Writing them out again would make the HTML change
    /// on every save — the walkthrough found exactly that with a mention chip
    /// followed by a space.
    static func trimmed(_ runs: [RichRun]) -> [RichRun] {
        var result = runs
        guard !result.isEmpty else { return [] }
        if result[0].image == nil {
            var first = result[0]
            first.text = String(first.text.drop(while: { $0 == " " || $0 == "\n" }))
            result[0] = first
        }
        if result[result.count - 1].image == nil {
            var last = result[result.count - 1]
            while let character = last.text.last, character == " " || character == "\n" {
                last.text.removeLast()
            }
            result[result.count - 1] = last
        }
        return result.filter { $0.image != nil || !$0.text.isEmpty }
    }

    mutating func finish() {
        closeLists()
        setQuote(0)
        if inSignature {
            parts.append("</div>")
            inSignature = false
        }
    }

    // MARK: Zitate

    private mutating func setQuote(_ depth: Int) {
        if depth != quoteDepth { closeLists() }
        while quoteDepth < depth {
            parts.append("<blockquote>")
            quoteDepth += 1
        }
        while quoteDepth > depth {
            parts.append("</blockquote>")
            quoteDepth -= 1
        }
    }

    // MARK: Listen

    private mutating func openListItem(kind: RichListKind, depth: Int) {
        if levels.count > depth { closeLists(to: depth) }
        if levels.count < depth {
            while levels.count < depth {
                if let last = levels.indices.last, !levels[last].itemOpen {
                    parts.append("<li>")
                    levels[last].itemOpen = true
                }
                parts.append("<\(tag(kind))>")
                levels.append((kind, false))
            }
        }
        if let last = levels.indices.last {
            if levels[last].itemOpen {
                parts.append("</li>")
                levels[last].itemOpen = false
            }
            if levels[last].kind != kind {
                closeLists(to: depth - 1)
                parts.append("<\(tag(kind))>")
                levels.append((kind, false))
            }
            parts.append("<li>")
            levels[levels.count - 1].itemOpen = true
        }
    }

    private mutating func closeLists(to depth: Int = 0) {
        while levels.count > depth {
            let level = levels.removeLast()
            if level.itemOpen { parts.append("</li>") }
            parts.append("</\(tag(level.kind))>")
        }
    }

    private func tag(_ kind: RichListKind) -> String { kind == .ordered ? "ol" : "ul" }

    // MARK: Inline

    private mutating func appendInline(_ runs: [RichRun]) {
        var openRun: RichRun?
        for run in runs {
            if let image = run.image {
                if let previous = openRun { closeTags(previous); openRun = nil }
                parts.append("<img src=\"\(RichHTML.escapeAttribute(image.dataURL))\"")
                if !image.alt.isEmpty { parts.append(" alt=\"\(RichHTML.escapeAttribute(image.alt))\"") }
                parts.append(">")
                continue
            }
            guard !run.text.isEmpty else { continue }
            if run.formattingKey != openRun?.formattingKey {
                if let previous = openRun { closeTags(previous) }
                openTags(run)
                openRun = run
            }
            parts.append(RichHTML.escapeText(run.text))
        }
        if let previous = openRun { closeTags(previous) }
    }

    private mutating func openTags(_ run: RichRun) {
        if let link = run.link, let safe = RichHTML.allowedLink(link) {
            parts.append("<a href=\"\(RichHTML.escapeAttribute(safe))\">")
        }
        if run.bold { parts.append("<b>") }
        if run.italic { parts.append("<i>") }
        if run.underline { parts.append("<u>") }
        if run.strike { parts.append("<s>") }
        if let mention = run.mention, !mention.isEmpty {
            parts.append("<span class=\"co-mention\" data-email=\"\(RichHTML.escapeAttribute(mention))\">")
        }
    }

    private mutating func closeTags(_ run: RichRun) {
        if run.mention != nil, !(run.mention ?? "").isEmpty { parts.append("</span>") }
        if run.strike { parts.append("</s>") }
        if run.underline { parts.append("</u>") }
        if run.italic { parts.append("</i>") }
        if run.bold { parts.append("</b>") }
        if run.link != nil, RichHTML.allowedLink(run.link ?? "") != nil { parts.append("</a>") }
    }
}
