import XCTest
@testable import Rabe
@testable import RabeKit

/// Teil A der Titelleisten-Arbeit: Das Glas-Theme ist entfernt. Geprüft wird
/// die reine Migration der gespeicherten Einstellung und dass die drei übrigen
/// Themes weiter auflösen wie vorher.
final class ThemeTests: XCTestCase {

    // MARK: Migration der gespeicherten Einstellung

    /// `snow` war das Glas-Theme. Ein gespeicherter Wert darf keine leere
    /// Auswahl und keinen Absturz ergeben.
    func testGlassBecomesSystem() {
        XCTAssertEqual(ThemeID.migrated(from: "snow"), .system)
        XCTAssertEqual(ThemeID.migrated(from: "SNOW"), .system)
    }

    func testUnknownValuesBecomeSystem() {
        for stored in ["", "glas", "glass", "paper-ish", "42"] {
            XCTAssertEqual(ThemeID.migrated(from: stored), .system, stored)
        }
    }

    func testKnownValuesStay() {
        XCTAssertEqual(ThemeID.migrated(from: "system"), .system)
        XCTAssertEqual(ThemeID.migrated(from: "paper"), .paper)
        XCTAssertEqual(ThemeID.migrated(from: "carbon"), .carbon)
    }

    // MARK: Die drei Themes

    func testOnlyThreeThemesRemain() {
        XCTAssertEqual(ThemeID.allCases.map(\.rawValue), ["system", "paper", "carbon"])
        XCTAssertNil(ThemeID(rawValue: "snow"))
    }

    func testTitlesNameTheTheme() {
        XCTAssertEqual(ThemeID.system.title, "System")
        XCTAssertEqual(ThemeID.paper.title, "Hell (Papier)")
        XCTAssertEqual(ThemeID.carbon.title, "Dunkel (Graphit)")
    }

    // MARK: Auflösung

    /// `system` löst nach der Erscheinung auf, liefert aber nie `system` zurück.
    func testSystemFollowsTheAppearance() {
        let light = Theme.resolve(.system, systemDark: false, accentKey: "violet")
        let dark = Theme.resolve(.system, systemDark: true, accentKey: "violet")
        XCTAssertEqual(light.id, .paper)
        XCTAssertEqual(dark.id, .carbon)
        XCTAssertFalse(light.isDark)
        XCTAssertTrue(dark.isDark)
    }

    func testTheFixedThemesIgnoreTheAppearance() {
        XCTAssertEqual(Theme.resolve(.paper, systemDark: true, accentKey: "violet").id, .paper)
        XCTAssertEqual(Theme.resolve(.carbon, systemDark: false, accentKey: "violet").id, .carbon)
    }

    /// Die Seitenleiste bleibt je Theme eine Spur anders als das Fenster.
    func testSidebarSurfaceStaysPerTheme() {
        XCTAssertEqual(Theme.paper.side, RGBA.hex(0xf1eee8))
        XCTAssertEqual(Theme.graphite.side, RGBA.hex(0x141417))
    }

    /// Die Akzentfarbe aus den Einstellungen gewinnt weiterhin, ohne das Theme
    /// zu wechseln.
    func testAccentReplacesTheThemeAccent() {
        let custom = Theme.resolve(.paper, systemDark: false, accentKey: "blue")
        XCTAssertEqual(custom.id, .paper)
        XCTAssertEqual(custom.accent, RGBA.hex(0x2f6bd0))
        XCTAssertNotEqual(custom.accent, Theme.paper.accent)
    }

    func testThemeDefaultAccentStays() {
        let untouched = Theme.resolve(.carbon, systemDark: false, accentKey: "violet")
        XCTAssertEqual(untouched.accent, Theme.graphite.accent)
    }
}
