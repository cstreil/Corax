import XCTest
@testable import RabeKit

/// M2.11b: eine HTML-Mail, die ohne Breite geladen wird, bricht ein Zeichen pro
/// Zeile um und meldet ein Vielfaches ihrer Höhe (gemessen: 141 Zeichen →
/// 3852 pt statt 156 pt). Der Wert blieb in der Karte hängen.
final class M211bTests: XCTestCase {
    func testAPageIsNotLoadedBeforeItHasAWidth() {
        XCTAssertFalse(HTMLHeightGate.readyToLoad(viewWidth: 0))
        XCTAssertTrue(HTMLHeightGate.readyToLoad(viewWidth: 591))
    }

    func testAHeightMeasuredWithoutWidthIsRejected() {
        // Der gemessene Fehlerfall: 3852 pt, während die Seite innerWidth 0 hatte.
        XCTAssertFalse(HTMLHeightGate.accepts(height: 3852, viewWidth: 591, innerWidth: 0))
        // … und wenn schon die Ansicht keine Breite hat.
        XCTAssertFalse(HTMLHeightGate.accepts(height: 3852, viewWidth: 0, innerWidth: 0))
    }

    func testALayoutWithADifferentWidthIsRejected() {
        // Die Seite rechnet noch mit der alten Breite (Pool, Größenwechsel).
        XCTAssertFalse(HTMLHeightGate.accepts(height: 3285, viewWidth: 608, innerWidth: 0))
        XCTAssertFalse(HTMLHeightGate.accepts(height: 900, viewWidth: 608, innerWidth: 300))
    }

    func testANormalMeasurementPasses() {
        XCTAssertTrue(HTMLHeightGate.accepts(height: 156, viewWidth: 591, innerWidth: 591))
        XCTAssertTrue(HTMLHeightGate.accepts(height: 156, viewWidth: 608, innerWidth: 606))
    }

    func testEmptyHeightsAreRejected() {
        XCTAssertFalse(HTMLHeightGate.accepts(height: 0, viewWidth: 591, innerWidth: 591))
        XCTAssertFalse(HTMLHeightGate.accepts(height: -5, viewWidth: 591, innerWidth: 591))
    }
}
