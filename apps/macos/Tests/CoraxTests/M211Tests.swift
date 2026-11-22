import XCTest
@testable import CoraxKit

/// M2.11: beim Aufklappen bleibt über der Mail eine Zeile der Liste stehen.
///
/// Der Bereich unter dem Inset ist hier 0…600; die Thread-Zeile ist 40 pt hoch,
/// also liegt die Zeile darüber bei `aboveTop = rowTop - 40`.
final class M211Tests: XCTestCase {
    private let height: CGFloat = 600

    private func reveal(_ rowTop: CGFloat, _ aboveTop: CGFloat, cardBottom: CGFloat,
                        belowH: CGFloat) -> CGFloat? {
        ListReveal.revealTop(rowTop: rowTop, aboveTop: aboveTop, cardBottom: cardBottom,
                             belowH: belowH, visibleMinY: 0, visibleHeight: height)
    }

    func testAMailThatAlreadyFitsDoesNotScroll() {
        XCTAssertNil(reveal(100, 60, cardBottom: 500, belowH: 40))
    }

    func testAShortMailHangsOutBelow() {
        // 700 + 44 ragt 144 pt heraus, die Zeile darüber erlaubt das.
        XCTAssertEqual(reveal(300, 260, cardBottom: 700, belowH: 44), 144)
    }

    func testAMailTallerThanTheWindowKeepsOneRowAbove() {
        // Reicht der Platz nie, bleibt oben genau die Zeile darüber stehen.
        XCTAssertEqual(reveal(300, 260, cardBottom: 1_200, belowH: 44), 260)
    }

    func testARowCutAtTheTopScrollsToTheRowAbove() {
        // Die Zeile beginnt über dem sichtbaren Bereich: zurück bis zur Zeile darüber.
        XCTAssertEqual(reveal(-30, -70, cardBottom: 400, belowH: 44), -70)
    }

    func testTheFirstRowHasNoRowAbove() {
        // Ohne Vorgänger ist die eigene Oberkante die Grenze — hier ist nichts zu holen.
        XCTAssertNil(reveal(0, 0, cardBottom: 700, belowH: 40))
        // Angeschnitten geht es nur bis an ihren Anfang.
        XCTAssertEqual(reveal(-20, -20, cardBottom: 300, belowH: 40), -20)
    }

    func testTheLastRowHasNoRowBelow() {
        XCTAssertEqual(reveal(300, 260, cardBottom: 700, belowH: 0), 100)
    }

    func testRoundingOfLayoutValuesDoesNotScroll() {
        // Ein halber Punkt ist gerundet schon die richtige Stelle.
        XCTAssertNil(reveal(100, 60, cardBottom: 560.5, belowH: 40))
    }
}
