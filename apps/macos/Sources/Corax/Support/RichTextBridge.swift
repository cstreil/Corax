import AppKit
import CoraxKit

/// `RichDocument` ↔ `NSAttributedString` (M2.6).
///
/// `CoraxKit` keeps the HTML subset and the block model, this file is the only
/// place where AppKit attributes are made and read. Both directions must stay
/// exact: what the editor shows is what goes out as HTML, so every attribute
/// that carries meaning has a fixed pair here.
enum RichTextBridge {

    // MARK: Attribute

    enum Key {
        /// Quote depth of the paragraph (`Int`, 0 = not quoted).
        static let quote = NSAttributedString.Key(AppIdentity.bundleID + ".rich.quote")
        /// List kind of the paragraph (`String`, "bullet" | "ordered").
        static let list = NSAttributedString.Key(AppIdentity.bundleID + ".rich.list")
        /// List nesting of the paragraph (`Int`, 1-based).
        static let listDepth = NSAttributedString.Key(AppIdentity.bundleID + ".rich.listDepth")
        /// Paragraph belongs to the signature block (`Bool`).
        static let signature = NSAttributedString.Key(AppIdentity.bundleID + ".rich.signature")
        /// The picture of an attachment run (`RichImage`).
        static let image = NSAttributedString.Key(AppIdentity.bundleID + ".rich.image")
        /// E-mail of an `@`-mention chip (`String`).
        static let mention = NSAttributedString.Key(AppIdentity.bundleID + ".rich.mention")
    }

    static let bodyFontSize: CGFloat = 14
    /// Pictures are shown at most this wide in the editor (points).
    static let maxDisplayWidth: CGFloat = 460
    /// …and stored at most this large (pixels on the long edge).
    static let maxPixelSize: CGFloat = 1400

    static func bodyFont(size: CGFloat = bodyFontSize) -> NSFont {
        NSFont.systemFont(ofSize: size)
    }

    // MARK: Dokument → Text

    /// Builds the editor's attributed string. One block per paragraph, the
    /// block's style on the paragraph, its formatting on the runs.
    static func attributedString(from document: RichDocument, theme: Theme,
                                 fontSize: CGFloat = bodyFontSize) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if document.blocks.isEmpty { return result }
        for block in document.blocks {
            let start = result.length
            for run in block.runs {
                if let image = run.image {
                    appendImage(image, in: result, fontSize: fontSize, theme: theme)
                } else {
                    var attributes = inlineAttributes(run, theme: theme, fontSize: fontSize)
                    if block.quoteDepth > 0 { attributes[.foregroundColor] = theme.ink2.ns }
                    if block.isSignature { attributes[.foregroundColor] = theme.ink3.ns }
                    let text = run.text.replacingOccurrences(of: "\n", with: "\u{2028}")
                    result.append(NSAttributedString(string: text, attributes: attributes))
                }
            }
            let paragraphRange = NSRange(location: start, length: result.length - start)
            result.addAttributes(paragraphAttributes(for: block, theme: theme, fontSize: fontSize),
                                 range: paragraphRange)
            result.append(NSAttributedString(string: "\n",
                                             attributes: paragraphTextAttributes(for: block, theme: theme,
                                                                                 fontSize: fontSize)))
        }
        return result
    }

    private static func appendImage(_ image: RichImage, in result: NSMutableAttributedString,
                                    fontSize: CGFloat, theme: Theme) {
        let attachment = NSTextAttachment()
        let nsImage = NSImage(data: image.data)
        attachment.image = nsImage
        if let nsImage, nsImage.size.width > 0 {
            let width = min(nsImage.size.width, maxDisplayWidth)
            let scale = width / nsImage.size.width
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: nsImage.size.height * scale)
        }
        // The font stays the body font on purpose: a font as tall as the picture
        // would leak into the typing attributes and blow up the next paragraph
        // (first attempt at the line height, M2.6 walkthrough). The paragraph's
        // minimum line height does the reserving instead.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont(size: fontSize),
            Key.image: image,
        ]
        result.append(NSAttributedString(attachment: attachment))
        let range = NSRange(location: result.length - 1, length: 1)
        result.addAttributes(attributes, range: range)
        _ = theme
    }

    private static func inlineAttributes(_ run: RichRun, theme: Theme,
                                         fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let manager = NSFontManager.shared
        var font = bodyFont(size: fontSize)
        if run.bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if run.italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.ink.ns,
        ]
        if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link, let safe = RichHTML.allowedLink(link), let url = URL(string: safe) {
            attributes[.link] = url
            attributes[.foregroundColor] = theme.accent.ns
        }
        if let mention = run.mention {
            attributes[Key.mention] = mention
            attributes[.backgroundColor] = theme.accent.ns.withAlphaComponent(0.13)
        }
        return attributes
    }

    /// Paragraph-level attributes only (style, quote/list/signature markers).
    /// The font belongs to the runs: adding it here would flatten every bold or
    /// italic stretch of the paragraph.
    private static func paragraphAttributes(for block: RichBlock, theme: Theme,
                                            fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 0
        var attributes: [NSAttributedString.Key: Any] = [:]
        let quote = min(max(block.quoteDepth, 0), RichLimits.maxQuoteDepth)
        if quote > 0 {
            attributes[Key.quote] = quote
            style.firstLineHeadIndent = CGFloat(quote) * 14
            style.headIndent = CGFloat(quote) * 14
            attributes[.backgroundColor] = theme.accent.ns.withAlphaComponent(0.07)
        }
        if let kind = block.listKind {
            let depth = min(max(block.listDepth, 1), RichLimits.maxListDepth)
            attributes[Key.list] = kind.rawValue
            attributes[Key.listDepth] = depth
            style.textLists = (1...depth).map { level in
                NSTextList(markerFormat: marker(kind, level: level), options: 0)
            }
            let indent = CGFloat(depth) * 20
            style.firstLineHeadIndent = indent
            style.headIndent = indent + 4
        }
        if block.isSignature { attributes[Key.signature] = true }
        // TextKit 2 does not grow the line from `NSTextAttachment.bounds` alone:
        // without a minimum line height the picture overlaps the next line.
        let tallest = block.runs.compactMap { run -> CGFloat? in
            guard let image = run.image, let nsImage = NSImage(data: image.data), nsImage.size.width > 0 else {
                return nil
            }
            let scale = min(nsImage.size.width, maxDisplayWidth) / nsImage.size.width
            return nsImage.size.height * scale
        }.max() ?? 0
        if tallest > 0 { style.minimumLineHeight = tallest + 4 }
        attributes[.paragraphStyle] = style
        return attributes
    }

    /// What the paragraph's own newline carries, so typing there continues in
    /// the right look (and an empty paragraph is not a different font).
    private static func paragraphTextAttributes(for block: RichBlock, theme: Theme,
                                                fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        var attributes = paragraphAttributes(for: block, theme: theme, fontSize: fontSize)
        attributes[.font] = bodyFont(size: fontSize)
        attributes[.foregroundColor] = block.isSignature ? theme.ink3.ns
            : (block.quoteDepth > 0 ? theme.ink2.ns : theme.ink.ns)
        return attributes
    }

    /// The paragraph style for a block (also used when the editor re-applies a
    /// style after a formatting toggle).
    static func paragraphStyle(quote: Int, list: RichListKind?, depth: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 0
        let quoteDepth = min(max(quote, 0), RichLimits.maxQuoteDepth)
        if quoteDepth > 0 {
            style.firstLineHeadIndent = CGFloat(quoteDepth) * 14
            style.headIndent = CGFloat(quoteDepth) * 14
        }
        if let list {
            let levels = min(max(depth, 1), RichLimits.maxListDepth)
            style.textLists = (1...levels).map { level in
                NSTextList(markerFormat: marker(list, level: level), options: 0)
            }
            let indent = CGFloat(levels) * 20
            style.firstLineHeadIndent = indent
            style.headIndent = indent + 4
        }
        return style
    }

    /// Nested lists alternate their marker: disc → circle → square,
    /// decimal → lower-alpha → lower-roman.
    private static func marker(_ kind: RichListKind, level: Int) -> NSTextList.MarkerFormat {
        switch kind {
        case .bullet:
            return [.disc, .circle, .square][(level - 1) % 3]
        case .ordered:
            return [.decimal, .lowercaseAlpha, .lowercaseRoman][(level - 1) % 3]
        }
    }

    // MARK: Text → Dokument

    /// Reads the editor's text back into the block model.
    static func document(from attributed: NSAttributedString) -> RichDocument {
        let string = attributed.string as NSString
        guard string.length > 0 else { return RichDocument() }
        var blocks: [RichBlock] = []
        var location = 0
        // `lineRange(for:)` would also break at U+2028, which is exactly our soft
        // break inside a block — so the newline is searched by hand.
        while location < string.length {
            var end = location
            while end < string.length, string.character(at: end) != 0x0A { end += 1 }
            blocks.append(block(from: attributed, range: NSRange(location: location, length: end - location)))
            location = end + 1
        }
        return RichDocument(blocks: blocks)
    }

    private static func block(from attributed: NSAttributedString, range: NSRange) -> RichBlock {
        var block = RichBlock()
        let attributes = range.length > 0
            ? attributed.attributes(at: range.location, effectiveRange: nil)
            : (attributed.length > 0 ? attributed.attributes(at: max(0, min(range.location, attributed.length - 1)),
                                                             effectiveRange: nil) : [:])
        if let quote = attributes[Key.quote] as? Int { block.quoteDepth = max(0, quote) }
        if let raw = attributes[Key.list] as? String, let kind = RichListKind(rawValue: raw) {
            block.kind = .listItem(kind, depth: max(1, attributes[Key.listDepth] as? Int ?? 1))
        }
        block.isSignature = attributes[Key.signature] as? Bool ?? false
        guard range.length > 0 else { return block }
        attributed.enumerateAttributes(in: range, options: []) { runAttributes, runRange, _ in
            let text = (attributed.string as NSString).substring(with: runRange)
            if let image = runAttributes[Key.image] as? RichImage {
                block.runs.append(.image(image))
                return
            }
            var run = RichRun(text: text.replacingOccurrences(of: "\u{2028}", with: "\n"))
            if let font = runAttributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                run.bold = traits.contains(.bold)
                run.italic = traits.contains(.italic)
            }
            if let underline = runAttributes[.underlineStyle] as? Int, underline != 0 { run.underline = true }
            if let strike = runAttributes[.strikethroughStyle] as? Int, strike != 0 { run.strike = true }
            if let url = runAttributes[.link] as? URL {
                run.link = RichHTML.allowedLink(url.absoluteString)
            } else if let string = runAttributes[.link] as? String {
                run.link = RichHTML.allowedLink(string)
            }
            if let mention = runAttributes[Key.mention] as? String { run.mention = mention }
            block.runs.append(run)
        }
        // Merge runs the editor split without a visible reason (a caret move
        // inside one word), so the HTML stays small.
        var merged: [RichRun] = []
        for run in block.runs {
            if var last = merged.last, last.image == nil, run.image == nil,
               last.formattingKey == run.formattingKey {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        block.runs = merged
        return block
    }

    // MARK: Bilder

    /// Encodes a pasted or dropped picture for the draft: at most
    /// `maxPixelSize` on the long edge and at most `RichLimits.maxImageBytes`.
    /// PNG keeps transparency; when a photo is too big as PNG it is written as
    /// JPEG instead of refusing it.
    static func encode(_ image: NSImage, alt: String = "") -> RichImage? {
        let scaled = downscaled(image, maxPixel: maxPixelSize)
        guard let tiff = scaled.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        if bitmap.hasAlpha {
            if let png = bitmap.representation(using: .png, properties: [:]), png.count <= RichLimits.maxImageBytes {
                return RichImage(data: png, mime: .png, alt: alt)
            }
        }
        for quality in [0.85, 0.7, 0.5] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= RichLimits.maxImageBytes {
                return RichImage(data: jpeg, mime: .jpeg, alt: alt)
            }
        }
        // Still too heavy: one more halving, then give up (the caller says so).
        guard scaled.size.width > 320 else { return nil }
        let smaller = NSImage(size: NSSize(width: scaled.size.width / 2, height: scaled.size.height / 2))
        smaller.lockFocus()
        scaled.draw(in: NSRect(origin: .zero, size: smaller.size))
        smaller.unlockFocus()
        guard let smallTiff = smaller.tiffRepresentation,
              let smallBitmap = NSBitmapImageRep(data: smallTiff),
              let jpeg = smallBitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]),
              jpeg.count <= RichLimits.maxImageBytes else { return nil }
        return RichImage(data: jpeg, mime: .jpeg, alt: alt)
    }

    static func downscaled(_ image: NSImage, maxPixel: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > maxPixel || size.height > maxPixel, size.width > 0, size.height > 0 else { return image }
        let scale = maxPixel / max(size.width, size.height)
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        result.unlockFocus()
        return result
    }

    /// The picture on the pasteboard, if there is one.
    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let data = pasteboard.data(forType: .png), let image = NSImage(data: data) { return image }
        if let data = pasteboard.data(forType: .tiff), let image = NSImage(data: data) { return image }
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }
}

// MARK: - Formatierungszustand

/// What the format bar shows: the formatting at the caret or of the selection.
struct RichFormatState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var listKind: RichListKind?
    var quote = false
    var link: String?
}
