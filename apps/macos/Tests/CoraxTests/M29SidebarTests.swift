import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.9 Stufe A: Seitenleiste und Werkzeugleiste.
/// - die Breitenregel aus dem Entwurf (§1.3),
/// - der Ordnerbaum der Seitenleiste,
/// - der Label-/Ordnerfilter, der bis in den Kern durchgereicht wird.
@MainActor
final class M29SidebarTests: XCTestCase {
    private static var sandboxGate: WriteAccess { WriteAccess(identifier: Instance.sandbox, mode: .sandbox) }

    private func row(_ id: Int64, labels: [Int64] = []) -> ThreadSummary {
        ThreadSummary(id: id, accountId: 1, accountEmail: "a@b.de", subject: "S\(id)", snippet: "",
                      participants: [], lastMessageAt: 1_700_000_000_000 + id, messageCount: 1,
                      unreadCount: 1, isStarred: false, hasAttachments: false, snoozedUntil: nil, labels: labels)
    }

    /// Die Liste lädt in einem eigenen Task; die Filterprüfung wartet darauf.
    private func waitForList(_ core: FakeCore, labelId: Int64? = nil, folderId: Int64? = nil) async {
        for _ in 0..<80 {
            let queries = await core.listQueries
            if queries.contains(where: { $0.labelId == labelId && $0.folderId == folderId }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("die Liste hat den Filter nicht abgerufen")
    }

    private func coreStore(_ ids: [Int64] = [1, 2, 3]) async -> (MailboxStore, FakeCore) {
        let core = FakeCore()
        await core.setThreads(ids.map { row($0) })
        let box = MailboxStore(toasts: ToastCenter(), settings: SettingsStore(),
                               writeAccess: Self.sandboxGate, platform: TestPlatform())
        box.client = core
        box.applyThreads(ids.map { row($0) }, cursor: nil)
        return (box, core)
    }

    // MARK: Breitenregel

    func testSidebarIsVisibleOnAWideWindow() {
        XCTAssertTrue(SidebarState.visible(userWants: true, forced: false, windowWidth: 1200))
        XCTAssertTrue(SidebarState.visible(userWants: true, forced: false, windowWidth: SidebarState.autoHideWidth))
    }

    func testSidebarHidesByItselfOnANarrowWindow() {
        XCTAssertFalse(SidebarState.visible(userWants: true, forced: false, windowWidth: 800))
        XCTAssertFalse(SidebarState.visible(userWants: true, forced: false, windowWidth: SidebarState.autoHideWidth - 1))
    }

    func testAutoHideWidthKeepsTheContentUsable() {
        // 232 pt Leiste + 640 pt Inhalt: darunter klappt sie ein (Entwurf §1.3).
        XCTAssertEqual(SidebarState.autoHideWidth, 872)
    }

    func testTheUsersChoiceWins() {
        XCTAssertFalse(SidebarState.visible(userWants: false, forced: false, windowWidth: 1600),
                       "wer sie ausgeblendet hat, behält sie auch im breiten Fenster zu")
        XCTAssertTrue(SidebarState.visible(userWants: true, forced: true, windowWidth: 800),
                      "ausdrücklich eingeblendet gilt auch im schmalen Fenster")
    }

    func testToggleUnderTheAutoHideWidthForcesTheSidebar() {
        let defaults = UserDefaults(suiteName: "corax.test.sidebar.\(UUID().uuidString)")!
        let state = SidebarState(defaults: defaults)
        state.update(windowWidth: 800)
        XCTAssertFalse(state.isVisible, "schmal: von selbst eingeklappt")
        XCTAssertTrue(state.isHiddenByWidth)

        state.toggle()
        XCTAssertTrue(state.isVisible, "ein Klick blendet sie auch dort ein")
        XCTAssertEqual(state.userWantsVisible, true)

        state.toggle()
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.userWantsVisible, "und das ist dann gespeichert")
    }

    func testWidthChangeKeepsTheUsersChoice() {
        let defaults = UserDefaults(suiteName: "corax.test.sidebar.\(UUID().uuidString)")!
        let state = SidebarState(defaults: defaults)
        state.update(windowWidth: 1200)
        XCTAssertTrue(state.isVisible)

        state.update(windowWidth: 800)
        XCTAssertFalse(state.isVisible, "schmal: automatisch eingeklappt")
        XCTAssertTrue(state.userWantsVisible, "die Nutzerwahl bleibt, sie kommt beim Verbreitern zurück")

        state.update(windowWidth: 1200)
        XCTAssertTrue(state.isVisible)
    }

    // MARK: Ordnerbaum

    private func folder(_ id: Int64, _ name: String, role: String? = nil, delimiter: String? = "/") -> FolderInfo {
        FolderInfo(id: id, accountId: 1, imapName: name, delimiter: delimiter, role: role)
    }

    func testFolderTreeDropsTheSystemFolders() {
        let rows = Pickers.folderTree([
            folder(1, "INBOX", role: "inbox"),
            folder(2, "Sent", role: "sent"),
            folder(3, "Archive", role: "archive"),
            folder(4, "Projekte"),
        ])
        XCTAssertEqual(rows.map(\.name), ["Projekte"], "Systemordner stehen schon als Ansichten da")
    }

    func testFolderTreeIndentsByPath() {
        let rows = Pickers.folderTree([
            folder(1, "Projekte"),
            folder(2, "Projekte/Website"),
            folder(3, "Projekte/Website/M2"),
        ])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
        XCTAssertEqual(rows.map(\.name), ["Projekte", "Website", "M2"])
    }

    func testFolderTreeStripsTheGmailPrefix() {
        let rows = Pickers.folderTree([folder(1, "[Gmail]/Rechnungen")])
        XCTAssertEqual(rows.map(\.name), ["Rechnungen"])
        XCTAssertEqual(rows.map(\.depth), [0])
    }

    // MARK: Filter

    func testSelectingALabelFiltersTheListAndReachesTheCore() async throws {
        let core = FakeCore()
        await core.seedLabels([CoraxKit.Label(id: 9, name: "Arbeit", color: "#2563eb", keyword: "K9",
                                            position: 1, isAuto: false)])
        let box = MailboxStore(toasts: ToastCenter(), settings: SettingsStore(),
                               writeAccess: Self.sandboxGate, platform: TestPlatform())
        box.client = core
        await box.bootstrap()

        box.selectLabel(9)
        await waitForList(core, labelId: 9)

        XCTAssertEqual(box.filterLabelId, 9)
        XCTAssertEqual(box.view, .all, "ein Label ist ein Querschnitt durch alle Ansichten")
        XCTAssertEqual(box.title, "Arbeit")
        let queries = await core.listQueries
        let query = try XCTUnwrap(queries.last { $0.labelId == 9 })
        XCTAssertNil(query.folderId)
    }

    func testSelectingAFolderFiltersTheList() async throws {
        let (box, core) = await coreStore()
        let target = FolderInfo(id: 7, accountId: 1, imapName: "Projekte/Website", delimiter: "/", role: nil)

        box.selectFolder(target)
        await waitForList(core, folderId: 7)

        XCTAssertEqual(box.filterFolderId, 7)
        XCTAssertNil(box.filterLabelId)
        XCTAssertEqual(box.title, "Website")
        let queries = await core.listQueries
        XCTAssertTrue(queries.contains { $0.folderId == 7 }, "der Filter geht als folderId in den Kern")
    }

    func testPickingAViewDropsTheFilter() async {
        let (box, _) = await coreStore()
        box.selectLabel(9)
        XCTAssertNotNil(box.filterLabelId)

        box.setView(.inbox)

        XCTAssertNil(box.filterLabelId, "die Wahl einer Ansicht hebt den Label-Filter auf")
        XCTAssertEqual(box.view, .inbox)
    }

    func testPickingTheSameViewWhileFilteredAlsoDropsTheFilter() async {
        let (box, _) = await coreStore()
        box.selectLabel(9)
        XCTAssertEqual(box.view, .all, "ein Label setzt die Ansicht auf Alle")

        // Die Ansicht ist schon .all — der Filter muss trotzdem weichen.
        box.setView(.all)

        XCTAssertNil(box.filterLabelId)
        XCTAssertEqual(box.view, .all)
    }

    func testSelectingAnotherAccountDropsTheFilter() async {
        let (box, _) = await coreStore()
        box.selectFolder(FolderInfo(id: 7, accountId: 1, imapName: "Projekte", delimiter: "/", role: nil))
        box.setAccount(2)
        XCTAssertNil(box.filterFolderId)
    }

    func testTheLabelBadgeComesFromTheCounts() {
        let box = MailboxStore(toasts: ToastCenter(), settings: SettingsStore(),
                               writeAccess: Self.sandboxGate, platform: TestPlatform())
        // Ohne Zähler: 0, nicht abstürzen.
        XCTAssertEqual(box.badge(for: .inbox), 0)
        XCTAssertEqual(box.labelBadge(3), 0)
    }
}
