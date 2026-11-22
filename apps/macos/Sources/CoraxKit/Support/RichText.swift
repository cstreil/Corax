import Foundation

// MARK: - Grenzen

/// Limits for the composer's rich text (M2.6).
///
/// The rich body travels three ways: the editor's attributed string, the
/// stored HTML of a draft, and the `text/html` part of outgoing mail. All three
/// go through the parser in `RichHTML`, so every limit that protects the app is
/// enforced there. `2 MB` of decoded image data is the size of one embedded
/// picture: Tauri embeds pasted pictures as `data:` URLs without any limit, and
/// a draft with three 8 MB photos is unopenable in other clients.
public enum RichLimits {
    /// HTML accepted by `RichHTML.parse`. Signatures and drafts are kilobytes;
    /// a big picture pushes a body over 1 MB, so the limit is generous.
    public static let maxHTMLBytes = 4 * 1024 * 1024
    /// Decoded bytes of one embedded image.
    public static let maxImageBytes = 2 * 1024 * 1024
    /// Longest link the parser and the writer accept.
    public static let maxURLCharacters = 2048
    /// Element nesting the parser follows; deeper input is dropped, not walked.
    public static let maxNestingDepth = 64
    /// Up to this many tokens are read from one HTML string.
    public static let maxTokens = 200_000
    /// Blocks per document.
    public static let maxBlocks = 20_000
    /// Visible characters per document (all text runs together).
    public static let maxTextCharacters = 1_000_000
    /// Quote levels the composer shows (nested quotes deeper than this are
    /// flattened into the last level).
    public static let maxQuoteDepth = 6
    /// List nesting levels (`NSTextList` nesting in the editor).
    public static let maxListDepth = 4
}

// MARK: - Bilder

/// The image types the composer embeds (`data:` URLs only).
public enum RichMime: String, Sendable, CaseIterable {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case gif = "image/gif"
    case webp = "image/webp"
    case heic = "image/heic"

    /// `jpg` is the same type written differently; mail clients send both.
    public static func parse(_ raw: String) -> RichMime? {
        switch raw.lowercased() {
        case "image/png": .png
        case "image/jpeg", "image/jpg", "image/pjpeg": .jpeg
        case "image/gif": .gif
        case "image/webp": .webp
        case "image/heic", "image/heif": .heic
        default: nil
        }
    }

    /// The leading bytes a file of this type must have. A `data:` URL claims
    /// its type, and mail clients sniff the decoded bytes; refusing a payload
    /// that does not match its claim keeps a `image/png` header from carrying
    /// something else.
    var magic: [[UInt8]] {
        switch self {
        case .png: [[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]]
        case .jpeg: [[0xFF, 0xD8, 0xFF]]
        case .gif: [[0x47, 0x49, 0x46, 0x38]]          // "GIF8" (87a and 89a)
        case .webp: [[0x52, 0x49, 0x46, 0x46]]
        case .heic: [[0x66, 0x74, 0x79, 0x70]]
        }
    }

    func matchesMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return magic.contains { prefix in
            data.count >= prefix.count && Array(data.prefix(prefix.count)) == prefix
        }
    }

    /// Sniffs the type of a file the user pasted or dropped.
    public static func sniff(_ data: Data) -> RichMime? {
        allCases.first { $0.matchesMagic(data) }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        case .webp: "webp"
        case .heic: "heic"
        }
    }
}

/// One embedded picture: the decoded bytes, the type they claim, and the alt
/// text that goes out instead of the picture in the text part.
public struct RichImage: Hashable, Sendable {
    public var data: Data
    public var mime: RichMime
    public var alt: String

    public init(data: Data, mime: RichMime, alt: String = "") {
        self.data = data
        self.mime = mime
        self.alt = alt
    }

    public var dataURL: String { "data:\(mime.rawValue);base64,\(data.base64EncodedString())" }

    /// Parses `data:image/…;base64,…` and refuses everything that is not one of
    /// the image types above or exceeds `RichLimits.maxImageBytes`.
    ///
    /// Nothing is decoded before the header is checked, and the base64 length
    /// is bounded before the bytes are allocated, so a hostile `data:` URL
    /// cannot make the app allocate gigabytes.
    public static func parse(dataURL raw: String, alt: String = "",
                             limit: Int = RichLimits.maxImageBytes) -> RichImage? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 22, trimmed.count <= limit * 2 + 4096 else { return nil }
        // The comma has to be cut from `trimmed` before lowercasing: `lowercased()`
        // can change the UTF-8 length (U+212A KELVIN SIGN becomes "k", U+0130
        // becomes "i̇"), and an index from `trimmed` would then point past the
        // end of `lower` and trap. A hostile mail could send such an `img src`.
        guard let comma = trimmed.firstIndex(of: ",") else { return nil }
        let header = String(trimmed[..<comma]).lowercased()
        guard header.hasPrefix("data:") else { return nil }
        let parts = header.dropFirst(5).split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, let mime = RichMime.parse(String(parts[0])) else { return nil }
        guard parts.contains("base64") else { return nil }
        let payload = trimmed[trimmed.index(after: comma)...]
        // Every four base64 characters decode to three bytes.
        guard payload.count <= (limit / 3 + 1) * 4 + 4 else { return nil }
        let compact = payload.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(compact), options: []) else { return nil }
        guard !data.isEmpty, data.count <= limit else { return nil }
        guard mime.matchesMagic(data) else { return nil }
        return RichImage(data: data, mime: mime, alt: alt)
    }
}

// MARK: - Läufe (Inline-Formatierung)

/// One formatted stretch of text, or one picture.
///
/// `text` holds `\n` for a soft line break inside a block (`<br>` in HTML,
/// `U+2028` in the editor).
public struct RichRun: Hashable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strike: Bool
    /// Target of a link, already validated (`http`, `https`, `mailto`, `tel`).
    public var link: String?
    /// E-mail of an `@`-mention chip (Tauri's `span.co-mention`).
    public var mention: String?
    /// Set when this run is one picture; `text` is empty then.
    public var image: RichImage?

    public init(text: String = "", bold: Bool = false, italic: Bool = false,
                underline: Bool = false, strike: Bool = false, link: String? = nil,
                mention: String? = nil, image: RichImage? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.link = link
        self.mention = mention
        self.image = image
    }

    public static func image(_ image: RichImage) -> RichRun { RichRun(image: image) }

    /// The same flags, so adjacent runs can be merged before they are written.
    public var formattingKey: String {
        "\(bold)\(italic)\(underline)\(strike)|\(link ?? "")|\(mention ?? "")|\(image?.mime.rawValue ?? "")"
    }
}

// MARK: - Blöcke

public enum RichListKind: String, Sendable, CaseIterable {
    case bullet
    case ordered
}

/// One paragraph, one list item, or one quoted paragraph.
public struct RichBlock: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case paragraph
        /// `depth` is 1 for a plain list item, 2 for one nested inside it.
        case listItem(RichListKind, depth: Int)
    }

    public var kind: Kind
    /// 0 = not quoted, 1 = `> `, 2 = inside two blockquotes, and so on.
    public var quoteDepth: Int
    /// Belongs to the signature block (`div.co-signature` in HTML).
    public var isSignature: Bool
    public var runs: [RichRun]

    public init(kind: Kind = .paragraph, quoteDepth: Int = 0, isSignature: Bool = false,
                runs: [RichRun] = []) {
        self.kind = kind
        self.quoteDepth = quoteDepth
        self.isSignature = isSignature
        self.runs = runs
    }

    public init(text: String, kind: Kind = .paragraph, quoteDepth: Int = 0, isSignature: Bool = false) {
        self.init(kind: kind, quoteDepth: quoteDepth, isSignature: isSignature,
                  runs: text.isEmpty ? [] : [RichRun(text: text)])
    }

    public var isList: Bool {
        if case .listItem = kind { return true }
        return false
    }

    public var listKind: RichListKind? {
        if case .listItem(let kind, _) = kind { return kind }
        return nil
    }

    public var listDepth: Int {
        if case .listItem(_, let depth) = kind { return depth }
        return 0
    }

    /// The block's text, pictures left out (`\n` for soft breaks).
    public var text: String { runs.compactMap { $0.image == nil ? $0.text : nil }.joined() }

    public var isEmpty: Bool {
        runs.allSatisfy { $0.image == nil && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var hasImages: Bool { runs.contains { $0.image != nil } }
}

/// A parsed rich body: the blocks in reading order.
public struct RichDocument: Hashable, Sendable {
    public var blocks: [RichBlock]

    public init(blocks: [RichBlock] = []) {
        self.blocks = blocks
    }

    public init(text: String) {
        let blocks = text.components(separatedBy: "\n").map { RichBlock(text: $0) }
        self.init(blocks: blocks.isEmpty ? [RichBlock()] : blocks)
    }

    public var isEmpty: Bool { blocks.allSatisfy { $0.isEmpty && !$0.hasImages } }

    /// Everything except the signature blocks (what the AI writes into).
    public var withoutSignature: RichDocument {
        RichDocument(blocks: blocks.filter { !$0.isSignature })
    }

    public var hasSignature: Bool { blocks.contains(where: { $0.isSignature }) }

    /// The plain text: `- ` per list item and `> ` per quote level, as Tauri's
    /// `htmlToText` builds it.
    public var plainText: String {
        var lines: [String] = []
        for block in blocks {
            var text = block.runs.map { run -> String in
                if let image = run.image {
                    return image.alt.isEmpty ? "" : "[\(image.alt)]"
                }
                return run.text.replacingOccurrences(of: "\u{00A0}", with: " ")
            }.joined()
            if block.isList { text = "- " + text }
            let prefix = block.quoteDepth > 0 ? String(repeating: "> ", count: block.quoteDepth) : ""
            for part in text.components(separatedBy: "\n") {
                let line = part.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    lines.append(prefix.trimmingCharacters(in: .whitespaces))
                } else {
                    lines.append(prefix + line)
                }
            }
        }
        let joined = lines.joined(separator: "\n")
        let collapsed = joined.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
