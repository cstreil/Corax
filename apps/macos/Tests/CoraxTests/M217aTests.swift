import XCTest
@testable import Corax

/// M2.17: Bei schmalem Fenster weichen die fünf Ansichtsknöpfe einem Popup.
/// Teil B: die Grenze gilt jetzt für die Breite, die den Items der
/// Werkzeugleiste bleibt (Fenster minus Seitenleiste, Ampel und Suchfeld).
@MainActor
final class M217aTests: XCTestCase {

    func testModePickerNeedsTheFullRowWidth() {
        // Genau an der Grenze und darüber: Segment.
        XCTAssertTrue(WindowToolbar.showsModePicker(inRowWidth: WindowToolbar.modePickerMinRowWidth))
        XCTAssertTrue(WindowToolbar.showsModePicker(inRowWidth: 900))
        // Ein Punkt darunter: Popup.
        XCTAssertFalse(WindowToolbar.showsModePicker(inRowWidth: WindowToolbar.modePickerMinRowWidth - 1))
        XCTAssertFalse(WindowToolbar.showsModePicker(inRowWidth: 420))
    }

    func testMailTabsYieldBeforeTheyTruncate() {
        // Breite Zeile: Tabs.
        XCTAssertTrue(WindowToolbar.showsTabs(inRowWidth: 886))
        XCTAssertTrue(WindowToolbar.showsTabs(inRowWidth: WindowToolbar.tabsMinRowWidth))
        // 837-pt-Fenster: 534 pt Zeile — dort blieben nur 146 pt frei, also
        // keine Tabs (nachgemessen im Sandbox-Lauf).
        XCTAssertFalse(WindowToolbar.showsTabs(inRowWidth: 534))
        XCTAssertFalse(WindowToolbar.showsTabs(inRowWidth: 590))
    }
}
