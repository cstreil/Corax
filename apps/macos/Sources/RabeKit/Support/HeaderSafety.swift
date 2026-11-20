import Foundation

/// What may go into a mail header (W1 aus dem Audit M2).
///
/// `mail-builder` 0.4.4 writes a Subject or an address **raw**: a line break in
/// it becomes a second header line, so `Hallo\r\nBcc: x@y` sends a hidden copy
/// and `subject=…%0D%0AReply-To:…` redirects the answer. The core's envelope is
/// built explicitly (`smtp/mod.rs`) and is not affected, but `Reply-To`, `Cc`
/// and `Bcc` are.
///
/// The core sanitizes neither on `save_draft`; the app is the last place before
/// the draft is written, so it cleans here. The same cleaning belongs in the
/// core's `build_message` — that is a core change and the user's call.
public enum HeaderSafety {
    /// A Subject with the line breaks folded to spaces and every other control
    /// character removed.
    public static func subject(_ raw: String) -> String {
        guard raw.unicodeScalars.contains(where: isControl) else { return raw }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        var lastWasSpace = true   // no leading space, also not from `\r\n`
        for scalar in raw.unicodeScalars {
            if isLineBreak(scalar) || scalar.value == 0x09 {
                // A run of breaks (`\r\n`) or a tab folds to one space.
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
                continue
            }
            if isControl(scalar) { continue }
            out.append(scalar)
            lastWasSpace = scalar.value == 0x20 || scalar.value == 0x09
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    /// Whether an address from an untrusted link (`mailto:` in a mail, from the
    /// system) may go into a draft.
    ///
    /// RFC 6068 carries address specs, so no display name, no comment and no
    /// list: `<`, `>`, `,`, `;`, `"`, `(`, `)` and `\` all mean somebody is
    /// trying to break out of the address, and a control character or space
    /// would split the header. The encoded comma (`%2C`) is refused as well:
    /// written unquoted it turns one recipient into two.
    public static func isUsableAddress(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 320 else { return false }
        for scalar in raw.unicodeScalars where forbiddenAddressScalars.contains(scalar) {
            return false
        }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return true
    }

    // MARK: - Kleinigkeiten

    private static let lineBreaks = CharacterSet(charactersIn: "\n\r\u{0085}\u{2028}\u{2029}")
    private static let control = CharacterSet.controlCharacters.union(lineBreaks)
    private static let forbiddenAddressScalars =
        CharacterSet.controlCharacters
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "<>,;\"\\()"))

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool { lineBreaks.contains(scalar) }
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool { control.contains(scalar) }
}
