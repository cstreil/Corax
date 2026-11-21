import Foundation

/// M2.18n: wie Labels in Liste und Mail erscheinen — eine Regel für beide.
///
/// Automatische Kategorien (Marketing, News, Social …) sind echte Labels des
/// Kerns, wurden aber in Liste und Mail ausgeblendet. In der echten Instanz
/// stehen vier Labels, drei davon automatisch — sichtbar blieb also fast
/// nichts. Jetzt erscheinen beide Arten: **eigene zuerst** (Position, dann
/// Name), automatische danach, und ein Funkeln kennzeichnet die automatischen.
public enum MailLabelDisplay {
    /// Die Labels eines Threads in Anzeigereihenfolge; unbekannte Kennungen
    /// fallen weg, doppelte zählen einmal.
    public static func ordered(ids: [Int64], labels: [Int64: Label]) -> [Label] {
        var seen = Set<Int64>()
        let found = ids.compactMap { id -> Label? in
            guard let label = labels[id], seen.insert(id).inserted else { return nil }
            return label
        }
        return sorted(found)
    }

    /// Eigene Labels vor automatischen, innerhalb jeder Gruppe nach Position,
    /// dann Name (ohne Groß/Klein), zuletzt die Kennung — die Reihenfolge ist
    /// damit auch bei gleichen Namen stabil.
    public static func sorted(_ labels: [Label]) -> [Label] {
        labels.sorted { lhs, rhs in
            let leftAuto = lhs.isAuto == true
            let rightAuto = rhs.isAuto == true
            if leftAuto != rightAuto { return !leftAuto }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// Das Kürzel einer Listenzeile: das erste Label und wie viele weitere es
    /// gibt. Mehr passen nicht in die Zeile, ohne den Betreff zu verdrängen.
    public struct Badge: Equatable, Sendable {
        public let name: String
        public let colorHex: String
        /// Automatische Kategorie — die Zeile setzt davor ein Funkeln.
        public let isAuto: Bool
        public let more: Int

        public init(name: String, colorHex: String, isAuto: Bool, more: Int) {
            self.name = name
            self.colorHex = colorHex
            self.isAuto = isAuto
            self.more = more
        }

        /// Was in der Kapsel steht.
        public var text: String { more > 0 ? "\(name) +\(more)" : name }
    }

    public static func badge(ids: [Int64], labels: [Int64: Label]) -> Badge? {
        let list = ordered(ids: ids, labels: labels)
        guard let first = list.first else { return nil }
        return Badge(name: first.name,
                     colorHex: first.color,
                     isAuto: first.isAuto == true,
                     more: list.count - 1)
    }
}
