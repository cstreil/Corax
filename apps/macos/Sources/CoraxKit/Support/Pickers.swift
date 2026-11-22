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
///
/// M2.18k: Fehlt ein Elternordner in der Serverliste, steht hier ein
/// Zwischenknoten mit negativer Kennung (`isSyntheticParent`). Er ordnet nur
/// seine Kinder ein und ist nicht wählbar.
public struct FolderRow: Identifiable, Hashable {
    public let folder: FolderInfo
    public let depth: Int
    public let name: String
    /// Voller Pfad des Knotens (ohne `INBOX`/`[Gmail]`) — die Identität für
    /// Vergleich und Aufklappzustand.
    public let path: String
    /// Derselbe Pfad lesbar: „Projekte / Rabe“ (M2.18m).
    public let displayPath: String
    public let hasChildren: Bool
    public let isSyntheticParent: Bool
    public var isSelectable: Bool { !isSyntheticParent }
    public var id: Int64 { folder.id }
}

extension FolderInfo {
    /// M2.18k: nur für Zwischenknoten des Baums — ein Elternordner, den der
    /// Server nicht liefert. `id` ist negativ und aus Konto und Pfad gerechnet,
    /// damit sie über Neustarts gleich bleibt (SwiftUI-Identität).
    public init(syntheticParent accountId: Int64, path: String, separator: Character) {
        self.id = FolderRow.syntheticId(accountId: accountId, path: path)
        self.accountId = accountId
        self.imapName = path
        self.delimiter = String(separator)
        self.role = nil
    }
}

extension FolderRow {
    /// Stabile negative Kennung für einen Zwischenknoten (FNV-1a über
    /// Konto und Pfad, dann negativ und im `Int32`-Bereich gehalten).
    static func syntheticId(accountId: Int64, path: String) -> Int64 {
        var hash: UInt32 = 2_166_136_261
        for byte in "\(accountId)|\(path.lowercased())".utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return -(Int64(hash % 2_000_000_000) + 1)
    }
}

/// M2.18k: Aufklappzustand der Ordner, je Konto und Pfad in `UserDefaults`.
/// Wie `SidebarState` bekommt die Sandbox einen eigenen Schlüssel, damit ein
/// Beleglauf den Start der echten App nicht verändert.
public enum FolderDisclosure {
    public static func key(sandbox: Bool) -> String {
        sandbox ? "foldersExpanded.sandbox" : "foldersExpanded"
    }

    public static func identifier(accountId: Int64, path: String) -> String {
        "\(accountId)|\(path.lowercased())"
    }

    public static func load(defaults: UserDefaults = .standard,
                            sandbox: Bool = Instance.isSandbox) -> Set<String> {
        Set(defaults.stringArray(forKey: key(sandbox: sandbox)) ?? [])
    }

    public static func save(_ open: Set<String>, defaults: UserDefaults = .standard,
                            sandbox: Bool = Instance.isSandbox) {
        defaults.set(open.sorted(), forKey: key(sandbox: sandbox))
    }

    /// Beim ersten Start (noch kein Schlüssel) stehen die vorhandenen Ordner
    /// offen: sonst sähe der Baum nach dem Umbau plötzlich nur noch die
    /// Wurzelordner. Danach sind **neue** Ordner eingeklappt, weil ihr Pfad
    /// nicht in der gespeicherten Menge steht. Der erste Stand wird gleich
    /// gespeichert, damit genau diese Grenze gilt.
    public static func loadOrSeed(defaults: UserDefaults = .standard,
                                  sandbox: Bool = Instance.isSandbox,
                                  rows: [FolderRow]) -> Set<String> {
        if defaults.object(forKey: key(sandbox: sandbox)) != nil {
            return load(defaults: defaults, sandbox: sandbox)
        }
        let seeded = Set(rows.filter(\.hasChildren)
            .map { identifier(accountId: $0.folder.accountId, path: $0.path) })
        save(seeded, defaults: defaults, sandbox: sandbox)
        return seeded
    }

    public static func toggle(accountId: Int64, path: String, in open: Set<String>) -> Set<String> {
        var next = open
        let id = identifier(accountId: accountId, path: path)
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        return next
    }

    public static func isOpen(accountId: Int64, path: String,
                              open: Set<String>) -> Bool {
        open.contains(identifier(accountId: accountId, path: path))
    }

    /// Die sichtbaren Zeilen des Baums: Kinder eines zugeklappten Ordners
    /// fallen weg, alles davor und dahinter bleibt.
    public static func visible(_ rows: [FolderRow], open: Set<String>) -> [FolderRow] {
        var visible: [FolderRow] = []
        var hiddenBelow: Int?
        for row in rows {
            if let hidden = hiddenBelow {
                if row.depth > hidden { continue }
                hiddenBelow = nil
            }
            visible.append(row)
            if row.hasChildren, !isOpen(accountId: row.folder.accountId, path: row.path, open: open) {
                hiddenBelow = row.depth
            }
        }
        return visible
    }
}

/// Ein Knoten des Ordnerbaums, nur während `folderTree` gebraucht.
private final class FolderNode {
    let accountId: Int64
    let path: String
    /// Anzeigename; ein echter Ordner korrigiert die Schreibweise eines vorher
    /// angelegten Zwischenknotens („job“ → „Job“).
    var name: String
    let separator: Character
    let parentKey: String?
    var folder: FolderInfo?
    var children: [FolderNode] = []

    var displayPath: String { path.split(separator: separator).joined(separator: " / ") }

    init(accountId: Int64, path: String, name: String, separator: Character,
         parentKey: String?) {
        self.accountId = accountId
        self.path = path
        self.name = name
        self.separator = separator
        self.parentKey = parentKey
    }
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

    /// M2.18k: der Ordnerbaum der Seitenleiste — aus den **vollständigen
    /// Pfaden** je Konto, nicht aus der Reihenfolge der Liste.
    ///
    /// Vorher rechnete der Baum nur die Tiefe aus den Trennern und nahm an, die
    /// Zeile darüber sei der Elternordner. Der Kern liefert die Ordner aber in
    /// Anlagereihenfolge, und `MailboxStore` sortierte die Liste vorher nach
    /// Blattnamen — damit hing fast jedes Kind unter einem fremden Ordner
    /// (M2.18k, echte DB: 27 von 28). Jetzt:
    ///
    /// - der Trenner kommt **je Konto** aus `delimiter`, nie je Ordner geraten,
    /// - `INBOX`/`[Gmail]` fällt als Präfix weg,
    /// - fehlende Eltern werden als nicht wählbare Zwischenknoten ergänzt,
    /// - sortiert wird erst **innerhalb jeder Ebene**, nach Namen und ohne
    ///   Rücksicht auf Groß- und Kleinschreibung.
    public static func folderTree(_ folders: [FolderInfo]) -> [FolderRow] {
        // M2.15a: `all` („Alle E-Mails“) und `snoozed` („Zurückgestellt“)
        // stehen ebenfalls schon als Ansichten da. Im Sandbox-Seed fehlten
        // diese Rollen, deshalb fielen sie hier nicht auf; in echten Konten
        // wären „Alle E-Mails“ doppelt in der Liste gelandet.
        let system: Set<String> = ["inbox", "archive", "sent", "drafts", "trash", "spam", "all", "snoozed"]
        var separators: [Int64: Character] = [:]
        for folder in folders {
            guard let first = folder.delimiter?.first, !first.isWhitespace else { continue }
            if separators[folder.accountId] == nil { separators[folder.accountId] = first }
        }
        func key(_ accountId: Int64, _ path: String) -> String {
            "\(accountId)|\(path.lowercased())"
        }

        var nodes: [String: FolderNode] = [:]
        for folder in folders {
            if let role = folder.role, system.contains(role) { continue }
            let separator = separators[folder.accountId] ?? "/"
            var components = folder.imapName.split(separator: separator).map(String.init)
            // Gmail: „[Gmail]/Gesendet“ → „Gesendet“.
            if let first = components.first, first.caseInsensitiveCompare("[Gmail]") == .orderedSame {
                components.removeFirst()
            }
            // Dovecot/Courier: „INBOX.Ordner“ → „Ordner“ (der Posteingang selbst
            // trägt die Rolle `inbox` und ist hier längst weg).
            if components.count > 1, let first = components.first,
               first.caseInsensitiveCompare("INBOX") == .orderedSame {
                components.removeFirst()
            }
            components.removeAll { $0.isEmpty }
            if components.isEmpty { continue }

            var path = ""
            var parentKey: String?
            for component in components {
                path = path.isEmpty ? component : path + String(separator) + component
                let k = key(folder.accountId, path)
                if nodes[k] == nil {
                    nodes[k] = FolderNode(accountId: folder.accountId, path: path,
                                          name: component, separator: separator,
                                          parentKey: parentKey)
                }
                parentKey = k
            }
            // Ein echter Ordner gewinnt gegen einen vorher angelegten
            // Zwischenknoten (Eltern können in der Liste nach ihren Kindern
            // kommen — der Kern liefert in Anlagereihenfolge).
            let leafKey = key(folder.accountId, path)
            nodes[leafKey]?.folder = folder
            // Der echte Ordner bestimmt die Schreibweise: der Kern kann den
            // Elternordner erst nach seinem Kind liefern (Anlagereihenfolge).
            if let leafName = components.last { nodes[leafKey]?.name = leafName }
        }

        var roots: [FolderNode] = []
        for node in nodes.values {
            if let parentKey = node.parentKey, let parent = nodes[parentKey] {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }

        func ordered(_ list: [FolderNode]) -> [FolderNode] {
            list.sorted { left, right in
                let cmp = left.name.localizedCaseInsensitiveCompare(right.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                if left.accountId != right.accountId { return left.accountId < right.accountId }
                return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
            }
        }

        var rows: [FolderRow] = []
        func emit(_ node: FolderNode, depth: Int) {
            let children = ordered(node.children)
            let folder = node.folder
                ?? FolderInfo(syntheticParent: node.accountId, path: node.path,
                              separator: node.separator)
            rows.append(FolderRow(folder: folder, depth: depth, name: node.name,
                                  path: node.path, displayPath: node.displayPath,
                                  hasChildren: !children.isEmpty,
                                  isSyntheticParent: node.folder == nil))
            for child in children { emit(child, depth: depth + 1) }
        }
        for root in ordered(roots) { emit(root, depth: 0) }
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
