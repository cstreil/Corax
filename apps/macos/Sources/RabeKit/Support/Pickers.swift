import Foundation

/// Port of `src/keyboard/commandScore.ts` (Superhuman's command-score, MIT):
/// how well `query` matches `candidate` — 1.0 exact, decaying through word
/// beginnings and gaps, 0 for no match. The pickers rank with it, so ⇧A-typing
/// "in" finds "INBOX" before "Einladungen".
public enum CommandScore {
    private static let continueMatch = 1.0
    private static let spaceWordJump = 0.9
    private static let nonSpaceWordJump = 0.8
    private static let characterJump = 0.17
    private static let transposition = 0.1
    private static let skipped = 0.999
    private static let caseMismatch = 0.9999
    private static let notComplete = 0.99

    private static let gapCharacters: Set<Character> = ["\\", "/", "_", "+", ".", "#", "\"", "@", "[", "(", "{", "&"]
    private static let spaceCharacters: Set<Character> = [" ", "-", "\t"]

    public static func score(_ candidate: String, _ query: String) -> Double {
        let string = format(candidate)
        let abbreviation = format(query)
        guard !abbreviation.isEmpty else { return 1 }
        var memo: [Int: Double] = [:]
        return inner(Array(string), Array(abbreviation), 0, 0, &memo)
    }

    private static func format(_ text: String) -> String {
        String(text.lowercased().map { spaceCharacters.contains($0) ? " " : $0 })
    }

    /// `string`/`abbreviation` are lowercased character arrays.
    private static func inner(_ string: [Character], _ abbreviation: [Character],
                              _ stringIndex: Int, _ abbreviationIndex: Int,
                              _ memo: inout [Int: Double]) -> Double {
        if abbreviationIndex == abbreviation.count {
            return stringIndex == string.count ? continueMatch : notComplete
        }
        let key = stringIndex &* 1000 &+ abbreviationIndex
        if let cached = memo[key] { return cached }
        let abbreviationChar = abbreviation[abbreviationIndex]
        var highScore = 0.0
        var index = stringIndex
        while index < string.count {
            if string[index] != abbreviationChar {
                index += 1
                continue
            }
            var score = inner(string, abbreviation, index + 1, abbreviationIndex + 1, &memo)
            if score > 0 {
                if index == stringIndex {
                    score *= continueMatch
                } else if index > 0, gapCharacters.contains(string[index - 1]) {
                    score *= nonSpaceWordJump
                    if stringIndex > 0 {
                        let breaks = string[stringIndex..<(index - 1)].filter { gapCharacters.contains($0) }.count
                        score *= pow(skipped, Double(breaks))
                    }
                } else if index > 0, spaceCharacters.contains(string[index - 1]) {
                    score *= spaceWordJump
                    if stringIndex > 0 {
                        let breaks = string[stringIndex..<(index - 1)].filter { spaceCharacters.contains($0) }.count
                        score *= pow(skipped, Double(breaks))
                    }
                } else {
                    score *= characterJump
                    if stringIndex > 0 { score *= pow(skipped, Double(index - stringIndex)) }
                }
            }
            // A transposition ("recieve" for "receive") is heavily penalised.
            if index > 0, index + 1 < abbreviation.count,
               string[index - 1] == abbreviation[abbreviationIndex + 1] || (
                   abbreviation[abbreviationIndex + 1] == abbreviationChar && string[index - 1] != abbreviationChar) {
                let transposed = inner(string, abbreviation, index + 1, abbreviationIndex + 2, &memo) * transposition
                if transposed > score { score = transposed }
            }
            if score > highScore { highScore = score }
            index += 1
        }
        memo[key] = highScore
        return highScore
    }
}

/// One line of the sidebar's folder tree (M2.9): the folder, its indent level
/// and its name without the IMAP path.
public struct FolderRow: Identifiable, Hashable {
    public let folder: FolderInfo
    public let depth: Int
    public let name: String
    public var id: Int64 { folder.id }
}

/// The pure list logic behind the M2.5 pickers: "Verschieben" (`V`), "Label"
/// (`L`), Textbausteine (`⌘;`) and "Split nach Absender". Kept out of the views
/// so the ranking and the filtered sets have unit tests.
public enum Pickers {
    /// The folder role a view already shows; moving there would do nothing.
    public static func folderRole(of view: MailView) -> String? {
        switch view {
        case .inbox: return "inbox"
        case .done: return "archive"
        case .sent: return "sent"
        case .drafts: return "drafts"
        case .trash: return "trash"
        case .spam: return "spam"
        default: return nil
        }
    }

    /// M2.9: der Ordnerbaum der Seitenleiste. Die Systemordner (Posteingang,
    /// Gesendet, Entwürfe, Papierkorb, Spam, Archiv) stehen schon als Ansichten
    /// da und fallen weg; der Rest wird nach dem IMAP-Trenner eingerückt.
    public static func folderTree(_ folders: [FolderInfo]) -> [FolderRow] {
        // M2.15a: `all` („Alle E-Mails“) und `snoozed` („Zurückgestellt“)
        // stehen ebenfalls schon als Ansichten da. Im Sandbox-Seed fehlten
        // diese Rollen, deshalb fielen sie hier nicht auf; in echten Konten
        // wären „Alle E-Mails“ doppelt in der Liste gelandet.
        let system: Set<String> = ["inbox", "archive", "sent", "drafts", "trash", "spam", "all", "snoozed"]
        var rows: [FolderRow] = []
        for folder in folders {
            if let role = folder.role, system.contains(role) { continue }
            var name = folder.imapName
            if name.hasPrefix("[Gmail]/") { name = String(name.dropFirst(8)) }
            let separator = folder.delimiter?.first ?? "/"
            let depth = max(0, name.split(separator: separator).count - 1)
            rows.append(FolderRow(folder: folder, depth: depth, name: String(name.split(separator: separator).last ?? Substring(name))))
        }
        return rows
    }

    /// IMAP name without the Gmail prefix, as Tauri shows it.
    public static func folderName(_ folder: FolderInfo) -> String {
        var name = folder.imapName
        if name.hasPrefix("[Gmail]/") { name = String(name.dropFirst(8)) }
        let separator = folder.delimiter?.first ?? "/"
        return String(name.split(separator: separator).last ?? Substring(name))
    }

    /// Candidates for "Verschieben": no drafts, nothing the current view already
    /// shows, best match first when a query is typed.
    public static func moveCandidates(_ folders: [FolderInfo], view: MailView, query: String) -> [FolderInfo] {
        let current = folderRole(of: view)
        let usable = folders.filter { $0.role != "drafts" && (current == nil || $0.role != current) }
        return rank(usable, query: query, name: folderName)
    }

    /// Labels for "Label": the whole list, best match first when a query is typed.
    public static func labelCandidates(_ labels: [Label], query: String) -> [Label] {
        rank(labels, query: query) { $0.name }
    }

    public static func snippetCandidates(_ snippets: [Snippet], query: String) -> [Snippet] {
        rank(snippets, query: query) { $0.name }
    }

    /// Sorted by score above 0.01 (Tauri's threshold), original order on ties.
    static func rank<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        var scored: [(offset: Int, item: T, score: Double)] = []
        scored.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let value = CommandScore.score(name(item), trimmed)
            if value > 0.01 { scored.append((offset: offset, item: item, score: value)) }
        }
        scored.sort { left, right in
            if left.score == right.score { return left.offset < right.offset }
            return left.score > right.score
        }
        return scored.map(\.item)
    }

    /// `domainSplitPrefill` in `src/lib/splitPrefill.ts`: the editable defaults
    /// for a whole-domain split ("@acme.com"), or nil when the address has no
    /// usable domain part.
    public static func domainSplit(for email: String) -> (name: String, domain: String, sender: String)? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = address.lastIndex(of: "@"), at != address.startIndex else { return nil }
        let domain = String(address[address.index(after: at)...])
        guard !domain.isEmpty, !domain.contains("..") else { return nil }
        let allowed = domain.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        guard allowed, !domain.hasPrefix("."), !domain.hasSuffix(".") else { return nil }
        for suffix in [".com", ".org", ".net", ".io", ".dev"] where domain.hasSuffix(suffix) {
            let stem = String(domain.dropLast(suffix.count))
            if !stem.isEmpty { return (stem, domain, "@" + domain) }
        }
        return (domain, domain, "@" + domain)
    }
}
