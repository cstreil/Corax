import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.5: multi-selection and the group actions. The point of these tests is the
/// old W3/N-P2a question — "does the action hit exactly the rows the user
/// selected?" — now for a whole group, plus one undo for the group.
@MainActor
final class M25SelectionTests: XCTestCase {
    private func row(_ id: Int64, unread: Int64 = 1, starred: Bool = false, labels: [Int64] = []) -> ThreadSummary {
        ThreadSummary(id: id, accountId: 1, accountEmail: "a@b.de", subject: "S\(id)", snippet: "",
                      participants: [], lastMessageAt: 1_700_000_000_000 + id, messageCount: 1,
                      unreadCount: unread, isStarred: starred, hasAttachments: false, snoozedUntil: nil,
                      labels: labels)
    }

    private static var sandboxGate: WriteAccess { WriteAccess(identifier: Instance.sandbox, mode: .sandbox) }

    private func store(_ ids: [Int64] = [1, 2, 3, 4, 5]) -> MailboxStore {
        let box = MailboxStore(toasts: ToastCenter(), settings: SettingsStore(),
                               writeAccess: Self.sandboxGate, platform: TestPlatform())
        box.applyThreads(ids.map { row($0) }, cursor: nil)
        return box
    }

    private func coreStore(_ ids: [Int64]) async -> (MailboxStore, FakeCore) {
        let core = FakeCore()
        await core.setThreads(ids.map { row($0) })
        let box = MailboxStore(toasts: ToastCenter(), settings: SettingsStore(),
                               writeAccess: Self.sandboxGate, platform: TestPlatform())
        box.client = core
        box.applyThreads(ids.map { row($0) }, cursor: nil)
        return (box, core)
    }

    // MARK: Auswahl

    func testFirstPageSelectsRowOneInTheSelectionToo() {
        let box = store([1, 2])
        XCTAssertEqual(box.selectedId, 1)
        XCTAssertEqual(box.selectedIds, [1])
        XCTAssertEqual(box.targetIds, [1])
    }

    func testSelectAllTogglesBackToTheCursorRow() {
        let box = store([1, 2, 3])
        box.select(2)
        box.selectAllVisible()
        XCTAssertEqual(box.selectedIds, [1, 2, 3])
        XCTAssertEqual(box.targetIds, [1, 2, 3], "in Listenreihenfolge")
        box.selectAllVisible()
        XCTAssertEqual(box.selectedIds, [2], "alles ausgewählt hebt wieder auf den Cursor auf")
        XCTAssertEqual(box.targetIds, [2])
    }

    func testShiftExtendSelectsFromTheAnchor() {
        let box = store([1, 2, 3, 4, 5])
        box.select(2)
        box.extendSelection(1)                       // ⇧↓
        XCTAssertEqual(box.selectedIds, [2, 3])
        XCTAssertEqual(box.selectedId, 3)
        box.extendSelection(1)                       // ⇧↓ weiter
        XCTAssertEqual(box.selectedIds, [2, 3, 4], "weiter vom Anker aus")
        box.extendSelection(-1)                      // ⇧↑
        XCTAssertEqual(box.selectedIds, [2, 3])
        XCTAssertEqual(box.selectAnchorId, 2)
    }

    func testShiftExtendStopsAtTheListEnds() {
        let box = store([1, 2])
        box.select(1)
        box.extendSelection(-1)                       // ⇧↑ über den Anfang hinaus
        XCTAssertEqual(box.selectedIds, [1])
        box.select(2)
        box.extendSelection(1)                        // ⇧↓ über das Ende hinaus
        XCTAssertEqual(box.selectedIds, [2])
        XCTAssertEqual(box.selectedId, 2)
    }

    func testCommandClickTogglesOneRowAndKeepsTheCursorSelected() {
        let box = store([1, 2, 3])
        box.select(1)
        box.toggleSelect(3)
        XCTAssertEqual(box.selectedIds, [1, 3])
        XCTAssertEqual(box.selectedId, 3)
        box.toggleSelect(3)
        XCTAssertEqual(box.selectedIds, [1])
        XCTAssertEqual(box.selectedId, 1, "der Cursor bleibt in der Auswahl")
        XCTAssertTrue(box.isSelected(1))
        XCTAssertFalse(box.isSelected(3))
    }

    func testTheLastSelectedRowStaysSelected() {
        let box = store([1, 2])
        box.select(1)
        box.toggleSelect(1)
        XCTAssertEqual(box.selectedIds, [1], "die einzige Zeile lässt sich nicht abwählen")
        XCTAssertNotNil(box.selectedId)
    }

    func testShiftClickSelectsTheRange() {
        let box = store([1, 2, 3, 4])
        box.select(1)
        box.selectRange(4)
        XCTAssertEqual(box.selectedIds, [1, 2, 3, 4])
        XCTAssertEqual(box.selectedId, 4)
        box.selectRange(2)
        XCTAssertEqual(box.selectedIds, [1, 2, 3, 4], "additiv: nichts geht verloren")
    }

    func testNavigationCollapsesTheGroupToTheCursor() {
        let box = store([1, 2, 3])
        box.select(1)
        box.extendSelection(1)
        XCTAssertEqual(box.selectedIds.count, 2)
        box.step(1)
        XCTAssertEqual(box.selectedIds, [3], "Weiterbewegen lässt eine einzelne Zeile übrig")
        XCTAssertEqual(box.targetIds, [3])
    }

    func testSelectionIsPrunedWhenRowsLeaveTheList() {
        let box = store([1, 2, 3, 4])
        box.select(2)
        box.toggleSelect(4)
        XCTAssertEqual(box.selectedIds, [2, 4])
        box.applyThreads([row(1), row(2), row(3)], cursor: nil)
        XCTAssertEqual(box.selectedIds, [2], "verschwundene Zeilen fallen aus der Auswahl")
        XCTAssertEqual(box.selectedId, 2)
    }

    // MARK: Gruppenaktionen

    func testGroupArchiveSendsExactlyTheSelectedIdsAndOneUndo() async {
        let (box, core) = await coreStore([1, 2, 3, 4])
        box.select(1)
        box.toggleSelect(3)
        box.toggleSelect(4)
        XCTAssertEqual(box.targetIds, [1, 3, 4])

        box.archive()
        await box.waitForPendingWrites()

        let actions = await core.actions
        XCTAssertEqual(actions.count, 1, "eine Aktion für die ganze Gruppe")
        XCTAssertEqual(actions[0].kind, "archive")
        XCTAssertEqual(actions[0].threadIds, [1, 3, 4], "genau die gewählten Threads")
        XCTAssertEqual(box.toasts.current?.text, "Archiviert (3)")
        XCTAssertEqual(box.toasts.current?.actionTitle, Strings.undo, "ein Undo für die Gruppe")
        XCTAssertEqual(box.thread(2)?.id, 2, "der nicht gewählte Thread bleibt")
        XCTAssertEqual(box.selectedIds, [2], "die Auswahl rückt auf die nächste Zeile")
    }

    func testGroupUndoBringsEveryThreadBack() async {
        let (box, core) = await coreStore([1, 2, 3])
        box.selectAllVisible()
        box.archive()
        await box.waitForPendingWrites()
        XCTAssertTrue(box.threads.isEmpty)

        box.undo()
        await box.waitForPendingWrites()

        let undoCount = await core.undoCount
        XCTAssertEqual(undoCount, 1, "ein undo_last für die ganze Gruppe")
        XCTAssertEqual(Set(box.threads.map(\.id)), [1, 2, 3], "alle Threads sind zurück")
        XCTAssertEqual(box.toasts.current?.text, Strings.undone)
    }

    func testGroupStarUsesTheDirectionOfTheFirstTarget() async {
        let (box, core) = await coreStore([1, 2, 3])
        box.select(1)
        box.toggleSelect(2)
        box.toggleStar()
        await box.waitForPendingWrites()
        let actions = await core.actions
        XCTAssertEqual(actions.last?.kind, "star")
        XCTAssertEqual(actions.last?.threadIds, [1, 2])
        XCTAssertTrue(box.thread(1)?.isStarred == true)
        XCTAssertTrue(box.thread(2)?.isStarred == true)
        XCTAssertFalse(box.thread(3)?.isStarred == true)
    }

    func testGroupReadUsesTheDirectionOfTheFirstTarget() async {
        let (box, core) = await coreStore([1, 2, 3])
        box.select(1)
        box.toggleSelect(2)
        box.toggleUnread()                       // first target is unread → mark read
        await box.waitForPendingWrites()
        let actions = await core.actions
        XCTAssertEqual(actions.last?.kind, "mark_read")
        XCTAssertEqual(actions.last?.threadIds, [1, 2])
        XCTAssertFalse(box.thread(1)?.isUnread ?? true)
    }

    func testGroupMoveSendsTheFolderAndOneToast() async {
        let (box, core) = await coreStore([1, 2, 3])
        let folder = FolderInfo(id: 42, accountId: 1, imapName: "INBOX/Rechnungen", delimiter: "/", role: nil)
        box.select(1)
        box.toggleSelect(2)
        box.moveToFolder(folder)
        await box.waitForPendingWrites()
        let actions = await core.actions
        XCTAssertEqual(actions.last?.kind, "move")
        XCTAssertEqual(actions.last?.threadIds, [1, 2])
        XCTAssertEqual(actions.last?.params?.targetFolderId, 42)
        XCTAssertEqual(box.toasts.current?.text, "Verschoben nach Rechnungen (2)")
        XCTAssertEqual(box.folderName(folder), "Rechnungen")
    }

    func testLabelsSendTheLabelIdForTheGroup() async {
        let (box, core) = await coreStore([1, 2])
        box.select(1)
        box.toggleSelect(2)
        box.setLabel(7, applied: true)
        await box.waitForPendingWrites()
        var actions = await core.actions
        XCTAssertEqual(actions.last?.kind, "add_label")
        XCTAssertEqual(actions.last?.params?.labelId, 7)
        XCTAssertEqual(box.thread(1)?.labels, [7])

        box.setLabel(7, applied: false)
        await box.waitForPendingWrites()
        actions = await core.actions
        XCTAssertEqual(actions.last?.kind, "remove_label")
        XCTAssertEqual(box.thread(1)?.labels, [])
        XCTAssertFalse(box.allTargetsHaveLabel(7))
    }

    func testSpamInTheSpamViewSendsNotSpam() async {
        let (box, core) = await coreStore([1, 2])
        box.setView(.spam)
        try? await Task.sleep(for: .milliseconds(30))
        box.applyThreads([row(1), row(2)], cursor: nil)
        box.selectAllVisible()
        box.spam()
        await box.waitForPendingWrites()
        let actions = await core.actions
        XCTAssertEqual(actions.last?.kind, "not_spam")
    }

    func testPermanentDeleteHasNoUndo() async {
        let (box, core) = await coreStore([1, 2, 3])
        box.setView(.trash)
        try? await Task.sleep(for: .milliseconds(30))
        box.applyThreads([row(1), row(2)], cursor: nil)
        box.selectAllVisible()
        box.deletePermanently(ids: box.targetIds)
        await box.waitForPendingWrites()
        let actions = await core.actions
        XCTAssertEqual(actions.last?.kind, "delete_permanently")
        XCTAssertEqual(actions.last?.threadIds, [1, 2])
        XCTAssertNil(box.toasts.current?.actionTitle, "kein Rückgängig für endgültig gelöscht")
        XCTAssertTrue(box.threads.isEmpty)
    }

    /// W3 aus dem Audit M2: Der Dialog löscht die Threads, auf denen er geöffnet
    /// wurde. Rutscht währenddessen ein Nachbar in die Auswahl, bleibt er stehen.
    func testPermanentDeleteUsesTheIDsTheDialogOpenedOn() async {
        let (box, core) = await coreStore([1, 2, 3])
        box.setView(.trash)
        try? await Task.sleep(for: .milliseconds(30))
        box.applyThreads([row(1), row(2)], cursor: nil)
        box.selectAllVisible()
        let frozen = box.targetIds                 // what the dialog shows and means
        // While the dialog stands, 1 disappears (sync, another device) and 3
        // slides into the list — and with it into the live selection.
        box.applyThreads([row(2), row(3)], cursor: nil)
        box.deletePermanently(ids: frozen)
        await box.waitForPendingWrites()
        let actions = await core.actions
        XCTAssertEqual(actions.last?.kind, "delete_permanently")
        XCTAssertEqual(actions.last?.threadIds, [2], "nur die IDs aus dem Dialog, nie der Nachbar")
        XCTAssertEqual(box.threads.map(\.id), [3], "der Nachbar bleibt stehen")
    }

    /// W2 aus dem Audit M2: `undo_last` kennt `unarchive` und `not_spam` nicht —
    /// ein Rückgängig-Knopf nähme dort die vorige, fremde Aktion zurück.
    func testUnarchiveAndNotSpamOfferNoUndo() async {
        let (box, core) = await coreStore([1])
        box.unarchive()
        XCTAssertNil(box.toasts.current?.actionTitle, "kein Rückgängig für unarchive")
        box.undo()                                  // must not reach undo_last
        await box.waitForPendingWrites()
        let afterUnarchive = await core.actions
        XCTAssertFalse(afterUnarchive.contains { $0.kind == "undo_last" })

        let (spamBox, spamCore) = await coreStore([1])
        spamBox.notSpam()
        XCTAssertNil(spamBox.toasts.current?.actionTitle, "kein Rückgängig für not_spam")
        spamBox.undo()
        await spamBox.waitForPendingWrites()
        let afterNotSpam = await spamCore.actions
        XCTAssertFalse(afterNotSpam.contains { $0.kind == "undo_last" })

        // The kinds the core does know keep their undo.
        let (archiveBox, _) = await coreStore([1])
        archiveBox.archive()
        XCTAssertEqual(archiveBox.toasts.current?.actionTitle, Strings.undo)
    }

    /// W6 aus dem Audit M2: Ein Label zeigt keinen Toast, also schließt nichts
    /// sein Undo-Fenster — und das automatische Gelesen bliebe für immer lokal.
    func testLabelUndoWindowEndsAndSendsTheDeferredRead() async {
        let (box, core) = await coreStore([1, 2])
        MailboxStore.labelUndoWindow = 0.12
        defer { MailboxStore.labelUndoWindow = 30 }
        box.setLabel(7, applied: true)
        await box.waitForPendingWrites()
        box.expand(2)                               // unread → mark_read waits for the ticket
        try? await Task.sleep(for: .milliseconds(50))
        var actions = await core.actions
        XCTAssertFalse(actions.contains { $0.kind == "mark_read" }, "während des Fensters zurückgehalten")
        try? await Task.sleep(for: .milliseconds(250))
        await box.waitForPendingWrites()
        actions = await core.actions
        XCTAssertTrue(actions.contains { $0.kind == "mark_read" && $0.threadIds == [2] },
                      "nach dem Fenster geht das Gelesen an den Server")
    }

    /// K2 aus dem Audit M2: Sandbox und Release teilen sich `$TMPDIR`; nur der
    /// Vorschau-Ordner eines beendeten Prozesses ist Müll.
    func testStalePreviewDirectoriesOnlyForDeadProcesses() {
        let mine = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(AttachmentPreview.isStalePreviewDirectory("corax-preview-\(mine)"))
        XCTAssertFalse(AttachmentPreview.isStalePreviewDirectory("corax-preview-1"),
                       "launchd lebt (EPERM zählt als lebendig)")
        XCTAssertTrue(AttachmentPreview.isStalePreviewDirectory("corax-preview-99999"))
        XCTAssertTrue(AttachmentPreview.isStalePreviewDirectory("corax-preview-"),
                      "Name ohne PID ist ein Rest des alten Formats")
    }

    func testSyncNowGoesThroughTheCore() async {
        let (box, core) = await coreStore([1])
        box.syncNow()
        try? await Task.sleep(for: .milliseconds(60))
        let calls = await core.syncCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testFolderLoadUsesTheSelectionAccount() async {
        let (box, core) = await coreStore([1, 2])
        await core.seedFolders([FolderInfo(id: 3, accountId: 1, imapName: "INBOX", delimiter: "/", role: "inbox")])
        await box.loadFolders()
        let queries = await core.folderQueries
        XCTAssertEqual(queries, [1])
        XCTAssertEqual(box.folders.count, 1)
    }
}

/// M2.5: the pickers (folder/label/snippet ranking), the time parser, the quote
/// block and the composer (attachments, snippets, send variants).
@MainActor
final class M25PickerTests: XCTestCase {
    private func folder(_ id: Int64, _ name: String, role: String? = nil) -> FolderInfo {
        FolderInfo(id: id, accountId: 1, imapName: name, delimiter: "/", role: role)
    }

    func testMoveCandidatesSkipDraftsAndTheCurrentView() {
        let folders = [
            folder(1, "INBOX", role: "inbox"),
            folder(2, "Archiv", role: "archive"),
            folder(3, "Entwürfe", role: "drafts"),
            folder(4, "Rechnungen"),
            folder(5, "INBOX/Abo"),
        ]
        let inbox = Pickers.moveCandidates(folders, view: .inbox, query: "")
        XCTAssertEqual(inbox.map(\.id), [2, 4, 5], "ohne Posteingang und ohne Entwürfe")
        let done = Pickers.moveCandidates(folders, view: .done, query: "")
        XCTAssertEqual(done.map(\.id), [1, 4, 5], "in Erledigt fehlt das Archiv")
        let all = Pickers.moveCandidates(folders, view: .all, query: "")
        XCTAssertEqual(all.map(\.id), [1, 2, 4, 5], "in Alle bleibt jeder Ordner außer Entwürfe")
    }

    func testMoveCandidatesRankTheBestMatchFirst() {
        let folders = [folder(1, "Archiv"), folder(2, "Rechnungen"), folder(3, "Abo Briefe")]
        let matches = Pickers.moveCandidates(folders, view: .inbox, query: "rech")
        XCTAssertEqual(matches.map(\.id), [2])
        let partial = Pickers.moveCandidates(folders, view: .inbox, query: "ar")
        XCTAssertEqual(partial.first?.id, 1, "„Archiv“ gewinnt gegen „Briefe“")
    }

    func testFolderNameDropsTheGmailPrefixAndShowsTheLeaf() {
        let gmail = folder(1, "[Gmail]/Alle Nachrichten")
        XCTAssertEqual(Pickers.folderName(gmail), "Alle Nachrichten")
        let nested = FolderInfo(id: 2, accountId: 1, imapName: "INBOX/Projekte/Rabe", delimiter: "/", role: nil)
        XCTAssertEqual(Pickers.folderName(nested), "Rabe")
    }

    func testLabelAndSnippetRanking() {
        let labels = [
            Label(id: 1, name: "Rechnungen", color: "#e5484d", keyword: "K1", position: 0, isAuto: false),
            Label(id: 2, name: "Reisen", color: "#7c5cff", keyword: "K2", position: 1, isAuto: false),
        ]
        XCTAssertEqual(Pickers.labelCandidates(labels, query: "rei").map(\.id), [2],
                       "beide beginnen mit „rei“ – „Reisen“ passt auf das ganze Wort")
        XCTAssertEqual(Pickers.labelCandidates(labels, query: "rech").map(\.id), [1])
        let snippets = [
            Snippet(id: 1, name: "Absage", shortcut: nil, subject: nil, bodyText: "Leider nein.", usageCount: 0),
            Snippet(id: 2, name: "Zusage", shortcut: nil, subject: nil, bodyText: "Gerne.", usageCount: 0),
        ]
        XCTAssertEqual(Pickers.snippetCandidates(snippets, query: "zus").map(\.id), [2])
        XCTAssertEqual(Pickers.snippetCandidates(snippets, query: "").count, 2)
    }

    func testCommandScorePrefersTheWordBeginning() {
        XCTAssertGreaterThan(CommandScore.score("Archiv", "ar"), CommandScore.score("Brief", "ar"))
        XCTAssertEqual(CommandScore.score("Rechnungen", "rechnungen"), 1, accuracy: 0.001)
        XCTAssertEqual(CommandScore.score("Rechnungen", "xyz"), 0, accuracy: 0.0001)
    }

    func testDomainSplitSuggestion() {
        let suggestion = Pickers.domainSplit(for: " Ana@Example.com ")
        XCTAssertEqual(suggestion?.domain, "example.com")
        XCTAssertEqual(suggestion?.name, "example", "die bekannte Endung fällt weg")
        XCTAssertEqual(suggestion?.sender, "@example.com")
        XCTAssertNil(Pickers.domainSplit(for: "kaputt"))
        XCTAssertNil(Pickers.domainSplit(for: "@example.com"))
    }

    func testNaturalTimeGermanAndShortForms() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10, minute: 0))!

        let inTwoHours: Double = NaturalTime.parse("in 2 stunden", now: now)?.at.timeIntervalSince(now) ?? 0
        XCTAssertEqual(inTwoHours, 2 * 3600, accuracy: 1)
        let halfHour: Double = NaturalTime.parse("30m", now: now)?.at.timeIntervalSince(now) ?? 0
        XCTAssertEqual(halfHour, 1800, accuracy: 1)
        let tonight = NaturalTime.parse("heute abend", now: now)
        XCTAssertEqual(calendar.component(.hour, from: tonight!.at), 19)
        let tomorrow = NaturalTime.parse("morgen", now: now)
        XCTAssertEqual(calendar.component(.hour, from: tomorrow!.at), 9)
        let clock = NaturalTime.parse("14:30", now: now)
        XCTAssertEqual(calendar.component(.hour, from: clock!.at), 14)
        XCTAssertEqual(calendar.component(.minute, from: clock!.at), 30)
        // 09:00 has passed → the next occurrence is tomorrow.
        let passed = NaturalTime.parse("09:00", now: now)
        XCTAssertTrue(passed!.at > now)
        XCTAssertNil(NaturalTime.parse("irgendwann", now: now))
    }

    func testQuoteBlockPrefixesEveryLine() {
        let block = Quoting.block("Erste Zeile\n\nZweite Zeile")
        XCTAssertEqual(block, "> Erste Zeile\n>\n> Zweite Zeile")
        XCTAssertEqual(Quoting.block("> schon zitiert"), "> schon zitiert", "nicht doppelt zitieren")
        XCTAssertEqual(Quoting.block("   "), "")
    }

    // MARK: Composer

    private func draft(_ core: FakeCore) -> ComposeDraft {
        ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil,
                     to: [Address(name: nil, email: "a@b.de")], cc: [], subject: "Test",
                     client: core, toasts: ToastCenter(), settings: SettingsStore())
    }

    private func tempFile(_ name: String, bytes: Int) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m25-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: bytes))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url.path
    }

    func testAttachmentsAreAddedCountedAndRemoved() async {
        let core = FakeCore()
        let draft = draft(core)
        let first = tempFile("Bericht.pdf", bytes: 2048)
        let second = tempFile("Bild.png", bytes: 1024)
        XCTAssertEqual(draft.addAttachments(paths: [first, second]), 2)
        XCTAssertEqual(draft.attachments.count, 2)
        // Die Größe wird im Hintergrund gelesen (eine Datei in iCloud blockiert
        // sonst im Layout, siehe M2.5-Walkthrough).
        for _ in 0..<100 where draft.attachmentsBytes != 3072 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(draft.attachmentsBytes, 3072)
        XCTAssertEqual(draft.addAttachments(paths: [first]), 0, "dieselbe Datei kommt nicht doppelt")
        XCTAssertEqual(draft.addAttachments(paths: ["/gibt/es/nicht"]), 0)
        draft.removeAttachment(draft.attachments[0])
        XCTAssertEqual(draft.attachments.map(\.filename), ["Bild.png"])
    }

    func testAttachmentsTravelWithTheSavedDraft() async {
        let core = FakeCore()
        let draft = draft(core)
        let path = tempFile("Anlage.txt", bytes: 12)
        draft.addAttachments(paths: [path])
        _ = await draft.saveNow()
        let saved = await core.savedDrafts
        XCTAssertEqual(saved.last?.attachments.count, 1)
        XCTAssertEqual(saved.last?.attachments.first?.filename, "Anlage.txt")
    }

    func testSnippetInsertsTextAndASubjectOnlyWhenEmpty() {
        let core = FakeCore()
        let draft = draft(core)
        let snippet = Snippet(id: 9, name: "Zusage", shortcut: nil, subject: "Termin bestätigt",
                              bodyText: "Gerne, der Termin passt.", usageCount: 0)
        draft.insertSnippet(snippet)
        XCTAssertEqual(draft.body, "Gerne, der Termin passt.")
        draft.subject = ""
        draft.insertSnippet(snippet)
        XCTAssertEqual(draft.subject, "Termin bestätigt")
    }

    func testQuoteGoesAboveTheExistingText() {
        let core = FakeCore()
        let draft = draft(core)
        draft.body = "Meine Antwort steht schon hier."
        draft.insertQuote("Das ist zitiert.")
        XCTAssertTrue(draft.body.hasPrefix("> Das ist zitiert."))
        XCTAssertTrue(draft.body.hasSuffix("Meine Antwort steht hier.") == false)
        XCTAssertTrue(draft.body.contains("Meine Antwort steht schon hier."))
    }

    func testSendLaterPassesTheDeliveryTimeAndSkipsUndo() async {
        let core = FakeCore()
        let draft = draft(core)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        draft.send(variant: .later(date), onSent: {}, onUndo: { _ in })
        for _ in 0..<60 {
            let sent = await core.queuedSends
            if !sent.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let sent = await core.queuedSends
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].sendAt, Int64(date.timeIntervalSince1970 * 1000))
    }

    func testInstantSendUsesTheCurrentTime() async {
        let core = FakeCore()
        let draft = draft(core)
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        draft.send(variant: .instant, onSent: {}, onUndo: { _ in })
        for _ in 0..<60 {
            let sent = await core.queuedSends
            if !sent.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let sent = await core.queuedSends
        XCTAssertEqual(sent.count, 1)
        XCTAssertGreaterThanOrEqual(sent[0].sendAt ?? 0, before)
        XCTAssertLessThanOrEqual(sent[0].sendAt ?? 0, Int64(Date().timeIntervalSince1970 * 1000) + 1000)
    }
}
