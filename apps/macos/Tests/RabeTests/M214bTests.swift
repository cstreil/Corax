import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.14b: Satzzeichen-Kombis werden am Zeichen erkannt, nicht an der
/// physischen Taste. SwiftUI legt für die Menüleiste die US-Position ab;
/// auf deutscher Tastatur liegt `⌘/` dort, wo `ß` steht.
///
/// Die Zeichen unten sind nicht geraten: `UCKeyTranslate` mit der aktuellen
/// Belegung („German“) liefert `/` aus ⇧7, `\` aus ⌥⇧7, `;` aus ⇧,,
/// `'` aus ⇧#, `(` aus ⇧8.
final class M214bTests: XCTestCase {
    /// Deutsche Tastatur: das Zeichen, das entsteht, und was AppKit als
    /// `charactersIgnoringModifiers` daneben liefert.
    private struct GermanKey {
        let characters: String
        let charactersIgnoringModifiers: String
        let shift: Bool
        let option: Bool
    }

    private static let germanKeys: [String: GermanKey] = [
        "/": GermanKey(characters: "/", charactersIgnoringModifiers: "/", shift: true, option: false),
        ";": GermanKey(characters: ";", charactersIgnoringModifiers: ";", shift: true, option: false),
        "'": GermanKey(characters: "'", charactersIgnoringModifiers: "'", shift: true, option: false),
        // ⌥ verändert das Zeichen; charactersIgnoringModifiers ignoriert nur ⌘/⌥.
        "\\": GermanKey(characters: "\\", charactersIgnoringModifiers: "/", shift: true, option: true),
        ";⌥": GermanKey(characters: "˛", charactersIgnoringModifiers: ";", shift: true, option: true),
        "(": GermanKey(characters: "(", charactersIgnoringModifiers: "(", shift: true, option: false),
    ]

    /// Jede Kombi mit Satzzeichen ist mit dem Zeichen erreichbar, das ihre
    /// Taste erzeugt — auf einer Tastatur, auf der das Zeichen ohne ⇧/⌥ steht.
    func testEveryPunctuationComboIsReachableByItsCharacter() {
        XCTAssertFalse(ShortcutMap.punctuationCombos.isEmpty)
        for (shortcut, combo) in ShortcutMap.punctuationCombos {
            let chord = ShortcutMap.chord(combo)
            let press = KeyPress(characters: chord.symbol, command: chord.command,
                                 option: chord.option, control: chord.control, shift: chord.shift)
            XCTAssertTrue(ShortcutMap.matches(combo, press),
                          "\(combo) („\(shortcut.action)“) trifft nicht")
        }
    }

    /// Auf deutscher Tastatur braucht das Zeichen ⇧ oder ⌥; der Treffer darf
    /// nicht davon abhängen, welches Zeichen ⌥ zusätzlich erzeugt.
    func testGermanKeysReachTheirCombos() {
        let cases: [(combo: String, symbol: String)] = [
            ("⌘/", "/"),
            ("⌘'", "'"),
            ("⌘\\", "\\"),
            ("⌥⌘;", ";⌥"),
        ]
        for (combo, symbol) in cases {
            let key = Self.germanKeys[symbol]!
            let chord = ShortcutMap.chord(combo)
            let press = KeyPress(characters: key.characters,
                                 charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                 command: chord.command, option: key.option,
                                 control: chord.control, shift: key.shift)
            XCTAssertTrue(ShortcutMap.matches(combo, press),
                          "\(combo) trifft mit \(key.characters) / \(key.charactersIgnoringModifiers) nicht")
        }
        // ⌥⇧C liefert auf deutscher Tastatur „Ç“; die Kombi verlangt „C“.
        let chord = ShortcutMap.chord("⌥⇧⌘C")
        let press = KeyPress(characters: "Ç", charactersIgnoringModifiers: "C",
                             command: chord.command, option: true, shift: true)
        XCTAssertTrue(ShortcutMap.matches("⌥⇧⌘C", press))
    }

    /// Auf deutscher Tastatur ist `⇧⌘7` genau `⌘/`: beide erzeugen „/“.
    /// Am Zeichen ist die Listen-Kombi deshalb nicht erkennbar, der Editor
    /// entscheidet sie über den keyCode.
    func testGermanShiftCommandSevenTypesSlash() {
        let press = KeyPress(characters: "/", command: true, shift: true)
        XCTAssertTrue(ShortcutMap.matches("⌘/", press))
        XCTAssertFalse(ShortcutMap.matches("⇧⌘7", press),
                       "⇧⌘7 ist auf deutscher Tastatur nicht am Zeichen erkennbar")
        let eight = KeyPress(characters: "(", command: true, shift: true)
        XCTAssertFalse(ShortcutMap.matches("⇧⌘8", eight))
        XCTAssertFalse(ShortcutMap.matches("⌘/", eight))
    }

    /// Ohne ⌘ trifft keine Kombi — sonst würde jedes getippte Satzzeichen
    /// eine Aktion auslösen.
    func testPunctuationWithoutCommandDoesNotMatch() {
        for symbol in ["/", ";", "'", "\\"] {
            XCTAssertFalse(ShortcutMap.matches("⌘\(symbol)", KeyPress(characters: symbol, shift: true)))
            XCTAssertFalse(ShortcutMap.matches("⌥⌘\(symbol)", KeyPress(characters: symbol, option: true, shift: true)))
        }
    }

    /// Die Liste der Satzzeichen-Kombis enthält die vom Briefing genannten.
    func testPunctuationCombosContainTheBriefingRows() {
        let combos = Set(ShortcutMap.punctuationCombos.map(\.1))
        for combo in ["⌘/", "⌥⌘;", "⌘\\", "⌘'", "⇧⌘7", "⇧⌘8", "⌘,"] {
            XCTAssertTrue(combos.contains(combo), "\(combo) fehlt in punctuationCombos")
        }
    }

    /// Der Monitor kennt nur Kombis, die auch in der Tabelle stehen — sonst
    /// laufen Taste und Doku auseinander.
    @MainActor
    func testMonitorBindingsExistInTheTable() {
        for binding in MonitorKeys.bindings {
            let rows = ShortcutMap.all.filter { $0.combos.contains(binding.combo) }
            XCTAssertEqual(rows.count, 1, "\(binding.combo) steht nicht genau einmal in ShortcutMap")
        }
    }

    /// `⌘/` gilt nicht im Textfeld: dort ist dieselbe Kombi `⇧⌘7`
    /// (nummerierte Liste). `⌥⌘;` gilt dagegen gerade im Entwurf.
    @MainActor
    func testMonitorRespectsTextInput() {
        let help = KeyPress(characters: "/", command: true, shift: true)
        XCTAssertEqual(MonitorKeys.handle(help, inText: false), .shortcuts)
        XCTAssertNil(MonitorKeys.handle(help, inText: true))

        let key = Self.germanKeys[";⌥"]!
        let proofread = KeyPress(characters: key.characters,
                                 charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                 command: true, option: true, shift: true)
        XCTAssertEqual(MonitorKeys.handle(proofread, inText: true), .aiProofread)
        XCTAssertEqual(MonitorKeys.handle(proofread, inText: false), .aiProofread)
    }
}
