import AppKit
import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.18n: Labels in Liste und Mail, und die sichtbare `G`-Folge.
///
/// In der echten Instanz standen vier Labels, drei davon automatische
/// Kategorien — Liste und Mail blendeten genau die aus, sichtbar blieb fast
/// nichts. Und `G` wartete stumm auf die zweite Taste, was wie ein Defekt
/// aussah.
final class M218nTests: XCTestCase {
    private func label(_ id: Int64, _ name: String, position: Int64 = 0,
                       auto: Bool? = false) -> Label {
        Label(id: id, name: name, color: "#3366CC", keyword: "K\(id)",
              position: position, isAuto: auto)
    }

    // MARK: Gemeinsame Regel

    func testOwnLabelsComeBeforeAutomaticOnes() {
        let labels: [Int64: Label] = [
            1: label(1, "Marketing", position: 0, auto: true),
            2: label(2, "News", position: 1, auto: true),
            5: label(5, "Privat", position: 4),
        ]
        let ordered = MailLabelDisplay.ordered(ids: [1, 2, 5], labels: labels)
        XCTAssertEqual(ordered.map(\.name), ["Privat", "Marketing", "News"],
                       "eigene Labels zuerst, auch bei kleinerer Position der automatischen")
    }

    func testWithinAGroupPositionWinsThenTheName() {
        let labels: [Int64: Label] = [
            1: label(1, "Rechnung", position: 9),
            2: label(2, "Arbeit", position: 2),
            3: label(3, "Bank", position: 2),
            4: label(4, "Auto", position: 0, auto: true),
            5: label(5, "Familie", position: 0, auto: true),
        ]
        let ordered = MailLabelDisplay.ordered(ids: [1, 2, 3, 4, 5], labels: labels)
        XCTAssertEqual(ordered.map(\.name), ["Arbeit", "Bank", "Rechnung", "Auto", "Familie"])
    }

    func testUnknownAndDuplicateIDsAreDropped() {
        let labels: [Int64: Label] = [1: label(1, "Privat")]
        let ordered = MailLabelDisplay.ordered(ids: [1, 1, 99], labels: labels)
        XCTAssertEqual(ordered.map(\.id), [1])

        let badge = MailLabelDisplay.badge(ids: [1, 1, 99], labels: labels)
        XCTAssertEqual(badge?.more, 0, "eine doppelte Kennung ist kein zweites Label")
    }

    func testBadgeNamesTheFirstLabelAndCountsTheRest() {
        let labels: [Int64: Label] = [
            1: label(1, "Marketing", position: 0, auto: true),
            2: label(2, "Reise", position: 4),
            5: label(5, "Privat", position: 3),
        ]
        let badge = MailLabelDisplay.badge(ids: [1, 2, 5], labels: labels)
        XCTAssertEqual(badge?.name, "Privat")
        XCTAssertEqual(badge?.text, "Privat +2")
        XCTAssertEqual(badge?.isAuto, false)
    }

    func testBadgeMarksAnAutomaticCategory() {
        let labels: [Int64: Label] = [1: label(1, "Marketing", position: 0, auto: true)]
        let badge = MailLabelDisplay.badge(ids: [1], labels: labels)
        XCTAssertEqual(badge?.text, "Marketing")
        XCTAssertEqual(badge?.isAuto, true, "nur so kann die Zeile das Funkeln setzen")
    }

    func testBadgeIsNilWithoutLabels() {
        XCTAssertNil(MailLabelDisplay.badge(ids: [], labels: [:]))
        XCTAssertNil(MailLabelDisplay.badge(ids: [7], labels: [1: label(1, "Privat")]))
    }

    /// `isAuto` ist im Modell optional (alte Zeilen ohne Feld); `nil` ist ein
    /// eigenes Label, keine automatische Kategorie.
    func testNilIsAnOwnLabel() {
        let labels: [Int64: Label] = [1: label(1, "Alt", auto: nil)]
        XCTAssertEqual(MailLabelDisplay.badge(ids: [1], labels: labels)?.isAuto, false)
    }

    // MARK: `G`-Folge

    func testEveryMailboxHasASecondKey() {
        let covered = Set(GoSequence.targets.compactMap(\.view))
        XCTAssertEqual(covered, Set(MailView.allCases),
                       "jedes Postfach der Seitenleiste muss über `g` erreichbar sein")
    }

    func testTheFolderPickerIsPartOfTheSequence() {
        let picker = GoSequence.target(for: "o")
        XCTAssertNil(picker?.view, "`g o` fragt nach Ordner oder Label")
        XCTAssertEqual(picker?.title, "Ordner/Label …")
        XCTAssertEqual(GoSequence.target(for: "O")?.key, "o", "Großschreibung zählt nicht")
    }

    func testTheSecondKeysAreUnique() {
        let keys = GoSequence.targets.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertTrue(keys.allSatisfy { !$0.isEmpty })
    }

    func testUnknownSecondKeyIsNotATarget() {
        XCTAssertNil(GoSequence.target(for: "q"))
    }

    func testTheHintKeepsReadingTime() {
        XCTAssertEqual(GoSequence.headline, "Gehe zu:")
        XCTAssertEqual(GoSequence.window, 2, "M2.18n: 1,2 s waren zu kurz für einen Hinweis")
    }

    // MARK: Seitenleiste

    func testTheSidebarShowsTheWholeSequence() {
        XCTAssertEqual(SidebarColumn.goHint(for: .inbox), "G I")
        XCTAssertEqual(SidebarColumn.goHint(for: .starred), "G S")
        XCTAssertEqual(SidebarColumn.goHint(for: .trash), "G #")
        XCTAssertEqual(SidebarColumn.goHint(for: .spam), "G !")
        XCTAssertEqual(SidebarColumn.goHint(for: .all), "G A")
    }

    /// Jede Zeile mit Zähler muss die Folge trotzdem zeigen; die Tabelle ist die
    /// eine Quelle für beides.
    func testTheSidebarHintComesFromTheSequenceTable() {
        for view in MailView.allCases {
            let target = GoSequence.targets.first { $0.view == view }
            XCTAssertNotNil(target, "\(view) fehlt in GoSequence")
            XCTAssertEqual(SidebarColumn.goHint(for: view), "G " + (target?.key.uppercased() ?? "?"))
        }
    }
}
