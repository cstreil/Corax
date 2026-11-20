import Foundation

/// One `mailto:` link, parsed per RFC 6068 (M2.4).
///
/// The bundle registers the scheme, so macOS hands the app a `mailto:` URL when
/// it is the chosen mail program — and a link inside a mail reaches the same
/// parser through the core's `open_url`. Both paths must give the composer the
/// same fields:
///
/// - the path holds the recipient list (`mailto:a@b,c@d`), percent-encoded;
/// - the query carries `to`, `cc`, `bcc`, `subject`, `body` and `in-reply-to`
///   (all optional, each value percent-encoded, UTF-8);
/// - `+` is a literal plus sign, **not** a space (unlike form encoding);
/// - an invalid percent escape makes the whole link malformed: guessing would
///   put a wrong address into a draft.
public struct MailtoLink: Sendable, Equatable {
    public var to: [String] = []
    public var cc: [String] = []
    public var bcc: [String] = []
    public var subject = ""
    public var body = ""
    public var inReplyTo: String?

    public init() {}

    /// Whether the link has anything worth opening a composer for.
    public var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && body.isEmpty
    }

    public static func parse(_ url: URL) -> MailtoLink? { parse(url.absoluteString) }

    public static func parse(_ text: String) -> MailtoLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7, trimmed.prefix(7).lowercased() == "mailto:" else { return nil }
        let rest = trimmed.dropFirst(7)
        // The query starts at the first `?`; a `?` inside a value is encoded.
        let path: Substring
        let query: Substring?
        if let mark = rest.firstIndex(of: "?") {
            path = rest[rest.startIndex..<mark]
            query = rest[rest.index(after: mark)..<rest.endIndex]
        } else {
            path = rest
            query = nil
        }
        var link = MailtoLink()
        switch addresses(String(path)) {
        case .failure: return nil
        case .success(let list): link.to = list
        }
        if let query {
            guard parse(query, into: &link) else { return nil }
        }
        return link
    }

    /// `to=a@b,c@d&cc=…&subject=…`; returns false on an invalid escape.
    private static func parse(_ query: Substring, into link: inout MailtoLink) -> Bool {
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let key: Substring
            let rawValue: Substring
            if let equals = pair.firstIndex(of: "=") {
                key = pair[pair.startIndex..<equals]
                rawValue = pair[pair.index(after: equals)..<pair.endIndex]
            } else {
                key = pair
                rawValue = ""
            }
            guard let name = decode(String(key))?.lowercased(), let value = decode(String(rawValue)) else {
                return false
            }
            switch name {
            case "to":
                guard case .success(let list) = addresses(value) else { return false }
                link.to += list
            case "cc":
                guard case .success(let list) = addresses(value) else { return false }
                link.cc += list
            case "bcc":
                guard case .success(let list) = addresses(value) else { return false }
                link.bcc += list
            case "subject":
                link.subject = value
            case "body":
                link.body = value
            case "in-reply-to":
                link.inReplyTo = value
            default:
                // Unknown fields are ignored on purpose: RFC 6068 allows them,
                // and a wrong guess would land in the draft.
                continue
            }
        }
        return true
    }

    /// A comma-separated list of addresses.
    ///
    /// An address that could break out of its header is dropped instead of
    /// taken (W1 aus dem Audit M2): `mail-builder` writes it raw, so a control
    /// character, a space, `<`, `>`, `,`, `;` or a quote would edit the header
    /// block. That includes the RFC 6068 `%2C` form: unquoted it turns one
    /// recipient into two. The rest of the link still opens.
    private static func addresses(_ text: String) -> Result<[String], ParseFailure> {
        var list: [String] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard let decoded = decode(String(part)) else { return .failure(ParseFailure()) }
            let address = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, HeaderSafety.isUsableAddress(address) else { continue }
            list.append(address)
        }
        return .success(list)
    }

    /// Percent-decodes UTF-8; nil for an invalid escape (`%zz`, `%G1`).
    /// A literal `+` stays a `+`.
    private static func decode(_ text: String) -> String? {
        guard text.contains("%") else { return text }
        return text.removingPercentEncoding
    }

    struct ParseFailure: Error {}
}

extension MailtoLink {
    /// The addresses as `Address` values the composer takes (no display name:
    /// RFC 6068 carries address specs only).
    public var toAddresses: [Address] { to.map { Address(name: nil, email: $0) } }
    public var ccAddresses: [Address] { cc.map { Address(name: nil, email: $0) } }
}
