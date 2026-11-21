import XCTest
@testable import RabeKit

/// M2.18k: Ordner in der Seitenleiste.
///
/// Der Nutzer sah einen Ordnerbaum, in dem fast jedes Kind unter dem falschen
/// Elternordner hing und sechs Wurzelordner mitten zwischen den Kindern
/// standen. Ursache: der Kern liefert die Ordner in Anlagereihenfolge,
/// `MailboxStore` sortierte die Liste nach Blattnamen, und `folderTree` rechnete
/// nur die Tiefe aus den Trennern — der Elternordner war damit einfach die
/// Zeile darüber.
final class M218kTests: XCTestCase {

    private func folder(_ id: Int64, _ name: String, role: String? = nil,
                        delimiter: String? = "/", account: Int64 = 1) -> FolderInfo {
        FolderInfo(id: id, accountId: account, imapName: name, delimiter: delimiter, role: role)
    }

    private func tree(_ names: [(String, Int64)], delimiter: String? = "/") -> [FolderRow] {
        Pickers.folderTree(names.map { folder($1, $0, delimiter: delimiter) })
    }

    // MARK: Der gemeldete Fall

    /// Die echte Struktur (nur gekürzt): sechs Wurzelordner, Kinder dazwischen
    /// in Anlagereihenfolge. Jedes Kind muss unter **seinem** Elternordner
    /// stehen, nicht unter dem zufälligen Vorgänger.
    func testChildrenHangUnderTheirOwnParent() {
        // Reihenfolge wie in der echten DB (nach `id`, quer durch die Gruppen).
        let rows = tree([
            ("finanzen/anwälte", 1), ("kommerz/abos", 3), ("finanzen/gesundheit", 4),
            ("job/sidequests", 6), ("finanzen/bank", 7), ("menschen/hannah", 8),
            ("job", 20), ("kommerz", 22), ("menschen", 26),
            ("finanzen", 29), ("Notes", 32), ("familie & wohnung", 35),
        ])
        XCTAssertEqual(rows.map(\.name), [
            "familie & wohnung",
            "finanzen", "anwälte", "bank", "gesundheit",
            "job", "sidequests",
            "kommerz", "abos",
            "menschen", "hannah",
            "Notes",
        ])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0])

        // Jedes Kind hängt an dem Elternordner, dessen Pfad es verlängert.
        for (index, row) in rows.enumerated() where row.depth > 0 {
            var parentIndex = index - 1
            while parentIndex >= 0, rows[parentIndex].depth != row.depth - 1 { parentIndex -= 1 }
            XCTAssertGreaterThanOrEqual(parentIndex, 0, "\(row.name) hat keinen Elternordner")
            guard parentIndex >= 0 else { return }
            let parent = rows[parentIndex]
            XCTAssertEqual(row.folder.imapName.lowercased(),
                           (parent.folder.imapName + "/" + row.name).lowercased(),
                           "\(row.name) muss unter \(parent.name) stehen")
        }
    }

    /// Sortiert wird innerhalb jeder Ebene, ohne Rücksicht auf Groß/Klein.
    func testSortingIsPerLevelAndCaseInsensitive() {
        let rows = tree([
            ("job/zeiterfassung", 3), ("job/Administration", 2), ("job/bewerbungen", 1),
            ("Job", 10), ("alpha", 20),
        ])
        XCTAssertEqual(rows.map(\.name), ["alpha", "Job", "Administration", "bewerbungen", "zeiterfassung"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1, 1])
    }

    // MARK: Fehlende und verkürzte Eltern

    /// Ein Elternordner fehlt in der Serverliste: das Kind landet **nicht** im
    /// Root, sondern unter einem nicht wählbaren Zwischenknoten.
    func testAMissingParentBecomesANonSelectableNode() {
        let rows = tree([
            ("Projekte/Rabe/Design", 6),
            ("Projekte/Rabe", 5),
        ])
        XCTAssertEqual(rows.map(\.name), ["Projekte", "Rabe", "Design"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])

        let parent = rows[0]
        XCTAssertFalse(parent.isSelectable, "fehlender Elternordner ist nicht wählbar")
        XCTAssertLessThan(parent.folder.id, 0, "Zwischenknoten bekommt eine negative Kennung")
        XCTAssertTrue(rows[1].isSelectable)
        XCTAssertTrue(rows[2].isSelectable)

        // Die Kennung ist über Aufrufe hinweg gleich (SwiftUI-Identität).
        let again = tree([("Projekte/Rabe/Design", 6), ("Projekte/Rabe", 5)])
        XCTAssertEqual(rows.map(\.folder.id), again.map(\.folder.id))
    }

    /// „INBOX.Ordner“ (Dovecot/Courier) wird ohne das Präfix einsortiert.
    func testTheInboxPrefixIsDropped() {
        var inbox = folder(1, "INBOX", role: "inbox", delimiter: ".")
        let rest = [("INBOX.Projekte", 2), ("INBOX.Projekte.Rabe", 3)].map {
            folder($0.1, $0.0, delimiter: ".")
        }
        _ = inbox
        let rows = Pickers.folderTree([inbox] + rest)
        XCTAssertEqual(rows.map(\.name), ["Projekte", "Rabe"])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
        XCTAssertTrue(rows.allSatisfy(\.isSelectable))
    }

    /// Gmails `[Gmail]/`-Präfix fällt ebenfalls weg.
    func testTheGmailPrefixIsDropped() {
        let rows = tree([
            ("[Gmail]/Alle Nachrichten", 1), ("[Gmail]/Reisen", 2), ("Reisen/2026", 3),
        ])
        XCTAssertEqual(rows.map(\.name), ["Alle Nachrichten", "Reisen", "2026"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1])
    }

    /// Der Trenner kommt vom Konto, nicht vom einzelnen Ordner: meldet er `.`,
    /// wird auch ein Ordner ohne eigene Angabe damit zerlegt.
    func testTheAccountDelimiterWins() {
        let rows = Pickers.folderTree([
            folder(1, "Rechnungen.2026", delimiter: "."),
            folder(2, "Rechnungen.2026.Januar", delimiter: nil),
        ])
        XCTAssertEqual(rows.map(\.name), ["Rechnungen", "2026", "Januar"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
    }

    /// Zwei Konten mit gleichnamigem Ordner bleiben getrennt.
    func testTwoAccountsKeepTheirOwnTrees() {
        let rows = Pickers.folderTree([
            folder(1, "Projekte", account: 1),
            folder(2, "Projekte/Innen", account: 1),
            folder(3, "Projekte", account: 2),
            folder(4, "Projekte/Außen", account: 2),
        ])
        XCTAssertEqual(rows.map(\.name), ["Projekte", "Innen", "Projekte", "Außen"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 1])
        XCTAssertEqual(rows[0].folder.accountId, 1)
        XCTAssertEqual(rows[2].folder.accountId, 2)
    }

    // MARK: Aufklappzustand

    private var rows: [FolderRow] {
        tree([("finanzen/bank", 2), ("finanzen", 1), ("job", 3), ("job/suche", 4)])
    }

    func testCollapsingAParentHidesOnlyItsChildren() {
        let rows = self.rows
        let closed = FolderDisclosure.visible(rows, open: [])
        XCTAssertEqual(closed.map(\.name), ["finanzen", "job"], "ohne Aufklappen nur die Wurzel")

        let open = Set([
            FolderDisclosure.identifier(accountId: 1, path: "finanzen"),
            FolderDisclosure.identifier(accountId: 1, path: "job"),
        ])
        XCTAssertEqual(FolderDisclosure.visible(rows, open: open).map(\.name),
                       ["finanzen", "bank", "job", "suche"])

        let onlyJob = Set([FolderDisclosure.identifier(accountId: 1, path: "job")])
        XCTAssertEqual(FolderDisclosure.visible(rows, open: onlyJob).map(\.name),
                       ["finanzen", "job", "suche"])
    }

    func testToggleAndPersistenceRoundTrip() {
        let suite = "m218k-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Erster Start: die vorhandenen Ordner stehen offen, der Stand wird
        // gespeichert. Danach sind neue Ordner eingeklappt.
        let seeded = FolderDisclosure.loadOrSeed(defaults: defaults, sandbox: true,
                                                 rows: self.rows)
        XCTAssertEqual(seeded, Set([
            FolderDisclosure.identifier(accountId: 1, path: "finanzen"),
            FolderDisclosure.identifier(accountId: 1, path: "job"),
        ]))

        // Zuklappen und speichern.
        let closed = FolderDisclosure.toggle(accountId: 1, path: "finanzen", in: seeded)
        FolderDisclosure.save(closed, defaults: defaults, sandbox: true)
        XCTAssertFalse(FolderDisclosure.isOpen(accountId: 1, path: "finanzen",
                                               open: FolderDisclosure.load(defaults: defaults, sandbox: true)))

        // Ein neuer Ordner taucht auf, ohne gespeicherten Zustand.
        let withNew = self.rows + tree([("neu/kind", 9)])
        let restored = FolderDisclosure.loadOrSeed(defaults: defaults, sandbox: true, rows: withNew)
        XCTAssertFalse(FolderDisclosure.isOpen(accountId: 1, path: "neu", open: restored),
                       "neue Ordner sind eingeklappt")
        XCTAssertTrue(FolderDisclosure.isOpen(accountId: 1, path: "job", open: restored))
    }

    /// Die Sandbox bekommt einen eigenen Schlüssel, damit ein Beleglauf den
    /// Start der echten App nicht verändert.
    func testSandboxUsesItsOwnKey() {
        XCTAssertNotEqual(FolderDisclosure.key(sandbox: true), FolderDisclosure.key(sandbox: false))
        XCTAssertTrue(FolderDisclosure.key(sandbox: true).hasSuffix(".sandbox"))
    }
}
