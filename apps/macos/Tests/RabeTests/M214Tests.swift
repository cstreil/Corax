import XCTest
@testable import RabeKit

/// M2.14: eine Tabelle speist Tastenauswertung, Kürzelhilfe und `TASTATUR.md`.
final class M214Tests: XCTestCase {
    func testNoSingleKeyIsBoundTwiceInOneContext() {
        for context in Shortcut.Context.allCases {
            var seen: [String: String] = [:]
            for shortcut in ShortcutMap.all where shortcut.context == context {
                for key in shortcut.singles {
                    if let other = seen[key] {
                        XCTFail("\(context.title): \(key) doppelt — „\(other)“ und „\(shortcut.action)“")
                    }
                    seen[key] = shortcut.action
                }
            }
        }
    }

    func testNoComboIsBoundTwiceInOneContext() {
        for context in Shortcut.Context.allCases {
            var seen: [String: String] = [:]
            for shortcut in ShortcutMap.all where shortcut.context == context {
                for key in shortcut.combos {
                    if let other = seen[key] {
                        XCTFail("\(context.title): \(key) doppelt — „\(other)“ und „\(shortcut.action)“")
                    }
                    seen[key] = shortcut.action
                }
            }
        }
    }

    func testEveryShortcutHasABinding() {
        for shortcut in ShortcutMap.all {
            XCTAssertFalse(shortcut.singles.isEmpty && shortcut.combos.isEmpty,
                           "„\(shortcut.action)“ hat keine Belegung")
        }
    }

    func testEveryContextHasRows() {
        for context in Shortcut.Context.allCases {
            XCTAssertTrue(ShortcutMap.all.contains { $0.context == context },
                          "\(context.title) ist leer")
        }
    }

    func testTheSheetShowsEveryRow() {
        let shown = ShortcutMap.sections.flatMap(\.1).count
        XCTAssertEqual(shown, ShortcutMap.all.count)
    }

    /// `TASTATUR.md` und die Kürzelhilfe kommen aus derselben Tabelle; die Doku
    /// muss jede Zeile wörtlich enthalten (BRIEFING-M2.14 §7).
    func testTheDocumentationMatchesTheTable() throws {
        let url = try ContractFile.repositoryFile("docs/native-ui/TASTATUR.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        for shortcut in ShortcutMap.all {
            XCTAssertTrue(text.contains(ShortcutMap.markdownRow(shortcut)),
                          "TASTATUR.md fehlt: \(ShortcutMap.markdownRow(shortcut))")
        }
    }

    func testGermanCharactersAreSingleKeys() {
        // Auf deutscher Tastatur liegen sie auf anderen Tasten; verglichen wird
        // das Zeichen, nicht der keyCode.
        let keys = Set(ShortcutMap.all.flatMap(\.singles))
        for key in ["/", "?", "#", "!", "+", "-", "\\", "="] {
            XCTAssertTrue(keys.contains(key), "\(key) fehlt")
        }
    }
}
