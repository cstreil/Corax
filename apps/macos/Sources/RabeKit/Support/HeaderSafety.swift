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
    ///
    /// N1 aus dem Audit M2: only **Cc** goes. `CharacterSet.controlCharacters`
    /// holds Cc *and* Cf, and removing Cf broke emoji sequences (ZWJ) and RTL
    /// text (RLM, ALM) — including in replies to a foreign subject. The core
    /// applies the same rule in `build_message` (`sanitize_subject`).
    public static func subject(_ raw: String) -> String {
        guard raw.unicodeScalars.contains(where: isControl) else { return raw }
        let scalars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if isFoldableBreak(scalar) {
                // A run of breaks, tabs and the spaces around it folds to one
                // space; a subject without a break keeps its typed spaces.
                while i < scalars.count, isFoldableBreak(scalars[i]) || scalars[i].value == 0x20 {
                    i += 1
                }
                while out.last?.value == 0x20 { out.removeLast() }
                if !out.isEmpty { out.append(" ") }
                continue
            }
            if isControl(scalar) {
                i += 1
                continue
            }
            out.append(scalar)
            i += 1
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

    private static let forbiddenAddressScalars =
        CharacterSet.controlCharacters
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "<>,;\"\\()"))

    /// CR, LF and TAB: the three Cc characters that fold to a space.
    private static func isFoldableBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x0D || scalar.value == 0x0A || scalar.value == 0x09
    }

    /// Unicode general category Cc: U+0000–U+001F, U+007F and U+0080–U+009F.
    /// Deliberately not `CharacterSet.controlCharacters`, which also holds Cf.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value <= 0x1F || (0x7F...0x9F).contains(value)
    }
}
