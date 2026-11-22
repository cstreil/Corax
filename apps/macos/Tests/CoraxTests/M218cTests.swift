import XCTest
@testable import Corax
@testable import CoraxKit

/// Teil B: Die Breite, die den Items der Werkzeugleiste bleibt, entscheidet über
/// Tabs und Ansichtswahl. Ampel und Suchfeld malt AppKit beziehungsweise
/// SwiftUI; beide Plätze werden abgezogen, damit die Grenzen aus M2.17 weiter
/// für den tatsächlich verfügbaren Platz gelten.
@MainActor
final class M218cTests: XCTestCase {

    func testRowWidthSubtractsSystemChromeOnly() {
        // Die Leiste liegt über dem ganzen Fenster: nur Ampel (103) und
        // Suchfeld (200) gehen ab, die Seitenleiste beginnt darunter.
        XCTAssertEqual(WindowToolbar.rowWidth(windowWidth: 1118), 815)
        XCTAssertEqual(WindowToolbar.rowWidth(windowWidth: 950), 647)
        XCTAssertEqual(WindowToolbar.rowWidth(windowWidth: 837), 534)
    }

    func testRowWidthNeverGoesNegative() {
        // Schmaler als die Systemflächen: keine negative Breite, die eine
        // Entscheidung umdrehen würde.
        XCTAssertEqual(WindowToolbar.rowWidth(windowWidth: 200), 0)
        XCTAssertEqual(WindowToolbar.rowWidth(windowWidth: 0), 0)
    }

    func testM217ThresholdsStillHoldOnTheRowWidth() {
        // Die Grenzen aus M2.17 gelten weiter für die **Zeilenbreite**.
        XCTAssertTrue(WindowToolbar.showsTabs(inRowWidth: WindowToolbar.tabsMinRowWidth))
        XCTAssertFalse(WindowToolbar.showsTabs(inRowWidth: WindowToolbar.tabsMinRowWidth - 1))
        XCTAssertTrue(WindowToolbar.showsModePicker(inRowWidth: WindowToolbar.modePickerMinRowWidth))
        XCTAssertFalse(WindowToolbar.showsModePicker(inRowWidth: WindowToolbar.modePickerMinRowWidth - 1))
        // 950-pt-Fenster: 647 pt Zeile — über der Tab-Grenze, unter der Grenze
        // für die Kalender-Ansichtswahl.
        XCTAssertTrue(WindowToolbar.showsTabs(inRowWidth: WindowToolbar.rowWidth(windowWidth: 950)))
        XCTAssertFalse(WindowToolbar.showsModePicker(inRowWidth: WindowToolbar.rowWidth(windowWidth: 950)))
    }
}
