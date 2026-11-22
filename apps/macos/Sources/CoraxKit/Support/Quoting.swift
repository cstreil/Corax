import Foundation

/// The plain-text quote blocks the composer inserts (M2.5):
/// `quote-selection` (`⇧R`) and the reply quote.
///
/// Tauri renders these as HTML (`selectionQuoteHtml`, `quoteToHtml`); the
/// text-only composer keeps the same shape as plain text: every line prefixed
/// with "> ", an empty line after the block for typing.
public enum Quoting {
    /// The marked passage, as a `>` block. Blank lines stay blank (no ">").
    public static func block(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { out.append(">"); continue }
            // An already quoted line is not quoted twice.
            if trimmed.hasPrefix(">") { out.append(trimmed); continue }
            out.append("> " + trimmed)
        }
        while out.last == ">" { out.removeLast() }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `quote-selection` (`⇧R`): the marked passage as a `blockquote`, the
    /// shape Tauri's `selectionQuoteHtml` produces.
    public static func selectionHTML(_ text: String) -> String {
        let content = RichHTML.html(fromPlainText: text)
        guard !content.isEmpty else { return "" }
        let document = RichHTML.quoted(RichHTML.parse(content))
        return RichHTML.html(from: document)
    }

    /// The reply quote: the attribution line, then the original as a
    /// `blockquote` (Tauri's `quoteToHtml`).
    ///
    /// The original keeps its formatting when its HTML is known, because a
    /// quote of a table or a list reads badly as plain text; images are not
    /// quoted (they would be embedded into every draft).
    public static func replyHTML(bodyHTML: String?, bodyText: String?, from: Address, date: Date) -> String {
        let original: RichDocument
        if let bodyHTML, !bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            original = RichHTML.parse(bodyHTML)
        } else if let bodyText, !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            original = RichHTML.parse(RichHTML.html(fromPlainText: bodyText))
        } else {
            return ""
        }
        var quoted = RichHTML.quoted(original)
        for index in quoted.blocks.indices {
            quoted.blocks[index].runs = quoted.blocks[index].runs.filter { $0.image == nil }
        }
        quoted.blocks = quoted.blocks.filter { !$0.isEmpty }
        let name = from.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let who = name.isEmpty ? from.email : "\(name) <\(from.email)>"
        let attribution = "Am \(Format.longDate(date)) um \(Format.pickerTime(date)) schrieb \(who):"
        let header = RichHTML.html(from: RichDocument(blocks: [RichBlock(runs: [RichRun(text: attribution)])]))
        guard !quoted.blocks.isEmpty else { return "" }
        let body = RichHTML.html(from: quoted)
        return header + body
    }

    /// A forwarded mail: Tauri's `forwardBlock` as blocks — the separator and
    /// the header lines, then the original unchanged.
    public static func forwardHTML(bodyHTML: String?, bodyText: String?, from: Address, to: [Address],
                                   subject: String, date: Date) -> String {
        let original: RichDocument
        if let bodyHTML, !bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            original = RichHTML.parse(bodyHTML)
        } else if let bodyText, !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            original = RichHTML.parse(RichHTML.html(fromPlainText: bodyText))
        } else {
            return ""
        }
        let name = from.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let who = name.isEmpty ? from.email : "\(name) <\(from.email)>"
        let recipients = to.map(\.email).joined(separator: ", ")
        let header = [
            "---------- Weitergeleitete Nachricht ----------",
            "Von: \(who)",
            "Datum: \(Format.longDate(date)) \(Format.pickerTime(date))",
            "Betreff: \(subject)",
            "An: \(recipients)",
        ]
        var blocks = header.map { RichBlock(runs: [RichRun(text: $0)]) }
        blocks.append(RichBlock())
        blocks += original.blocks.filter { block in
            !block.runs.allSatisfy { $0.image != nil }
        }
        for index in blocks.indices { blocks[index].isSignature = false }
        return RichHTML.html(from: RichDocument(blocks: blocks))
    }

    /// The attribution line Tauri puts above a wire quote: "Am 3. März 2026 um
    /// 14:30 schrieb Ana Müller <ana@example.test>:" plus the body.
    public static func wireQuote(body: String, from: Address, date: Date) -> String {
        let name = from.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let who = name.isEmpty ? from.email : "\(name) <\(from.email)>"
        let header = "Am \(Format.longDate(date)) um \(Format.pickerTime(date)) schrieb \(who):"
        let quoted = block(body)
        return quoted.isEmpty ? header : header + "\n" + quoted
    }
}
