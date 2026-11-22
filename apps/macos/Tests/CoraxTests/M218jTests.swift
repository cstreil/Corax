import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.18j: Inline-Karte in der Tagesansicht. Der Einschub unter dem Block ist so
/// hoch wie die gemessene Karte; alles darunter rückt um genau diesen Wert nach
/// unten, die Stundenleiste mit. Was darüber liegt, bleibt stehen.
final class M218jTests: XCTestCase {
    private let hour = CalendarGrid.hourPx
    private let inset = CalendarInlineCard.inset
    private let card: CGFloat = 120
    private var cardAndInset: CGFloat { card + 2 * inset }
    /// Ein Block von 9:00 bis 10:00.
    private var nineToTen: CGFloat { CGFloat(10) * hour }
    private var gap: CalendarInlineCard.Gap {
        CalendarInlineCard.gap(bottom: nineToTen, cardHeight: card)
    }

    /// Der Streifen ist die Karte plus Rand — wie das Band im Monat.
    func testTheGapIsTheMeasuredCardPlusInset() {
        XCTAssertEqual(gap.afterY, ten, "der Streifen beginnt an der Blockunterkante")
        XCTAssertEqual(gap.height, card + 12, accuracy: 0.01)
    }

    /// Vor der ersten Messung hat die Karte eine Grundhöhe, sonst könnte sie sich
    /// nicht messen (sie stünde in einem null hohen Streifen).
    func testAnUnmeasuredCardUsesTheBaseHeight() {
        let unmeasured = CalendarInlineCard.gap(bottom: nineToTen, cardHeight: 0)
        XCTAssertEqual(unmeasured.height, CalendarInlineCard.baseHeight + 12, accuracy: 0.01)
        XCTAssertGreaterThan(unmeasured.height, 0)
    }

    private var ten: CGFloat { nineToTen }
    private var nine: CGFloat { CGFloat(9) * hour }

    /// Alles unter der Blockunterkante rückt um die Kartenhöhe nach unten …
    func testEverythingBelowTheBlockMovesDownByTheCard() {
        let eleven = CGFloat(11) * hour
        XCTAssertEqual(CalendarInlineCard.shown(eleven, gap: gap), eleven + cardAndInset,
                       accuracy: 0.01)
        XCTAssertEqual(CalendarInlineCard.shown(ten, gap: gap), ten + cardAndInset,
                       accuracy: 0.01, "auch der Termin, der genau jetzt beginnt")
    }

    /// … und der Block selbst bleibt, wo er ist.
    func testTheBlockItselfStaysInPlace() {
        XCTAssertEqual(CalendarInlineCard.shown(nine, gap: gap), nine)
        XCTAssertEqual(CalendarInlineCard.shown(nine + 40, gap: gap), nine + 40)
    }

    /// Die Stundenleiste und die Blöcke rücken **gleich** weit: eine Stunde nach
    /// der Karte steht ihre Beschriftung auf derselben Höhe wie ein Block, der um
    /// diese Stunde beginnt.
    func testHourLabelAndBlockStayAligned() {
        let eleven = CGFloat(11) * hour
        let label = CalendarInlineCard.shown(eleven, gap: gap)
        let block = CalendarInlineCard.shown(eleven, gap: gap)
        XCTAssertEqual(label, block, accuracy: 0.01)
        XCTAssertEqual(label - eleven, cardAndInset, accuracy: 0.01)
    }

    /// Klicks werden zurückgerechnet, damit sie die richtige Stunde treffen.
    func testClicksMapBackToTheTime() {
        let eleven = CGFloat(11) * hour
        let shown = CalendarInlineCard.shown(eleven, gap: gap)
        XCTAssertEqual(CalendarInlineCard.time(shown, gap: gap), eleven, accuracy: 0.01)
        // Über der Karte bleibt die Zeit, wie sie ist.
        XCTAssertEqual(CalendarInlineCard.time(nine, gap: gap), nine)
        // Mitten in der Karte gilt die Zeit davor, nicht die dahinter.
        XCTAssertEqual(CalendarInlineCard.time(ten + 40, gap: gap), ten + 40)
    }

    /// Ohne Karte ist der Einschub wirkungslos.
    func testWithoutACardNothingMoves() {
        XCTAssertEqual(CalendarInlineCard.shown(500, gap: nil), 500)
        XCTAssertEqual(CalendarInlineCard.time(500, gap: nil), 500)
        XCTAssertEqual(CalendarInlineCard.height(1344, gap: nil), 1344)
    }

    /// Das Raster wird um den Streifen höher — sonst wäre der letzte Termin des
    /// Tages abgeschnitten.
    func testTheGridGrowsByTheGap() {
        XCTAssertEqual(CalendarInlineCard.height(24 * hour, gap: gap), 24 * hour + cardAndInset,
                       accuracy: 0.01)
    }

    /// Die Karte wird ganz sichtbar gescrollt: unten angekommen reicht ein Schub
    /// bis zu ihrer Unterkante, nicht bis in die Mitte.
    func testTheCardIsScrolledJustIntoView() {
        let total = CalendarInlineCard.height(24 * hour, gap: gap)
        let target = CalendarInlineCard.scrollTarget(gap: gap, scrollOffset: 0, visible: 500,
                                                     total: total)
        XCTAssertEqual(target, gap.afterY + gap.height - 500 + 10, accuracy: 0.01)
    }

    /// Ist die Karte schon zu sehen, bleibt der Scrollstand.
    func testAVisibleCardDoesNotScroll() {
        let total = CalendarInlineCard.height(24 * hour, gap: gap)
        let target = CalendarInlineCard.scrollTarget(gap: gap, scrollOffset: 400, visible: 600,
                                                     total: total)
        XCTAssertEqual(target, 400)
    }

    /// Steht die Karte über dem sichtbaren Bereich, wird nach oben gescrollt.
    func testTheCardAboveTheViewScrollsUp() {
        let total = CalendarInlineCard.height(24 * hour, gap: gap)
        let target = CalendarInlineCard.scrollTarget(gap: gap, scrollOffset: 900, visible: 600,
                                                     total: total)
        XCTAssertEqual(target, gap.afterY - 10, accuracy: 0.01)
    }

    /// Nie über das Raster hinaus.
    func testTheScrollTargetStaysInsideTheGrid() {
        let total = CalendarInlineCard.height(24 * hour, gap: gap)
        let far = CalendarInlineCard.Gap(afterY: 23 * hour, height: cardAndInset)
        let target = CalendarInlineCard.scrollTarget(gap: far, scrollOffset: 0, visible: 600,
                                                     total: total)
        XCTAssertLessThanOrEqual(target, total - 600)
        XCTAssertGreaterThanOrEqual(target, 0)
    }
}
