import Foundation

/// M2.18m: ein Ziel für „Gehe zu Ordner/Label …“ (`G` `O`) — und dieselben
/// Einträge in der Befehlspalette (`⌘K`).
///
/// Zwischenknoten des Ordnerbaums (Elternordner, die der Server nicht liefert)
/// tauchen hier **nicht** auf: sie sind nicht wählbar, und eine Aktion darf
/// niemals auf ihnen landen.
public struct GoToEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case folder, label
    }

    public let kind: Kind
    public let targetId: Int64
    /// Anzeigename: der Ordnername bzw. der Labelname.
    public let title: String
    /// Voller Ordnerpfad, z. B. „Projekte / Website“ (`nil` bei Labels).
    public let path: String?
    /// Kontoname — nur, wenn es mehr als ein Konto gibt.
    public let account: String?
    /// Was die Suche durchsucht: Name, Pfad und Konto.
    public let searchText: String

    public var id: String { "\(kind.rawValue)|\(targetId)" }

    /// Die Zeile unter dem Namen: Pfad, sonst das Konto.
    public var detail: String? {
        if let path, path != title { return path }
        return account
    }
}

public enum GoToEntries {
    /// Ordner und Labels als Ziele, in fester Reihenfolge: erst Ordner nach
    /// Pfad, dann Labels nach Namen.
    ///
    /// - Systemordner und automatische Labels fallen weg (sie stehen schon als
    ///   Ansichten da bzw. sind keine eigene Wahl),
    /// - Zwischenknoten ohne echten Ordner fallen weg,
    /// - `accounts` liefert den Kontonamen; gezeigt wird er nur bei mehreren.
    public static func make(folders: [FolderInfo], labels: [Label],
                            accounts: [Int64: String] = [:],
                            showsAccount: Bool = false) -> [GoToEntry] {
        var folderEntries: [(path: String, entry: GoToEntry)] = []
        for row in Pickers.folderTree(folders) where row.isSelectable {
            let account = showsAccount ? accounts[row.folder.accountId] : nil
            let search = [row.name, row.displayPath, account ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let entry = GoToEntry(kind: .folder, targetId: row.folder.id,
                                  title: row.name, path: row.displayPath,
                                  account: account, searchText: search)
            folderEntries.append((row.displayPath, entry))
        }
        folderEntries.sort {
            let cmp = $0.path.localizedCaseInsensitiveCompare($1.path)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.entry.targetId < $1.entry.targetId
        }
        var entries = folderEntries.map(\.entry)
        entries += labels
            .filter { !($0.isAuto ?? false) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { GoToEntry(kind: .label, targetId: $0.id, title: $0.name,
                             path: nil, account: nil, searchText: $0.name) }
        return entries
    }

    /// Suche über Name, Pfad und Konto. Leere Eingabe zeigt alles; ein Treffer
    /// am Namensanfang steht vor einem Treffer mitten im Wort.
    public static func matches(_ entries: [GoToEntry], query: String) -> [GoToEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        // Erst ein einfaches „enthält“ (wie die Befehlspalette), dann die
        // Reihenfolge über `CommandScore` und den Bonus für den Namensanfang.
        let needle = trimmed.lowercased()
        var scored: [(offset: Int, entry: GoToEntry, score: Double)] = []
        for (offset, entry) in entries.enumerated() {
            guard entry.searchText.lowercased().contains(needle) else { continue }
            let bonus = entry.title.lowercased().hasPrefix(needle) ? 1.0 : 0
            scored.append((offset, entry, CommandScore.score(entry.searchText, trimmed) + bonus))
        }
        scored.sort {
            if $0.score == $1.score { return $0.offset < $1.offset }
            return $0.score > $1.score
        }
        return scored.map(\.entry)
    }

    /// Die gewählte Zeile nach `↑`/`↓` (bleibt in der Liste).
    public static func stepped(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }
}
