import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.18i: Karte im Zeitraster (oben bündig am Block, in den sichtbaren Bereich
/// geklemmt, folgt dem Scrollen) und Bandhöhe im Monat (die gemessene Karte,
/// keine feste Reserve).
final class M218iTests: XCTestCase {
    private let visible = CGSize(width: 1000, height: 700)
    private let gridTop: CGFloat = 60
    private let cardHeight: CGFloat = 200
    private let cardWidth = CalendarCardPlacement.width
    private let margin = CalendarCardPlacement.margin
    // Gültiger Bereich für `y`: [gridTop + margin, visible.height − cardHeight − margin]
    private let minY: CGFloat = 68
    private let maxY: CGFloat = 492

    /// Oben bündig mit dem Block, rechts daneben, wenn links kein Platz ist.
    func testTheCardSitsTopAlignedNextToTheBlock() {
        let block = CGRect(x: 100, y: 200, width: 100, height: 56)
        let placed = CalendarCardPlacement.anchor(block: block, visible: visible, gridTop: gridTop,
                                                  cardHeight: cardHeight, scrollOffset: 100)
        XCTAssertEqual(placed.y, 60 + 200 - 100, "Kopf + Block.minY − Scroll")
        XCTAssertEqual(placed.x, block.maxX + margin, "rechts, weil links kein Platz ist")
    }

    /// Links, wenn dort Platz für die ganze Karte ist.
    func testTheCardGoesLeftWhenThereIsRoom() {
        let block = CGRect(x: 500, y: 200, width: 100, height: 56)
        let placed = CalendarCardPlacement.anchor(block: block, visible: visible, gridTop: gridTop,
                                                  cardHeight: cardHeight, scrollOffset: 100)
        XCTAssertEqual(placed.x, 500 - margin - cardWidth)
    }

    /// Oben zu wenig Platz: die Karte rutscht unter den Kopf und bleibt sichtbar.
    func testTheCardMovesUpWhenTheBlockIsNearTheTop() {
        let block = CGRect(x: 100, y: 10, width: 100, height: 56)
        let placed = CalendarCardPlacement.anchor(block: block, visible: visible, gridTop: gridTop,
                                                  cardHeight: cardHeight, scrollOffset: 100)
        XCTAssertEqual(placed.y, minY)
    }

    /// Unten zu wenig Platz: die Karte wird hochgeschoben, bis sie ganz passt.
    func testTheCardStaysFullyVisibleAtTheBottom() {
        let block = CGRect(x: 100, y: 1500, width: 100, height: 56)
        let placed = CalendarCardPlacement.anchor(block: block, visible: visible, gridTop: gridTop,
                                                  cardHeight: cardHeight, scrollOffset: 1000)
        XCTAssertEqual(placed.y, maxY)
    }

    /// Der Scrollstand verschiebt die Karte mit ihrem Block.
    func testScrollingMovesTheCardWithTheBlock() {
        let block = CGRect(x: 100, y: 200, width: 100, height: 56)
        let before = CalendarCardPlacement.anchor(block: block, visible: visible, gridTop: gridTop,
                                                  cardHeight: cardHeight, scrollOffset: 0)
        let after = CalendarCardPlacement.anchor(block: block, visible: visible, gridTop: gridTop,
                                                 cardHeight: cardHeight, scrollOffset: 50)
        XCTAssertEqual(before.y - after.y, 50)
    }

    /// Ohne Block (Termin außerhalb der Sicht) gibt es keinen Anker: oben rechts.
    func testWithoutABlockTheCardSitsTopRight() {
        let placed = CalendarCardPlacement.anchor(block: nil, visible: visible, gridTop: gridTop,
                                                  cardHeight: cardHeight, scrollOffset: 0)
        XCTAssertEqual(placed.y, gridTop + margin)
        XCTAssertEqual(placed.x, visible.width - cardWidth - margin)
    }

    /// Ganztägige Balken sitzen im festen Kopf, die Karte hängt daran.
    func testAnAllDayBarAnchorsTheCardUnderIt() {
        let bar = CGRect(x: 60, y: 20, width: 150, height: 18)
        let placed = CalendarCardPlacement.anchorBar(bar: bar, visible: visible,
                                                     cardHeight: cardHeight)
        XCTAssertEqual(placed.y, bar.maxY + margin)
        XCTAssertEqual(placed.x, bar.maxX + margin)
    }

    /// Das Band im Monat ist genau die gemessene Karte plus Rand.
    func testTheMonthBandIsExactlyTheMeasuredCard() {
        XCTAssertEqual(MonthBand.height(card: 180, total: 800), 188)
        XCTAssertEqual(MonthBand.height(card: 180, total: 2000), 188,
                       "ein höheres Band als die Karte gibt es nicht")
        // Nie mehr, als die sechs Wochen mit 48 pt übrig lassen (400 − 288 = 112).
        XCTAssertEqual(MonthBand.height(card: 600, total: 400), 112)
        // Vor der ersten Messung: eine kleine Grundhöhe statt null.
        XCTAssertEqual(MonthBand.height(card: 0, total: 800), 120)
    }

    // MARK: - Blocklage

    /// Ein Block, der um `hour` beginnt und eine Stunde dauert, mit seiner Lage
    /// aus demselben Modell, das das Raster benutzt.
    private func positioned(hour: Int, id: Int64 = 1) -> PositionedEvent {
        let start = Int64(hour) * 3_600_000
        let event = CalendarEvent(id: id, accountId: 1, messageId: nil, summary: "T\(hour)",
                                  location: nil, organizer: nil, description: nil, attendees: [],
                                  joinUrl: nil, rsvpStatus: nil, isLocal: true, calendarId: 1,
                                  rrule: nil, startsAt: start, endsAt: start + 3_600_000,
                                  allDay: false, status: "CONFIRMED", method: nil)
        return CalendarMath.layoutDay([event], dayStart: 0)[0]
    }

    /// Der Beleg hat es aufgedeckt: gemessen kam für **jeden** Block `minY = 0`
    /// heraus, weil `.offset` nur zeichnet. Gerechnet liegt der Block auf seiner
    /// Zeit — und zwei Termine zwölf Stunden auseinander damit nicht mehr
    /// übereinander.
    func testTheBlockRectSitsAtTheEventTime() {
        let nine = CalendarCardPlacement.blockRect(positioned(hour: 9), column: 5, columnWidth: 120)
        let late = CalendarCardPlacement.blockRect(positioned(hour: 21), column: 5, columnWidth: 120)
        XCTAssertEqual(nine.minY, 9 * CalendarGrid.hourPx + 1, accuracy: 0.01)
        XCTAssertEqual(late.minY, 21 * CalendarGrid.hourPx + 1, accuracy: 0.01)
        XCTAssertEqual(late.minY - nine.minY, 12 * CalendarGrid.hourPx, accuracy: 0.01,
                       "zwölf Stunden Abstand, nicht beide am Spaltenkopf")
    }

    /// Der Spaltenversatz steckt im Rechteck, sonst läge jeder Tag über dem ersten.
    func testTheBlockRectIncludesTheColumnOffset() {
        let first = CalendarCardPlacement.blockRect(positioned(hour: 9), column: 0, columnWidth: 120)
        let sixth = CalendarCardPlacement.blockRect(positioned(hour: 9), column: 5, columnWidth: 120)
        XCTAssertEqual(first.minX, CalendarGrid.gutterPx + 2, accuracy: 0.01)
        XCTAssertEqual(sixth.minX - first.minX, 5 * 120, accuracy: 0.01)
    }

    /// Und die Karte folgt dem Block: bei gleichem Scrollstand liegen 9 Uhr und
    /// 21 Uhr zwölf Stunden auseinander, statt beide am Kopf zu kleben.
    func testTheCardFollowsTwoBlocksAtDifferentTimes() {
        let tall = CGSize(width: 1000, height: 1400)
        let scroll: CGFloat = 400
        let nine = CalendarCardPlacement.anchor(
            block: CalendarCardPlacement.blockRect(positioned(hour: 9), column: 5, columnWidth: 120),
            visible: tall, gridTop: gridTop, cardHeight: cardHeight, scrollOffset: scroll)
        let late = CalendarCardPlacement.anchor(
            block: CalendarCardPlacement.blockRect(positioned(hour: 21), column: 5, columnWidth: 120),
            visible: tall, gridTop: gridTop, cardHeight: cardHeight, scrollOffset: scroll)
        XCTAssertEqual(nine.y, gridTop + 9 * CalendarGrid.hourPx + 1 - scroll, accuracy: 0.01)
        XCTAssertEqual(late.y - nine.y, 12 * CalendarGrid.hourPx, accuracy: 0.01)
    }

    // MARK: Ein ⌘↵ sichert genau einmal (M2.18o)

    /// Vorher hing die Karte im Monatsband zweimal im Baum — sichtbar und als
    /// unsichtbare Messkopie. Beide Editoren sicherten auf `⌘↵`: die Änderung
    /// ging doppelt an den Kern, bei Teilnehmenden die Mail zweimal raus.
    @MainActor
    func testOneSaveRequestIsHandledExactlyOnce() {
        let store = CalendarStore(toasts: ToastCenter())
        XCTAssertFalse(store.takeSaveRequest(), "ohne Anforderung gibt es nichts zu sichern")
        store.requestSave()
        XCTAssertTrue(store.takeSaveRequest(), "die Karte sichert")
        XCTAssertFalse(store.takeSaveRequest(), "eine zweite Kopie sichert nicht noch einmal")
        store.requestSave()
        XCTAssertTrue(store.takeSaveRequest(), "der nächste ⌘↵ wird wieder verarbeitet")
        XCTAssertFalse(store.takeSaveRequest())
    }
}
