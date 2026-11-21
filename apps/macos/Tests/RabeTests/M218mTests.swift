import XCTest
@testable import RabeKit

/// M2.18m: „Gehe zu Ordner/Label …“ (`G` `O`) — Ziele, Suche und die Taste.
final class M218mTests: XCTestCase {

    private func folder(_ id: Int64, _ name: String, account: Int64 = 1,
                        delimiter: String? = "/") -> FolderInfo {
        FolderInfo(id: id, accountId: account, imapName: name, delimiter: delimiter, role: nil)
    }

    private func label(_ id: Int64, _ name: String, auto: Bool = false) -> Label {
        Label(id: id, name: name, color: "#3366ff", keyword: "$rabe-\(id)",
              position: id, isAuto: auto)
    }

    // MARK: Ziele

    func testFoldersComeWithTheirPathAndLabelsWithoutAutoCategories() {
        let entries = GoToEntries.make(
            folders: [folder(3, "Projekte/Rabe"), folder(2, "Projekte")],
            labels: [label(10, "Reise"), label(11, "Bank"), label(12, "Marketing", auto: true)])
        XCTAssertEqual(entries.map(\.title), ["Projekte", "Rabe", "Bank", "Reise"])
        XCTAssertEqual(entries.map(\.kind), [.folder, .folder, .label, .label])
        XCTAssertEqual(entries[0].path, "Projekte")
        XCTAssertEqual(entries[1].path, "Projekte / Rabe", "der Pfad ist lesbar")
        XCTAssertEqual(entries[1].detail, "Projekte / Rabe")
        XCTAssertNil(entries[2].path)
        XCTAssertFalse(entries.contains { $0.title == "Marketing" }, "automatische Labels fallen weg")
    }

    /// Zwischenknoten des Baums sind keine Ziele: ein fehlender Elternordner
    /// wird eingefügt, aber nicht angeboten.
    func testMissingParentsAreNotTargets() {
        let entries = GoToEntries.make(folders: [folder(5, "Projekte/Rabe/Design")], labels: [])
        XCTAssertEqual(entries.map(\.title), ["Design"])
        XCTAssertTrue(entries.allSatisfy { $0.targetId > 0 },
                      "nur echte Ordner, keine negativen Zwischenknoten")
    }

    func testTheAccountIsShownOnlyWithSeveralAccounts() {
        let accounts: [Int64: String] = [1: "privat", 2: "arbeit"]
        let one = GoToEntries.make(folders: [folder(1, "Bank")], labels: [],
                                   accounts: accounts, showsAccount: false)
        XCTAssertNil(one[0].account)

        let many = GoToEntries.make(folders: [folder(1, "Bank", account: 2)], labels: [],
                                    accounts: accounts, showsAccount: true)
        XCTAssertEqual(many[0].account, "arbeit")
        XCTAssertEqual(many[0].detail, "arbeit")
    }

    // MARK: Suche

    func testSearchFindsByNameAndByPath() {
        let entries = GoToEntries.make(
            folders: [folder(1, "Projekte"), folder(2, "Projekte/Rabe"), folder(3, "Bank")],
            labels: [label(10, "Steuer")])

        XCTAssertEqual(GoToEntries.matches(entries, query: "bank").map(\.title), ["Bank"])
        XCTAssertEqual(GoToEntries.matches(entries, query: "rabe").map(\.title), ["Rabe"],
                       "der Ordnername reicht")
        XCTAssertEqual(GoToEntries.matches(entries, query: "projekte").map(\.title),
                       ["Projekte", "Rabe"], "der Pfad trifft Ordner und Kinder")
        XCTAssertEqual(GoToEntries.matches(entries, query: "steu").map(\.title), ["Steuer"])
        XCTAssertEqual(GoToEntries.matches(entries, query: "").count, entries.count)
        XCTAssertTrue(GoToEntries.matches(entries, query: "xyz").isEmpty)
    }

    /// Ein Treffer am Namensanfang steht vor einem Treffer mitten im Wort.
    func testPrefixMatchesRankFirst() {
        let entries = GoToEntries.make(
            folders: [folder(1, "Rechnungsbank"), folder(2, "Bank")], labels: [])
        XCTAssertEqual(GoToEntries.matches(entries, query: "bank").map(\.title), ["Bank", "Rechnungsbank"])
    }

    func testSteppingStaysInsideTheList() {
        XCTAssertEqual(GoToEntries.stepped(0, by: 1, count: 3), 1)
        XCTAssertEqual(GoToEntries.stepped(2, by: 1, count: 3), 2)
        XCTAssertEqual(GoToEntries.stepped(0, by: -1, count: 3), 0)
        XCTAssertEqual(GoToEntries.stepped(0, by: 1, count: 0), 0)
    }

    // MARK: Taste und Doku

    func testShiftCommandOAppearsExactlyOnce() {
        let combos = ShortcutMap.all.flatMap(\.combos)
        XCTAssertEqual(combos.filter { $0 == "⇧⌘O" }.count, 1, "⇧⌘O darf nur einmal belegt sein")
        XCTAssertEqual(combos.filter { $0 == "⌘O" }.count, 1, "⌘O bleibt Meeting beitreten")
    }

    func testTheGoToRowIsInTheShortcutTable() {
        let row = ShortcutMap.all.first { $0.action.contains("Ordner/Label") }
        let entry = try? XCTUnwrap(row)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.singles, [], "`G` steht schon auf der Postfach-Zeile")
        XCTAssertEqual(entry?.combos, ["⇧⌘O"])
        if let entry { XCTAssertEqual(ShortcutMap.keys(entry), "⇧⌘O") }
        XCTAssertTrue(entry?.action.contains("G O") ?? false, "die Folge steht im Text")
    }

    /// `g` bleibt die Einleitung; `o` ist ein zweiter Buchstabe und darf die
    /// Postfach-Folge nicht verdrängen.
    func testTheMailboxFollowKeysAreUntouched() {
        let row = ShortcutMap.all.first { $0.action.hasPrefix("Gehe zu Postfach") }
        XCTAssertEqual(row?.singles, ["G"])
        XCTAssertFalse(row?.action.contains("O ") ?? true, "`g o` wird jetzt von Ordner/Label genutzt")
    }
}
