import AppKit
import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.9 Stufe B: das Verfassen-Panel.
/// - Reihenfolge und Zustand der Entwürfe (Entwurf §3.3, §3.4),
/// - die Fokus-Regeln (§3.6) auf der Ebene des Dispatchers,
/// - Größe und Überlauf-Regel (§3.1).
@MainActor
final class M29ComposeDockTests: XCTestCase {
    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    // MARK: Zustände

    func testOnlyOneDraftIsOpenAtATime() {
        let dock = ComposeDock()
        let draft = ids(2)
        XCTAssertTrue(dock.add(draft[0], as: .open))
        XCTAssertTrue(dock.add(draft[1], as: .open))
        XCTAssertEqual(dock.openId, draft[1])
        XCTAssertEqual(dock.state(draft[0]), .minimized)
        XCTAssertEqual(dock.barIds, [draft[0]])
    }

    func testOpeningABarMinimizesTheOpenDraftAndKeepsTheOrder() {
        let dock = ComposeDock()
        let draft = ids(3)
        dock.add(draft[0], as: .open)
        dock.add(draft[1], as: .open)          // draft[0] wird Leiste
        dock.add(draft[2], as: .open)          // draft[1] wird Leiste
        XCTAssertEqual(dock.barIds, [draft[0], draft[1]])
        dock.open(draft[0])
        XCTAssertEqual(dock.openId, draft[0])
        // Der zuletzt minimierte sitzt links neben dem offenen Panel.
        XCTAssertEqual(dock.barIds, [draft[1], draft[2]],
                       "der bisher offene Entwurf wird Leiste und rutscht an das Panel")
        XCTAssertEqual(dock.order, [draft[0], draft[1], draft[2]],
                       "die Anlagereihenfolge bleibt stabil (Fokus-Ring)")
    }

    func testTheDockHoldsAtMostFourDrafts() {
        let dock = ComposeDock()
        for id in ids(4) { XCTAssertTrue(dock.add(id, as: .open)) }
        XCTAssertTrue(dock.isFull)
        XCTAssertFalse(dock.add(UUID(), as: .open))
        XCTAssertEqual(dock.count, 4)
    }

    func testADraftInItsOwnWindowDoesNotUseADockSlot() {
        let dock = ComposeDock()
        for id in ids(4) { XCTAssertTrue(dock.add(id, as: .minimized)) }
        XCTAssertTrue(dock.isFull)
        // Ein Fenster-Entwurf ist kein Dock-Platz.
        XCTAssertTrue(dock.add(UUID(), as: .window))
        XCTAssertEqual(dock.windowIds.count, 1)
        XCTAssertEqual(dock.dockedCount, 4)
    }

    func testEscapeGoesFromMaximizedToOpenToMinimized() {
        let dock = ComposeDock()
        let draft = UUID()
        var focusBack = 0
        dock.onFocusList = { focusBack += 1 }
        dock.add(draft, as: .open)
        dock.maximize(draft)
        XCTAssertEqual(dock.state(draft), .maximized)
        dock.escapeOpenPanel()
        XCTAssertEqual(dock.state(draft), .open)
        dock.escapeOpenPanel()
        XCTAssertEqual(dock.state(draft), .minimized)
        XCTAssertEqual(focusBack, 1, "Esc im Panel gibt den Fokus an die Liste zurück")
        XCTAssertNil(dock.openId)
    }

    func testMinimumToggleClosesAndReopens() {
        let dock = ComposeDock()
        let draft = UUID()
        dock.add(draft, as: .open)
        var opens = 0
        dock.onFocusList = { opens += 1 }
        dock.toggleMinimize()
        XCTAssertEqual(dock.state(draft), .minimized)
        XCTAssertEqual(opens, 1)
        dock.toggleMinimize()
        XCTAssertEqual(dock.state(draft), .open)
    }

    func testSendingFreesTheSlotAndKeepsTheOthers() {
        let dock = ComposeDock()
        let draft = ids(3)
        dock.add(draft[0], as: .open)
        dock.add(draft[1], as: .open)
        dock.add(draft[2], as: .open)
        dock.remove(draft[2])
        XCTAssertEqual(dock.order, [draft[0], draft[1]])
        XCTAssertNil(dock.openId, "nach dem Senden bleibt der nächste als Leiste stehen")
        XCTAssertEqual(dock.barIds, [draft[0], draft[1]])
    }

    func testMovingToAWindowAndBack() {
        let dock = ComposeDock()
        let draft = UUID()
        var opened = 0
        dock.onOpenWindow = { _ in opened += 1 }
        dock.add(draft, as: .open)
        dock.moveToWindow(draft)
        XCTAssertEqual(dock.state(draft), .window)
        XCTAssertEqual(opened, 1)
        XCTAssertNil(dock.openId)
        dock.dock(draft)
        XCTAssertEqual(dock.state(draft), .open)
        XCTAssertEqual(dock.openId, draft)
    }

    // MARK: Fokus (§3.6)

    func testCycleFocusWalksThroughEveryDraftAndBackToTheList() {
        let dock = ComposeDock()
        let draft = ids(3)
        dock.add(draft[0], as: .open)
        dock.add(draft[1], as: .open)
        dock.add(draft[2], as: .open)
        // Offen ist draft[2]; der Ring läuft in Anlagereihenfolge, die Liste
        // steht hinten dran.
        XCTAssertNil(dock.cycleFocus(), "⌃Tab von der letzten Leiste führt zur Liste")
        XCTAssertFalse(dock.hasDraftFocus)
        XCTAssertEqual(dock.cycleFocus(), draft[0], "von der Liste zum ersten Entwurf")
        XCTAssertEqual(dock.state(draft[0]), .open, "eine Leiste wird beim Wechsel geöffnet")
        XCTAssertEqual(dock.cycleFocus(), draft[1])
        XCTAssertEqual(dock.state(draft[1]), .open)
        XCTAssertEqual(dock.cycleFocus(), draft[2])
        XCTAssertEqual(dock.state(draft[2]), .open)
        XCTAssertNil(dock.cycleFocus(), "nach dem letzten wieder an die Liste")
    }

    func testCycleFocusGoesBackward() {
        let dock = ComposeDock()
        let draft = ids(2)
        dock.add(draft[0], as: .open)
        dock.add(draft[1], as: .open)
        XCTAssertEqual(dock.cycleFocus(backward: true), draft[0], "rückwärts: der Entwurf davor")
        XCTAssertNil(dock.cycleFocus(backward: true), "davor kommt die Liste")
    }

    func testASingleDraftIsReachedFromTheList() {
        let dock = ComposeDock()
        let draft = UUID()
        dock.add(draft, as: .open)
        XCTAssertNil(dock.cycleFocus(), "erst die Liste …")
        XCTAssertEqual(dock.cycleFocus(), draft)
        XCTAssertTrue(dock.hasDraftFocus)
    }

    func testFocusReturnsToTheListAfterSending() {
        let dock = ComposeDock()
        let draft = UUID()
        dock.add(draft, as: .open)
        XCTAssertTrue(dock.hasDraftFocus)
        dock.remove(draft)
        XCTAssertFalse(dock.hasDraftFocus)
    }

    func testAListKeyIsNotHandledWhileADraftHasTheFocus() {
        // Die Regel selbst (zwei Zeilen), plus die Ausnahme `⌥C`.
        XCTAssertFalse(ActionDispatcher.listKeysEnabled(hasDraftFocus: true))
        XCTAssertTrue(ActionDispatcher.listKeysEnabled(hasDraftFocus: false))
        XCTAssertEqual(ActionDispatcher.modifiedListAction(flags: .option, keyCode: 8), .composeInWindow)
        XCTAssertNil(ActionDispatcher.modifiedListAction(flags: .command, keyCode: 8))
        XCTAssertNil(ActionDispatcher.modifiedListAction(flags: .option, keyCode: 0))
    }

    // MARK: Größe und Überlauf (§3.1, §3.4)

    func testPanelSizeFollowsTheDesignRules() {
        XCTAssertEqual(ComposeDock.panelWidth(contentWidth: 900), 540)
        XCTAssertEqual(ComposeDock.panelWidth(contentWidth: 600), 540, "600 − 32 bleibt über 540")
        XCTAssertEqual(ComposeDock.panelWidth(contentWidth: 480), 448)
        XCTAssertEqual(ComposeDock.panelWidth(contentWidth: 380), ComposeDock.minimumWidth)
        XCTAssertEqual(ComposeDock.panelHeight(contentHeight: 700), 560)
        XCTAssertEqual(ComposeDock.panelHeight(contentHeight: 400), 376)
        XCTAssertEqual(ComposeDock.panelHeight(contentHeight: 200), ComposeDock.minimumHeight)
    }

    func testBarOverflowPutsTheOldestIntoTheChip() {
        // 3 × 272 + 2 × 10 = 836: alle drei passen.
        XCTAssertEqual(ComposeDock.barOverflow(count: 3, available: 900).shown, 3)
        XCTAssertEqual(ComposeDock.barOverflow(count: 3, available: 836).shown, 3)
        // Bei 800 pt passen zwei Leisten und der Chip für die dritte.
        let tight = ComposeDock.barOverflow(count: 3, available: 800)
        XCTAssertEqual(tight.shown, 2)
        XCTAssertEqual(tight.hidden, 1)
        XCTAssertEqual(ComposeDock.barOverflow(count: 0, available: 500).shown, 0)
    }

    // MARK: Titel

    func testThePanelTitleFallsBackToTheDraftName() {
        let draft = ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil, to: [], cc: [],
                                 subject: "  ", client: FakeCore(), toasts: ToastCenter(),
                                 settings: SettingsStore())
        XCTAssertEqual(draft.panelTitle, draft.title)
        draft.subject = "Termin am Freitag"
        XCTAssertEqual(draft.panelTitle, "Termin am Freitag", "der Betreff gewinnt, sobald er da ist")
    }
}
