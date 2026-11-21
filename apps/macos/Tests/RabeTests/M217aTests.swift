import XCTest
@testable import Rabe

/// M2.17: Bei schmalem Fenster weichen die fünf Ansichtsknöpfe einem Popup.
final class M217aTests: XCTestCase {

    func testModePickerNeedsTheFullRowWidth() {
        // Genau an der Grenze und darüber: Segment.
        XCTAssertTrue(CalendarChromeRow.showsModePicker(inRowWidth: CalendarChromeRow.modePickerMinRowWidth))
        XCTAssertTrue(CalendarChromeRow.showsModePicker(inRowWidth: 900))
        // Ein Punkt darunter: Popup.
        XCTAssertFalse(CalendarChromeRow.showsModePicker(inRowWidth: CalendarChromeRow.modePickerMinRowWidth - 1))
        XCTAssertFalse(CalendarChromeRow.showsModePicker(inRowWidth: 420))
    }

    func testMailTabsYieldBeforeTheyTruncate() {
        // 1118 pt Fenster mit Seitenleiste: 886 pt Zeile, Tabs passen.
        XCTAssertTrue(MailChromeRow.showsTabs(inRowWidth: 886))
        XCTAssertTrue(MailChromeRow.showsTabs(inRowWidth: MailChromeRow.tabsMinRowWidth))
        // 950 pt Fenster: 718 pt Zeile — „Newsletter" wurde dort abgeschnitten.
        XCTAssertFalse(MailChromeRow.showsTabs(inRowWidth: 718))
    }
}
