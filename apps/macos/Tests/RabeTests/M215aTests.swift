import XCTest
@testable import RabeKit

/// M2.15a: die eigenen IMAP-Ordner in der Seitenleiste (1.3) und der
/// Nachlade-Pfad der HTML-Mails (1.2) — die reinen Teile davon.
final class M215aTests: XCTestCase {
    private func folder(_ id: Int64, _ name: String, role: String? = nil, delimiter: String? = "/") -> FolderInfo {
        FolderInfo(id: id, accountId: 1, imapName: name, delimiter: delimiter, role: role)
    }

    /// Eigene Ordner stehen in der Liste, Systemordner nicht, und die
    /// Hierarchie kommt aus dem Trennzeichen des Servers.
    ///
    /// M2.18k: Sortiert wird jetzt **innerhalb jeder Ebene** nach Namen —
    /// vorher stand die Liste in der Reihenfolge des Kerns, und genau daran
    /// hing jedes Kind unter dem falschen Elternordner.
    func testOwnFoldersBecomeRowsWithHierarchy() {
        let folders = [
            folder(1, "INBOX", role: "inbox"),
            folder(2, "Archive", role: "archive"),
            folder(3, "Sent", role: "sent"),
            folder(4, "Projekte"),
            folder(5, "Projekte/Rabe"),
            folder(6, "Projekte/Rabe/Design"),
            folder(7, "Familie"),
        ]
        let rows = Pickers.folderTree(folders)
        XCTAssertEqual(rows.map(\.folder.id), [7, 4, 5, 6], "Systemordner dürfen nicht in der Liste stehen")
        XCTAssertEqual(rows.map(\.name), ["Familie", "Projekte", "Rabe", "Design"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 2])
    }

    /// Ein Konto mit anderem Trennzeichen (`.` wie bei manchen Providern).
    func testFolderTreeUsesTheAccountsDelimiter() {
        let rows = Pickers.folderTree([
            folder(1, "Rechnungen", delimiter: "."),
            folder(2, "Rechnungen.2026", delimiter: "."),
        ])
        XCTAssertEqual(rows.map(\.name), ["Rechnungen", "2026"])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
    }

    /// Ohne eigene Ordner bleibt die Sektion leer — die Seitenleiste blendet
    /// sie dann ganz aus (kein leerer „ORDNER“-Kopf).
    func testOnlySystemFoldersGiveNoRows() {
        let rows = Pickers.folderTree([
            folder(1, "INBOX", role: "inbox"),
            folder(2, "Trash", role: "trash"),
            folder(3, "All Mail", role: "all"),
        ])
        XCTAssertTrue(rows.isEmpty)
    }

    /// M2.11b/M2.15: laden erst mit Breite, Messungen nur mit passender
    /// Innenbreite — der Fall „Breite 0“ bleibt gesperrt.
    func testHTMLHeightGateStillRejectsWidthZero() {
        XCTAssertFalse(HTMLHeightGate.readyToLoad(viewWidth: 0))
        XCTAssertTrue(HTMLHeightGate.readyToLoad(viewWidth: 680))
        XCTAssertFalse(HTMLHeightGate.accepts(height: 3852, viewWidth: 608, innerWidth: 0))
        XCTAssertTrue(HTMLHeightGate.accepts(height: 156, viewWidth: 608, innerWidth: 608))
    }
}
