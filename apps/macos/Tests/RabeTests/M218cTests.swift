import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.18c: Der Seitenleisten-Schalter steht immer in der Werkzeugzeile; bei
/// eingeklappter Leiste rückt die Zeile nur dann um die Ampelzone ein, wenn die
/// Fensterknöpfe wirklich im Band liegen (M2.18c, Nachbesserung).
@MainActor
final class M218cTests: XCTestCase {

    func testLeadIsSidebarOrNothing() {
        // Offen: die Zeile beginnt, wo die Seitenleiste endet — unabhängig von
        // der Ampel, die dann ohnehin in deren Spalte liegt.
        XCTAssertEqual(WindowChromeRow.leadWidth(sidebarVisible: true, lightsInBand: false), SidebarState.width)
        XCTAssertEqual(WindowChromeRow.leadWidth(sidebarVisible: true, lightsInBand: true), SidebarState.width)
        // Zu, Ampel über dem Band (Normalfall): kein Einrücken mehr.
        XCTAssertEqual(WindowChromeRow.leadWidth(sidebarVisible: false, lightsInBand: false), 0)
        // Zu, Ampel im Band (randloses Fenster): Zone bleibt.
        XCTAssertEqual(WindowChromeRow.leadWidth(sidebarVisible: false, lightsInBand: true),
                       WindowChromeRow.trafficLightZone)
    }

    func testRowWidthGrowsWhenTheSidebarCollapses() {
        // 1118 pt Fenster: 886 pt Zeile mit Leiste, ganz ohne Einrückung ohne Leiste.
        XCTAssertEqual(WindowChromeRow.rowWidth(windowWidth: 1118, sidebarVisible: true, lightsInBand: false), 886)
        XCTAssertEqual(WindowChromeRow.rowWidth(windowWidth: 1118, sidebarVisible: false, lightsInBand: false), 1118)
        XCTAssertEqual(WindowChromeRow.rowWidth(windowWidth: 1118, sidebarVisible: false, lightsInBand: true), 1046)
        // 950 pt Fenster.
        XCTAssertEqual(WindowChromeRow.rowWidth(windowWidth: 950, sidebarVisible: true, lightsInBand: false), 718)
        XCTAssertEqual(WindowChromeRow.rowWidth(windowWidth: 950, sidebarVisible: false, lightsInBand: false), 950)
    }

    func testM217ThresholdsStillHoldOnTheRowWidth() {
        // Die Grenzen aus M2.17 gelten weiter für die **Zeilenbreite**.
        XCTAssertTrue(MailChromeRow.showsTabs(inRowWidth: MailChromeRow.tabsMinRowWidth))
        XCTAssertFalse(MailChromeRow.showsTabs(inRowWidth: MailChromeRow.tabsMinRowWidth - 1))
        XCTAssertTrue(CalendarChromeRow.showsModePicker(inRowWidth: CalendarChromeRow.modePickerMinRowWidth))
        XCTAssertFalse(CalendarChromeRow.showsModePicker(inRowWidth: CalendarChromeRow.modePickerMinRowWidth - 1))
        // Mit Leiste bleibt ein 950-pt-Fenster unter der Tab-Grenze, ohne sie nicht.
        XCTAssertFalse(MailChromeRow.showsTabs(inRowWidth: WindowChromeRow.rowWidth(windowWidth: 950, sidebarVisible: true, lightsInBand: false)))
        XCTAssertTrue(MailChromeRow.showsTabs(inRowWidth: WindowChromeRow.rowWidth(windowWidth: 950, sidebarVisible: false, lightsInBand: false)))
    }

    func testTrafficLightsCountOnlyInsideTheBand() {
        // Fenster 900 pt hoch, Titelbar 32 pt, Band 52 pt: das Band liegt
        // zwischen 32 und 84 pt unter der Fensteroberkante (AppKit: von unten).
        let windowHeight: CGFloat = 900
        let topInset: CGFloat = 32
        let band: CGFloat = WindowChromeRow.height

        // Knopf in der Titelbar über dem Band (Oberkante 10 pt unter dem Rand).
        XCTAssertFalse(TrafficLights.overlapsBand(
            button: CGRect(x: 20, y: windowHeight - 24, width: 14, height: 14),
            windowHeight: windowHeight, topInset: topInset, bandHeight: band))

        // Knopf im Band (Oberkante 40 pt unter dem Rand).
        XCTAssertTrue(TrafficLights.overlapsBand(
            button: CGRect(x: 20, y: windowHeight - 54, width: 14, height: 14),
            windowHeight: windowHeight, topInset: topInset, bandHeight: band))

        // Knopf unter dem Band.
        XCTAssertFalse(TrafficLights.overlapsBand(
            button: CGRect(x: 20, y: windowHeight - 140, width: 14, height: 14),
            windowHeight: windowHeight, topInset: topInset, bandHeight: band))
    }
}
