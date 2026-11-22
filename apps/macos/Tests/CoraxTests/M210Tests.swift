import XCTest
@testable import CoraxKit

/// M2.10: die Statuszeile des semantischen Index.
///
/// Der Balken stand bei 11 034/11 071 auf halber Breite, weil er nur 260 pt breit
/// war — der *Wert* stimmte. Geprüft wird hier die Rechnung, die Zeile und der
/// Prozentwert.
final class M210Tests: XCTestCase {
    func testTheThreeStatesOfTheIndexRow() {
        XCTAssertEqual(EmbeddingStatusText.title(enabled: false, ready: true), "Aus")
        XCTAssertEqual(EmbeddingStatusText.title(enabled: false, ready: false), "Aus",
                       "aus bleibt aus, auch wenn ein Modell im Speicher liegt")
        XCTAssertEqual(EmbeddingStatusText.title(enabled: true, ready: false), "Aktiv · Modell wird geladen")
        XCTAssertEqual(EmbeddingStatusText.title(enabled: true, ready: true), "Bereit")
    }

    func testThePercentFollowsTheCounts() {
        XCTAssertEqual(EmbeddingStatusText.percent(embedded: 11_034, total: 11_071), 100,
                       "99,7 % rundet auf 100")
        XCTAssertEqual(EmbeddingStatusText.percent(embedded: 5_535, total: 11_071), 50)
        XCTAssertEqual(EmbeddingStatusText.percent(embedded: 0, total: 11_071), 0)
        XCTAssertEqual(EmbeddingStatusText.percent(embedded: 9, total: 0), 0,
                       "ohne Mail im Postfach kein Fortschritt")
    }

    func testTheCountLineNamesTheOpenItems() {
        XCTAssertEqual(EmbeddingStatusText.counts(embedded: 11_034, total: 11_071, pending: 29),
                       "11034/11071 eingebettet · 29 offen")
        XCTAssertEqual(EmbeddingStatusText.counts(embedded: 10, total: 10, pending: 0),
                       "10/10 eingebettet")
    }
}
