import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.8c (Live-Test 2):
/// 1. Jede Wahl einer Ansicht, eines Postfachs oder Tabs verlässt den Kalender —
///    auch wenn sie die ist, die schon gesetzt war (Inbox → Kalender → Inbox).
/// 2. Ist „Automatisch weiter" aus, klappt nach dem Entfernen des offenen
///    Threads nichts auf: zurück in die Liste, Auswahl auf dem Nachbarn.
@MainActor
final class M28cTests: XCTestCase {
    private static var sandboxGate: WriteAccess { WriteAccess(identifier: Instance.sandbox, mode: .sandbox) }

    private func row(_ id: Int64, unread: Int64 = 1) -> ThreadSummary {
        ThreadSummary(id: id, accountId: 1, accountEmail: "a@b.de", subject: "S\(id)", snippet: "",
                      participants: [], lastMessageAt: 1_700_000_000_000 + id, messageCount: 1,
                      unreadCount: unread, isStarred: false, hasAttachments: false, snoozedUntil: nil,
                      labels: [])
    }

    /// Store mit Kern und geladenen Einstellungen, damit `autoAdvance` greift.
    private func coreStore(_ ids: [Int64] = [1, 2, 3, 4], autoAdvance: Bool = true)
        async -> (MailboxStore, FakeCore, SettingsStore) {
        let toasts = ToastCenter()
        let settings = SettingsStore()
        settings.toasts = toasts
        let core = FakeCore()
        settings.client = core
        await settings.load()
        settings.set("autoAdvance", autoAdvance)
        let box = MailboxStore(toasts: toasts, settings: settings,
                               writeAccess: Self.sandboxGate, platform: TestPlatform())
        box.client = core
        await core.setThreads(ids.map { row($0) })
        // Opening a thread loads its detail; without one the fake core's error
        // toast would replace the undo toast and end its window mid-test.
        await core.setDetail(ThreadDetail(thread: row(2), messages: []))
        box.applyThreads(ids.map { row($0) }, cursor: nil)
        return (box, core, settings)
    }

    private func bareStore() -> MailboxStore {
        MailboxStore(toasts: ToastCenter(), settings: SettingsStore(),
                     writeAccess: Self.sandboxGate, platform: TestPlatform())
    }

    // MARK: 1 — Kalender verlassen

    func testPickingTheSameViewClosesTheCalendar() {
        let box = bareStore()
        var left = 0
        box.onUserNavigation = { left += 1 }

        // Kalender offen, Nutzer wählt „Inbox", obwohl Inbox schon gesetzt ist.
        box.setView(.inbox)

        XCTAssertEqual(left, 1, "auch die schon gesetzte Ansicht verlässt den Kalender")
        XCTAssertEqual(box.view, .inbox)
    }

    func testPickingTheSameAccountClosesTheCalendar() {
        let box = bareStore()
        var left = 0
        box.onUserNavigation = { left += 1 }

        box.setAccount(1)
        left = 0
        box.setAccount(1)   // dasselbe Postfach noch einmal

        XCTAssertEqual(left, 1)
        XCTAssertEqual(box.accountId, 1)
    }

    func testPickingTheSameTabClosesTheCalendar() {
        let box = bareStore()
        var left = 0
        box.onUserNavigation = { left += 1 }

        box.setTab(box.currentTabID)

        XCTAssertEqual(left, 1)
        XCTAssertEqual(box.currentTabID, "important")
    }

    func testProgrammaticAccountResetKeepsTheCalendarOpen() {
        let box = bareStore()
        var left = 0
        box.onUserNavigation = { left += 1 }

        // Kontoeinstellungen entfernen das aktive Konto: kein Nutzerwunsch.
        box.setAccount(nil, byUser: false)

        XCTAssertEqual(left, 0)
    }

    // MARK: 2 — Automatisch weiter

    func testAutoAdvanceOnOpensTheNeighbour() async {
        let (box, _, _) = await coreStore(autoAdvance: true)
        box.select(2)
        box.expand(2)

        box.archive()
        await box.waitForPendingWrites()

        XCTAssertEqual(box.expandedId, 3, "Einstellung an: der Nachbar klappt auf")
        XCTAssertEqual(box.selectedId, 3)
    }

    func testAutoAdvanceOffReturnsToTheList() async {
        let (box, _, _) = await coreStore(autoAdvance: false)
        box.select(2)
        box.expand(2)

        box.archive()
        await box.waitForPendingWrites()

        XCTAssertNil(box.expandedId, "Einstellung aus: nichts klappt auf")
        XCTAssertNil(box.inlineCompose)
        XCTAssertEqual(box.selectedId, 3, "die Auswahl steht auf dem Nachbarn")
        XCTAssertEqual(box.threads.map(\.id), [1, 3, 4])
    }

    /// Jede Entfernungsart läuft durch `removeGroup`; die Einstellung gilt für alle.
    func testAutoAdvanceOffForEveryRemovingAction() async {
        let folder = FolderInfo(id: 7, accountId: 1, imapName: "Archive", delimiter: "/", role: "archive")
        let kinds = ["archive", "trash", "spam", "snooze", "move", "unarchive", "not_spam"]

        for kind in kinds {
            let (box, _, _) = await coreStore(autoAdvance: false)
            box.select(2)
            box.expand(2)
            XCTAssertEqual(box.expandedId, 2, "\(kind): Ausgangslage offen")

            switch kind {
            case "archive": box.archive()
            case "trash": box.trash()
            case "spam": box.spam()
            case "snooze": box.snooze()
            case "move": box.moveToFolder(folder)
            case "unarchive": box.unarchive()
            case "not_spam": box.notSpam()
            default: XCTFail("unbekannte Aktionsart \(kind)")
            }
            await box.waitForPendingWrites()

            XCTAssertNil(box.expandedId, "\(kind) mit „Automatisch weiter“ aus")
            XCTAssertEqual(box.selectedId, 3, "\(kind): Auswahl auf dem Nachbarn")
            XCTAssertEqual(box.threads.map(\.id), [1, 3, 4], "\(kind): offener Thread ist weg")
        }
    }

    func testAutoAdvanceOffWithAGroupWhereTheOpenThreadIsIncluded() async {
        let (box, _, _) = await coreStore(autoAdvance: false)
        box.select(2)
        box.expand(2)
        box.toggleSelect(4)
        XCTAssertEqual(box.targetIds, [2, 4])

        box.archive()
        await box.waitForPendingWrites()

        XCTAssertNil(box.expandedId, "auch die Gruppe klappt nichts auf")
        XCTAssertEqual(box.selectedId, 3, "die Zeile, die auf den Platz der ersten nachgerückt ist")
        XCTAssertEqual(box.threads.map(\.id), [1, 3])
    }

    /// Undo ist kein „Weiter" (N-P2a): der offen entfernte Thread öffnet wieder.
    func testUndoReopensTheThreadThatWasRemovedOpen() async {
        let (box, _, _) = await coreStore(autoAdvance: false)
        box.select(2)
        box.expand(2)
        box.archive()
        await box.waitForPendingWrites()
        XCTAssertNil(box.expandedId)
        box.undo()
        await box.waitForPendingWrites()
        XCTAssertEqual(box.expandedId, 2, "Undo öffnet den Thread wieder")
        XCTAssertEqual(box.selectedId, 2)
    }
}
