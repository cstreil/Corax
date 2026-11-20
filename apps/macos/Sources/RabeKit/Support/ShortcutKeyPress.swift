import Foundation

/// M2.14b: eine gedrückte Kombi, so wie AppKit sie liefert.
///
/// SwiftUI legt Satzzeichen-Kombis in der Menüleiste physisch aus: aus `⌘/`
/// wurde auf deutscher Tastatur `⌘ß`, aus `⌥⌘;` wurde `⌥⌘ü`. Der Monitor
/// vergleicht deshalb das Zeichen der gedrückten Taste statt der Menü-Kennung.
public struct KeyPress: Sendable, Equatable {
    /// Die Zeichen mit allen Modifikatoren — `\` entsteht auf deutscher
    /// Tastatur aus `⌥⇧7`, `'` aus `⇧#`.
    public let characters: String
    /// Die Zeichen ohne ⌘ und ⌥, aber mit ⇧ — `;` aus `⇧,`.
    public let charactersIgnoringModifiers: String
    public let command: Bool
    public let option: Bool
    public let control: Bool
    public let shift: Bool

    public init(characters: String,
                charactersIgnoringModifiers: String? = nil,
                command: Bool = false,
                option: Bool = false,
                control: Bool = false,
                shift: Bool = false) {
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }
}

/// Eine Kombi der Tabelle, in Modifikatoren und Taste zerlegt.
public struct ShortcutChord: Sendable, Equatable {
    public let control: Bool
    public let option: Bool
    public let shift: Bool
    public let command: Bool
    /// Die Taste selbst, z. B. `/`, `;` oder `⌫`.
    public let symbol: String

    /// Nur echte Zeichen lassen sich am Zeichen erkennen; `⌫`, `↵`, `Bild↓`
    /// und `⌥⌘1…9` gehören der Menüleiste.
    public var isCharacter: Bool { symbol.count == 1 }
}

public extension ShortcutMap {
    /// `⌥⌘;` → ⌥+⌘ mit `;`.
    static func chord(_ combo: String) -> ShortcutChord {
        var control = false, option = false, shift = false, command = false
        var rest = Substring(combo)
        symbols: while let first = rest.first {
            switch first {
            case "⌃": control = true
            case "⌥": option = true
            case "⇧": shift = true
            case "⌘": command = true
            default: break symbols
            }
            rest = rest.dropFirst()
        }
        return ShortcutChord(control: control, option: option, shift: shift,
                             command: command, symbol: String(rest))
    }

    /// Trifft die gedrückte Kombi diese Zeile?
    ///
    /// ⇧ und ein ⌥, das die Tastatur zum Erzeugen des Zeichens braucht, sind
    /// keine Bedingung: `⌘\` ist auf deutscher Tastatur `⌘⌥⇧7`, `⌥⌘;` ist
    /// `⌥⌘⇧,`, `⌘/` ist `⌘⇧7`. ⌘ und ⌃ müssen genau passen; eine Kombi, die
    /// selbst ⌥ verlangt, braucht ⌥.
    static func matches(_ combo: String, _ press: KeyPress) -> Bool {
        let chord = chord(combo)
        guard chord.isCharacter else { return false }
        guard press.command == chord.command, press.control == chord.control else { return false }
        if chord.option, !press.option { return false }
        return press.characters == chord.symbol
            || press.charactersIgnoringModifiers == chord.symbol
    }

    /// Die Zeilen dieser Kontexte, deren Kombi trifft — in Tabellenreihenfolge.
    static func shortcuts(matching press: KeyPress, in contexts: Set<Shortcut.Context>) -> [Shortcut] {
        all.filter { contexts.contains($0.context) && $0.combos.contains { matches($0, press) } }
    }

    /// Alle Kombis, deren Taste auf einer anderen Tastatur ein anderes Zeichen
    /// erzeugt, als die Menüleiste annimmt (M2.14b): Satzzeichen, und Ziffern
    /// mit ⇧ — auf deutscher Tastatur wird aus `⇧7` ein `/`.
    static var punctuationCombos: [(Shortcut, String)] {
        all.flatMap { shortcut -> [(Shortcut, String)] in
            shortcut.combos.compactMap { combo -> (Shortcut, String)? in
                let chord = chord(combo)
                guard chord.isCharacter, let first = chord.symbol.first else { return nil }
                if first.isLetter { return nil }
                if first.isNumber, !chord.shift { return nil }
                return (shortcut, combo)
            }
        }
    }
}
