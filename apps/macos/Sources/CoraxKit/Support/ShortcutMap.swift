import Foundation

/// M2.14: die eine Tabelle hinter Tastenauswertung, Kürzelhilfe und `TASTATUR.md`.
///
/// Zwei Schichten: `singles` sind Einzeltasten (nur außerhalb von Textfeldern,
/// abschaltbar über `singleKeyShortcuts`), `combos` sind Menü-Kombis und gelten
/// immer. Verglichen wird das erzeugte Zeichen, nicht der Tastencode.
public struct Shortcut: Identifiable, Hashable, Sendable {
    public enum Context: String, CaseIterable, Sendable {
        case list, listThread, thread, global, ai, draft, panel, editor, calendar

        public var title: String {
            switch self {
            case .list: "Liste"
            case .listThread: "Liste und offener Thread"
            case .thread: "Offener Thread"
            case .global: "Überall"
            case .ai: "KI"
            case .draft: "Entwurf"
            case .panel: "Verfassen-Panel"
            case .editor: "Editor"
            case .calendar: "Kalender"
            }
        }
    }

    public let context: Context
    public let action: String
    /// Einzeltasten; verglichen wird das Zeichen (Großbuchstabe bei `⇧`).
    public let singles: [String]
    /// Menü-Kombis in Anzeigeform (`⇧⌘R`).
    public let combos: [String]

    public var id: String { "\(context.rawValue):\(action)" }

    public init(_ context: Context, _ action: String, singles: [String] = [], combos: [String] = []) {
        self.context = context
        self.action = action
        self.singles = singles
        self.combos = combos
    }
}

/// Die vom Nutzer abgenommene Belegung (BRIEFING-M2.14 §6). Reihenfolge und
/// Wortlaut sind maßgeblich für Kürzelhilfe und `TASTATUR.md`.
public enum ShortcutMap {
    public static let all: [Shortcut] = [
        // Liste
        Shortcut(.list, "nächster / voriger Thread", singles: ["J", "K"], combos: ["↓", "↑"]),
        Shortcut(.list, "Seite weiter / zurück", combos: ["Bild↓", "Bild↑"]),
        Shortcut(.list, "erster / letzter Thread", combos: ["Pos1", "Ende"]),
        Shortcut(.list, "Thread aufklappen", singles: ["O"], combos: ["↵"]),
        Shortcut(.list, "Auswahl erweitern", combos: ["⇧↓", "⇧↑"]),
        Shortcut(.list, "alles auswählen / aufheben", singles: ["A"], combos: ["⌘A"]),
        Shortcut(.list, "Zeile zur Auswahl", singles: ["X"], combos: ["⌘-Klick"]),
        Shortcut(.list, "Split wechseln", singles: ["Tab", "⇧Tab"], combos: ["⌃Tab", "⌃⇧Tab"]),
        Shortcut(.list, "direkt zu Split n", combos: ["⌥⌘1…9"]),
        // Liste und offener Thread
        Shortcut(.listThread, "Erledigt", singles: ["E"], combos: ["⌃⌘A"]),
        Shortcut(.listThread, "zurück in den Posteingang", singles: ["⇧E"], combos: ["⇧⌃⌘A"]),
        Shortcut(.listThread, "Papierkorb", singles: ["#"], combos: ["⌫", "⌘⌫"]),
        Shortcut(.listThread, "Später (morgen 8:00)", singles: ["H"], combos: ["⌃⌘H"]),
        Shortcut(.listThread, "Stern", singles: ["S"], combos: ["⇧⌘L"]),
        Shortcut(.listThread, "gelesen / ungelesen", singles: ["U"], combos: ["⇧⌘U"]),
        Shortcut(.listThread, "Spam / kein Spam", singles: ["!"], combos: ["⇧⌘J"]),
        Shortcut(.listThread, "Rückgängig", singles: ["Z"], combos: ["⌘Z"]),
        Shortcut(.listThread, "Verschieben …", singles: ["V"], combos: ["⌃⌘M"]),
        Shortcut(.listThread, "Label …", singles: ["L"], combos: ["⌃⌘L"]),
        Shortcut(.listThread, "Newsletter abmelden", combos: ["⌃⌘U"]),
        Shortcut(.listThread, "Antworten", singles: ["R"], combos: ["⌘R"]),
        Shortcut(.listThread, "Allen antworten", singles: ["⇧R"], combos: ["⇧⌘R"]),
        Shortcut(.listThread, "Weiterleiten", singles: ["F"], combos: ["⇧⌘F"]),
        // Offener Thread
        Shortcut(.thread, "in der Nachricht weiter / zurück", singles: ["J", "K"], combos: ["↓", "↑"]),
        Shortcut(.thread, "seitenweise", singles: ["Space", "⇧Space"], combos: ["Bild↓", "Bild↑"]),
        Shortcut(.thread, "erste / letzte Nachricht", combos: ["Pos1", "Ende"]),
        Shortcut(.thread, "zuklappen", combos: ["↵", "Esc"]),
        Shortcut(.thread, "ersten Anhang öffnen", singles: ["O"], combos: ["⌘↓"]),
        Shortcut(.thread, "Quick Look", singles: ["Y"], combos: ["⌘Y"]),
        Shortcut(.thread, "Bilder laden", combos: ["⇧⌘I"]),
        // Überall
        Shortcut(.global, "Neue Mail", singles: ["C"], combos: ["⌘N"]),
        Shortcut(.global, "Jetzt synchronisieren", combos: ["⇧⌘N"]),
        Shortcut(.global, "Bestätigungscode kopieren", combos: ["⌥⇧⌘C"]),
        Shortcut(.global, "Gehe zu Postfach I S D T E H # ! A", singles: ["G"], combos: ["⌘1…⌘9"]),
        // M2.18m: `G` `O` als zweiter Buchstabe der Folge (deshalb keine eigene
        // Einzeltaste — `G` ist oben schon belegt). Die Ziele stehen auch in
        // der Befehlspalette.
        Shortcut(.global, "Gehe zu Ordner/Label … (G O)", combos: ["⇧⌘O"]),
        Shortcut(.global, "Konto 1…9 / alle", combos: ["⌃1…⌃9", "⌃0"]),
        Shortcut(.global, "Seitenleiste", singles: ["\\"], combos: ["⌃⌘S"]),
        Shortcut(.global, "Suche", singles: ["/"], combos: ["⌥⌘F", "⌘F"]),
        Shortcut(.global, "Befehlspalette", combos: ["⌘K"]),
        Shortcut(.global, "Kürzelhilfe", singles: ["?"], combos: ["⌘/"]),
        Shortcut(.global, "Einstellungen · Leistung · Beenden", combos: ["⌘,", "⌥⌘P", "⌘Q"]),
        // KI
        Shortcut(.ai, "Zusammenfassen / mit KI schreiben", singles: ["I"], combos: ["⌥⌘I"]),
        Shortcut(.ai, "Fragen an das Postfach", singles: ["⇧I"], combos: ["⇧⌥⌘I"]),
        Shortcut(.ai, "Korrekturlesen (im Entwurf)", combos: ["⌥⌘;"]),
        Shortcut(.ai, "KI-Filter (in der Suche)", combos: ["⌥⌘K"]),
        // Entwurf
        Shortcut(.draft, "Senden", combos: ["⇧⌘D", "⌘↵"]),
        Shortcut(.draft, "Senden und erledigen", combos: ["⌥⇧⌘D", "⌘⇧↵"]),
        Shortcut(.draft, "Später senden …", combos: ["⌃⌘D"]),
        Shortcut(.draft, "Sofort senden", combos: ["⌃⌥⌘D"]),
        Shortcut(.draft, "Anhängen …", combos: ["⇧⌘A"]),
        Shortcut(.draft, "Textbaustein …", combos: ["⌃⌘K"]),
        Shortcut(.draft, "verwerfen (im Thread)", combos: ["⇧⌘⌫"]),
        // Panel
        Shortcut(.panel, "minimieren", combos: ["Esc"]),
        Shortcut(.panel, "verwerfen", combos: ["⇧⌘⌫"]),
        Shortcut(.panel, "minimieren / wiederherstellen", combos: ["⇧⌘M"]),
        Shortcut(.panel, "Fokus reihum Liste ↔ Entwürfe", combos: ["⌃Tab"]),
        // Editor
        Shortcut(.editor, "fett · kursiv · unterstrichen · durchgestrichen", combos: ["⌘B", "⌘I", "⌘U", "⇧⌘X"]),
        Shortcut(.editor, "nummerierte Liste · Aufzählung · Zitat", combos: ["⇧⌘7", "⇧⌘8", "⌘'"]),
        Shortcut(.editor, "Link · Formatierung entfernen · Kontakt", combos: ["⌘K", "⌘\\", "@"]),
        // Kalender
        Shortcut(.calendar, "Kalender öffnen / zurück zur Post", combos: ["⌥⌘2", "⌥⌘1"]),
        Shortcut(.calendar, "Tag / Woche / Monat", singles: ["D", "W", "M"], combos: ["⌘1", "⌘2", "⌘3"]),
        // Für M2.13 reserviert: Jahresansicht und Terminliste.
        Shortcut(.calendar, "Jahr", singles: ["Y"], combos: ["⌘4"]),
        Shortcut(.calendar, "Terminliste", singles: ["L"], combos: ["⌘5"]),
        Shortcut(.calendar, "Heute", singles: ["T"], combos: ["⌘T"]),
        Shortcut(.calendar, "zurück / weiter blättern", singles: ["-", "+", "="], combos: ["⌘←", "⌘→"]),
        Shortcut(.calendar, "Neuer Termin", singles: ["B"], combos: ["⌘N"]),
        Shortcut(.calendar, "voriger / nächster Termin", singles: ["Tab", "⇧Tab"], combos: ["↑", "↓"]),
        Shortcut(.calendar, "Termin aufklappen / zuklappen", combos: ["↵"]),
        Shortcut(.calendar, "Termin bearbeiten", combos: ["⌘E"]),
        Shortcut(.calendar, "Termin sichern (im Titelfeld ↵)", combos: ["⌘↵"]),
        Shortcut(.calendar, "schrittweise zurück", combos: ["Esc"]),
        Shortcut(.calendar, "Meeting beitreten", singles: ["O"], combos: ["⌘O"]),
        Shortcut(.calendar, "Termin löschen", combos: ["⌫"]),
    ]

    /// Abschnitte für die Kürzelhilfe, in fester Reihenfolge.
    public static var sections: [(Shortcut.Context, [Shortcut])] {
        Shortcut.Context.allCases.compactMap { context in
            let rows = all.filter { $0.context == context }
            return rows.isEmpty ? nil : (context, rows)
        }
    }

    /// Eine Zeile der Kürzelhilfe, z. B. "R · ⌘R". Einzeltasten stehen vorn,
    /// die Kombis dahinter; die Hilfe erklärt den Unterschied im Kopf.
    public static func keys(_ shortcut: Shortcut) -> String {
        (shortcut.singles + shortcut.combos).joined(separator: " · ")
    }

    /// Die Markdown-Zeile, die `TASTATUR.md` enthalten muss.
    public static func markdownRow(_ shortcut: Shortcut) -> String {
        let single = shortcut.singles.isEmpty ? "—" : shortcut.singles.map { "`\($0)`" }.joined(separator: " / ")
        let combo = shortcut.combos.isEmpty ? "—" : shortcut.combos.map { "`\($0)`" }.joined(separator: " / ")
        return "| \(shortcut.action) | \(single) | \(combo) |"
    }

    /// Alle Tabellenzeilen der Doku, nach Kontext gruppiert.
    public static func markdownRows(for context: Shortcut.Context) -> [String] {
        all.filter { $0.context == context }.map(markdownRow)
    }
}
