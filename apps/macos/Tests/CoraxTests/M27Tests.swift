import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.7: the two follow-ups from the audit's re-check — N2 (a deferred
/// `mark_read` must not be lost when the app quits) and W7 (a group action
/// above 500 threads is refused instead of losing its undo).
@MainActor
final class M27Tests: XCTestCase {
    private func row(_ id: Int64, unread: Int64 = 1) -> ThreadSummary {
        ThreadSummary(id: id, accountId: 1, accountEmail: "a@b.de", subject: "S\(id)", snippet: "",
                      participants: [], lastMessageAt: 1_700_000_000_000 + id, messageCount: 1,
                      unreadCount: unread, isStarred: false, hasAttachments: false, snoozedUntil: nil,
                      labels: [])
    }

    private static var sandboxGate: WriteAccess { WriteAccess(identifier: Instance.sandbox, mode: .sandbox) }

    private func store(_ rows: [ThreadSummary], core: FakeCore, toasts: ToastCenter) -> MailboxStore {
        let box = MailboxStore(toasts: toasts, settings: SettingsStore(),
                               writeAccess: Self.sandboxGate, platform: TestPlatform())
        box.client = core
        box.applyThreads(rows, cursor: nil)
        return box
    }

    // MARK: N2 — quitting inside the label window

    /// A label action holds `mark_read` back (W6). Quitting must send it before
    /// the core shuts down, in the order the actions were queued.
    func testQuittingFlushesTheDeferredReadBeforeShutdown() async {
        let toasts = ToastCenter()
        let core = FakeCore()
        let rows = [row(1), row(2)]
        await core.setThreads(rows)
        let box = store(rows, core: core, toasts: toasts)

        box.setLabel(7, applied: true)   // label ticket: no toast, 30 s window
        box.expand(1)                    // unread → mark_read held back
        await box.flushBeforeTermination()

        let actions = await core.actions
        XCTAssertEqual(actions.map(\.kind), ["add_label", "mark_read"],
                       "the read goes out after the label, before the shutdown")
        XCTAssertEqual(actions.last?.threadIds, [1])
    }

    /// Without a pending read the flush is a no-op and does not hang.
    func testQuittingWithoutADeferredReadIsQuick() async {
        let toasts = ToastCenter()
        let core = FakeCore()
        let rows = [row(1, unread: 0)]
        await core.setThreads(rows)
        let box = store(rows, core: core, toasts: toasts)

        await box.flushBeforeTermination()
        let actions = await core.actions
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: W7 — group bound

    func testGroupActionAcceptsExactly500Threads() async {
        let toasts = ToastCenter()
        let core = FakeCore()
        let rows = (1...500).map { row(Int64($0)) }
        await core.setThreads(rows)
        let box = store(rows, core: core, toasts: toasts)
        box.selectAllVisible()

        box.archive()
        await box.waitForPendingWrites()

        XCTAssertEqual(box.threads.count, 0, "all 500 left the list")
        let actions = await core.actions
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].kind, "archive")
        XCTAssertEqual(actions[0].threadIds.count, 500)
    }

    func testGroupActionRefusesMoreThan500Threads() async {
        let toasts = ToastCenter()
        let core = FakeCore()
        let rows = (1...501).map { row(Int64($0)) }
        await core.setThreads(rows)
        let box = store(rows, core: core, toasts: toasts)
        box.selectAllVisible()
        XCTAssertEqual(box.targetIds.count, 501, "⌘A may select more than the bound")

        box.archive()
        await box.waitForPendingWrites()

        XCTAssertEqual(box.threads.count, 501, "nothing is removed")
        XCTAssertEqual(toasts.current?.text, GroupActionLimit.message)
        let actions = await core.actions
        XCTAssertTrue(actions.isEmpty, "no core call")
    }

    /// Every group action is behind the bound, not just archive.
    func testEveryGroupActionRefusesAboveTheBound() async {
        let toasts = ToastCenter()
        let core = FakeCore()
        let rows = (1...501).map { row(Int64($0)) }
        await core.setThreads(rows)
        let box = store(rows, core: core, toasts: toasts)
        box.selectAllVisible()
        let ids = rows.map(\.id)
        let folder = FolderInfo(id: 9, accountId: 1, imapName: "Archive", delimiter: "/", role: "archive")

        box.archive()
        box.trash()
        box.spam()
        box.snooze()
        box.toggleStar()
        box.toggleUnread()
        box.setLabel(7, applied: true)
        box.moveToFolder(folder)
        box.deletePermanently(ids: ids)
        await box.waitForPendingWrites()

        let actions = await core.actions
        XCTAssertTrue(actions.isEmpty, "no action reached the core")
        XCTAssertEqual(box.threads.count, 501)
        XCTAssertEqual(toasts.current?.text, GroupActionLimit.message)
    }
}
