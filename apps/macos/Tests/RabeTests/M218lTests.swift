import AppKit
import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.18l: der Stern zeigt in der Aktionsleiste seinen Zustand, und das
/// Label-Kürzel der Zeile nennt das erste eigene Label plus „+n".
final class M218lTests: XCTestCase {
    private let fallback = NSColor.systemGray

    private func label(_ id: Int64, _ name: String, color: String = "#3366CC",
                       auto: Bool = false) -> Label {
        Label(id: id, name: name, color: color, keyword: "kw\(id)", position: id, isAuto: auto)
    }

    // MARK: Stern

    /// Markiert wird der gefüllte Stern gezeichnet, sonst der leere — das war
    /// der Fehler: im Aktionsknopf stand immer der leere.
    func testTheStarShowsItsState() {
        XCTAssertEqual(ThreadCellView.starSymbolName(starred: true), "star.fill")
        XCTAssertEqual(ThreadCellView.starSymbolName(starred: false), "star")
        let flagged = ThreadCellView.starIcon(starred: true, color: .black)
        let plain = ThreadCellView.starIcon(starred: false, color: .black)
        XCTAssertNotNil(flagged)
        XCTAssertNotNil(plain)
        XCTAssertNotEqual(flagged?.tiffRepresentation, plain?.tiffRepresentation,
                          "gefüllt und leer müssen sich unterscheiden")
    }

    /// Der markierte Stern ist gelb, egal welche Textfarbe die Zeile gerade hat.
    func testAFlaggedStarIsAlwaysTheSameYellow() {
        let onPaper = ThreadCellView.starIcon(starred: true, color: .black)
        let onDark = ThreadCellView.starIcon(starred: true, color: .white)
        XCTAssertEqual(onPaper?.tiffRepresentation, onDark?.tiffRepresentation)
    }

    /// Der leere Stern nimmt die Farbe der Zeile an.
    func testAPlainStarFollowsTheRowColor() {
        let dark = ThreadCellView.starIcon(starred: false, color: .black)
        let light = ThreadCellView.starIcon(starred: false, color: .white)
        XCTAssertNotEqual(dark?.tiffRepresentation, light?.tiffRepresentation)
    }

    // MARK: Label-Kürzel

    /// Ein eigenes Label, keine weiteren: nur der Name.
    func testASingleLabelIsJustTheName() {
        let info = RowLabelInfo.make(ids: [7], labels: [7: label(7, "Rechnung")], color: fallback)
        XCTAssertEqual(info?.name, "Rechnung")
        XCTAssertEqual(info?.more, 0)
        XCTAssertEqual(info?.text, "Rechnung")
    }

    /// Zwei eigene Labels: das erste mit „+1".
    func testMoreLabelsAddACounter() {
        let two = RowLabelInfo.make(ids: [7, 8],
                                    labels: [7: label(7, "Rechnung"), 8: label(8, "Steuer")],
                                    color: fallback)
        XCTAssertEqual(two?.text, "Rechnung +1")
        XCTAssertEqual(two?.more, 1)
        let three = RowLabelInfo.make(ids: [7, 8, 9],
                                      labels: [7: label(7, "Rechnung"), 8: label(8, "Steuer"),
                                               9: label(9, "Bank")],
                                      color: fallback)
        XCTAssertEqual(three?.text, "Rechnung +2")
    }

    /// Automatische Kategorien stehen seit M2.18n mit in der Zeile: eigene
    /// zuerst, und die Kapsel bekommt ein Funkeln.
    func testAutomaticLabelsShowWithASparkle() {
        let info = RowLabelInfo.make(ids: [1, 7],
                                     labels: [1: label(1, "Marketing", auto: true),
                                              7: label(7, "Rechnung")],
                                     color: fallback)
        XCTAssertEqual(info?.text, "Rechnung +1")
        XCTAssertEqual(info?.isAuto, false)

        let onlyAuto = RowLabelInfo.make(ids: [1], labels: [1: label(1, "News", auto: true)],
                                         color: fallback)
        XCTAssertEqual(onlyAuto?.name, "News", "ohne eigenes Label zeigt die Kapsel das automatische")
        XCTAssertEqual(onlyAuto?.isAuto, true, "nur dann setzt die Zeile das Funkeln")

        let ownLater = RowLabelInfo.make(ids: [1, 7],
                                         labels: [1: label(1, "Marketing", auto: true),
                                                  7: label(7, "Rechnung")],
                                         color: fallback)
        XCTAssertEqual(ownLater?.name, "Rechnung", "eigene Labels stehen vor automatischen")
    }

    /// Eine unbekannte Kennung kostet nicht das ganze Kürzel.
    func testAnUnknownLabelIsSkipped() {
        let info = RowLabelInfo.make(ids: [99, 7], labels: [7: label(7, "Rechnung")],
                                     color: fallback)
        XCTAssertEqual(info?.name, "Rechnung")
        XCTAssertNil(RowLabelInfo.make(ids: [99], labels: [:], color: fallback))
        XCTAssertNil(RowLabelInfo.make(ids: [], labels: [7: label(7, "Rechnung")], color: fallback))
    }

    /// Die Farbe kommt vom Label; fehlt sie, bleibt die Ersatzfarbe der Zeile.
    func testTheBadgeTakesTheLabelColor() {
        let info = RowLabelInfo.make(ids: [7], labels: [7: label(7, "Rechnung", color: "#FF0000")],
                                     color: fallback)
        XCTAssertEqual(info?.color.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.02)
        let broken = RowLabelInfo.make(ids: [7], labels: [7: label(7, "Rechnung", color: "nope")],
                                       color: fallback)
        XCTAssertEqual(broken?.color, fallback)
    }
}
