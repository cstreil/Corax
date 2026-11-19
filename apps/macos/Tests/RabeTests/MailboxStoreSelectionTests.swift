import XCTest
@testable import Rabe
@testable import RabeKit

/// W3 (Audit P2): after a list update the selection follows the neighbour of the
/// thread that disappeared, and an expanded thread collapses with a toast.
@MainActor
final class MailboxStoreSelectionTests: XCTestCase {
    private func row(_ id: Int64, unread: Int64 = 1) -> ThreadSummary {
        ThreadSummary(id: id, accountId: 1, accountEmail: "a@b.de", subject: "S\(id)", snippet: "",
                      participants: [], lastMessageAt: 1_700_000_000_000 + id, messageCount: 1,
                      unreadCount: unread, isStarred: false, hasAttachments: false, snoozedUntil: nil, labels: [])
    }

    private func store() -> MailboxStore {
        MailboxStore(toasts: ToastCenter(), settings: SettingsStore(), writeAccess: Self.sandboxGate, platform: TestPlatform())
    }

    /// P2g: the sandbox gate is always open, so the stores behave as before.
    private static var sandboxGate: WriteAccess { WriteAccess(identifier: Instance.sandbox, mode: .sandbox) }

    func testFirstPageSelectsRowOne() {
        let box = store()
        box.applyThreads([row(1), row(2)], cursor: nil)
        XCTAssertEqual(box.selectedId, 1)
    }

    func testSelectionMovesToNeighbourWhenThreadDisappears() {
        let box = store()
        box.applyThreads([row(1), row(2), row(3), row(4)], cursor: nil)
        box.select(3)
        // 3 is gone (archived elsewhere): the selection stays at that position.
        box.applyThreads([row(1), row(2), row(4)], cursor: nil)
        XCTAssertEqual(box.selectedId, 4, "Nachbar an derselben Position")
        XCTAssertTrue(box.shouldIgnoreActionOnAutoSelection(), "erste Aktionstaste wird ignoriert")
    }

    func testLastRowDisappearsSelectsNewLast() {
        let box = store()
        box.applyThreads([row(1), row(2)], cursor: nil)
        box.select(2)
        box.applyThreads([row(1)], cursor: nil)
        XCTAssertEqual(box.selectedId, 1)
    }

    func testExpandedThreadThatDisappearsCollapsesWithToast() {
        let box = store()
        box.applyThreads([row(1), row(2), row(3)], cursor: nil)
        box.select(2)
        box.expand(2)
        XCTAssertEqual(box.expandedId, 2)
        box.applyThreads([row(1), row(3)], cursor: nil)
        XCTAssertNil(box.expandedId)
        XCTAssertEqual(box.toasts.current?.text, "Thread wurde verschoben")
        XCTAssertEqual(box.selectedId, 3)
    }

    func testUserNavigationDoesNotArmTheGuard() {
        let box = store()
        box.applyThreads([row(1), row(2)], cursor: nil)
        box.select(2)
        box.setView(.all)          // user navigation: next apply must not arm it
        box.applyThreads([row(1)], cursor: nil)
        XCTAssertFalse(box.shouldIgnoreActionOnAutoSelection())
    }

    func testStayingSelectionKeepsTheGuardOff() {
        let box = store()
        box.applyThreads([row(1), row(2)], cursor: nil)
        box.select(2)
        box.applyThreads([row(1), row(2)], cursor: nil)
        XCTAssertEqual(box.selectedId, 2)
        XCTAssertFalse(box.shouldIgnoreActionOnAutoSelection())
    }
}

@MainActor
final class MailboxStoreUndoTests: XCTestCase {
    private func row(_ id: Int64, unread: Int64 = 1) -> ThreadSummary {
        ThreadSummary(id: id, accountId: 1, accountEmail: "a@b.de", subject: "S\(id)", snippet: "",
                      participants: [], lastMessageAt: 1_700_000_000_000 + id, messageCount: 1,
                      unreadCount: unread, isStarred: false, hasAttachments: false, snoozedUntil: nil, labels: [])
    }

    /// P2g: the sandbox gate is always open, so the stores behave as before.
    private static var sandboxGate: WriteAccess { WriteAccess(identifier: Instance.sandbox, mode: .sandbox) }

    private func store(with ids: [Int64]) async -> (MailboxStore, FakeCore) {
        let core = FakeCore()
        await core.setThreads(ids.map { row($0) })
        let box = MailboxStore(toasts: ToastCenter(), settings: SettingsStore(), writeAccess: Self.sandboxGate, platform: TestPlatform())
        box.client = core
        box.applyThreads(ids.map { row($0) }, cursor: nil)
        return (box, core)
    }

    /// N-P2a: while a thread is open, undo keeps the selection on it — the
    /// restored thread only reappears in the list. `E` afterwards hits the open
    /// thread, not the one that came back.
    func testUndoKeepsTheOpenThreadSelected() async {
        let (box, core) = await store(with: [1, 2, 3])
        box.select(1)
        box.archive()                          // A (1) archiviert, Auswahl rückt auf 2
        await box.waitForPendingWrites()
        XCTAssertEqual(box.selectedId, 2)

        box.expand(2)                          // B (2) geöffnet
        XCTAssertEqual(box.expandedId, 2)

        box.undo()                             // Z
        await box.waitForPendingWrites()
        let undoCount = await core.undoCount
        XCTAssertEqual(undoCount, 1)
        XCTAssertEqual(box.expandedId, 2)
        XCTAssertEqual(box.selectedId, 2, "Auswahl und offener Thread müssen übereinstimmen")
        XCTAssertNotNil(box.thread(1), "der zurückgeholte Thread steht wieder in der Liste")

        box.archive()                          // E trifft B
        await box.waitForPendingWrites()
        // The deferred `mark_read` of the neighbour that opens after archiving
        // now goes out too (the gate is on); the archive is what must hit B.
        let actions = await core.actions
        let lastArchive = actions.last { $0.kind == "archive" }
        XCTAssertEqual(lastArchive?.threadIds, [2], "E trifft den offenen Thread B, nicht den zurückgeholten A")
    }

    /// R-W1: `undo_last` took back a foreign action – the toast says so.
    func testForeignActionGetsItsOwnText() async {
        let (box, core) = await store(with: [1, 2, 3])
        box.select(1)
        box.archive()
        await box.waitForPendingWrites()
        // The newest core action is no longer ours: the thread does not come
        // back when `undo_last` runs (a foreign action was undone instead).
        await core.setThreads([row(2), row(3)])
        box.undo()
        await box.waitForPendingWrites()
        XCTAssertEqual(box.toasts.current?.text, Strings.undoForeignAction)
    }

    /// Nothing left to undo keeps the plain text.
    func testNothingToUndoKeepsThePlainText() async {
        let (box, core) = await store(with: [1, 2])
        box.select(1)
        box.archive()
        await box.waitForPendingWrites()
        await core.setThreads([row(2)])
        await core.setUndoResult(false)
        box.undo()
        await box.waitForPendingWrites()
        XCTAssertEqual(box.toasts.current?.text, Strings.undoGone)
    }

    /// With nothing open, undo selects the restored thread again.
    func testUndoSelectsTheRestoredThreadWhenNothingIsOpen() async {
        let (box, _) = await store(with: [1, 2])
        box.select(1)
        box.archive()
        await box.waitForPendingWrites()
        XCTAssertEqual(box.selectedId, 2)
        XCTAssertNil(box.expandedId)

        box.undo()
        await box.waitForPendingWrites()
        XCTAssertEqual(box.selectedId, 1)
        XCTAssertNil(box.expandedId)
    }
}
