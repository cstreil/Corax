import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.1: every settings editor creates, changes and deletes against `FakeCore`,
/// and the writes land in the settings object where they belong.
@MainActor
final class SettingsEditorsTests: XCTestCase {
    private var core: FakeCore!
    private var toasts: ToastCenter!
    private var platform: TestPlatform!

    override func setUp() {
        super.setUp()
        core = FakeCore()
        toasts = ToastCenter()
        platform = TestPlatform()
    }

    // MARK: Textbausteine

    func testSnippetCreateChangeDelete() async {
        let store = SnippetsStore(toasts: toasts)
        store.client = core
        await core.seedSnippets([
            Snippet(id: 1, name: "Alt", shortcut: "alt", subject: nil, bodyText: "Hallo", usageCount: 3),
        ])
        await store.load()
        XCTAssertEqual(store.items.map(\.name), ["Alt"])

        // Create
        assertTrue(await store.save(SnippetInput(id: nil, name: "Neu", shortcut: "neu", subject: "Betreff",
                                                    bodyText: "Text")))
        XCTAssertEqual(store.items.count, 2)
        let created = await core.snippetRows.first { $0.name == "Neu" }
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.shortcut, "neu")

        // Change: the usage count survives an edit.
        assertTrue(await store.save(SnippetInput(id: 1, name: "Umbenannt", shortcut: nil, subject: nil,
                                                    bodyText: "Neuer Text")))
        let edited = store.items.first { $0.id == 1 }
        XCTAssertEqual(edited?.name, "Umbenannt")
        XCTAssertEqual(edited?.usageCount, 3)
        XCTAssertNil(edited?.shortcut)

        // Delete
        assertTrue(await store.delete(1))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertFalse(store.items.contains { $0.id == 1 })
    }

    // MARK: Labels und Kategorien

    func testLabelCreateRenameDelete() async {
        let store = LabelsStore(toasts: toasts)
        store.client = core
        await core.seedLabels([
            Label(id: 10, name: "Arbeit", color: "#2563eb", keyword: "K1", position: 2, isAuto: false),
        ])
        await store.load()
        XCTAssertEqual(store.nextPosition, 3)

        assertTrue(await store.save(LabelInput(id: nil, name: "Privat", color: "#16a34a", position: store.nextPosition)))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first { $0.name == "Privat" }?.keyword, "K_1")

        assertTrue(await store.save(LabelInput(id: 10, name: "Job", color: "#d97706", position: 2)))
        XCTAssertEqual(store.items.first { $0.id == 10 }?.name, "Job")

        assertTrue(await store.delete(10))
        XCTAssertEqual(store.items.count, 1)
    }

    func testCategoriesAreSortedAfterUserLabels() async {
        let store = LabelsStore(toasts: toasts)
        store.client = core
        await core.seedLabels([
            Label(id: 1, name: "Marketing", color: "#2563eb", keyword: "ComailAutoMarketing", position: 0, isAuto: true),
            Label(id: 2, name: "Arbeit", color: "#16a34a", keyword: "K2", position: 3, isAuto: false),
        ])
        await store.load()
        XCTAssertEqual(store.sorted.map(\.name), ["Arbeit", "Marketing"])
        // A new user label goes after the highest user position, not after the category.
        XCTAssertEqual(store.nextPosition, 4)

        let created = await store.createCategory(name: "Rechnungen", color: "#dc2626", description: "Quittungen")
        XCTAssertEqual(created?.isAuto, true)
        let names = await core.createdCategories
        XCTAssertEqual(names, ["Rechnungen"])
    }

    func testRestoreAutoLabelsReloadsTheList() async {
        let store = LabelsStore(toasts: toasts)
        store.client = core
        await core.seedLabels([])
        await store.load()
        let count = await store.restoreAutoLabels()
        XCTAssertEqual(count, 2)
    }

    // MARK: Splits und Regeln

    func testSplitCreateChangeDelete() async {
        let store = SplitsStore(toasts: toasts)
        store.client = core
        await core.seedSplits([])
        await core.seedLabels([])
        await store.load()
        XCTAssertEqual(store.nextPosition, 0)

        // Create with a condition.
        let rule = await store.save(SplitInput(id: nil, name: "Rechnungen", position: 0,
                                               condition: .sender(.contains, "@lieferant.de"),
                                               target: nil, countAll: true))
        XCTAssertNotNil(rule)
        XCTAssertEqual(store.splits.count, 1)
        XCTAssertEqual(store.tabs.count, 1)

        // Change: name, target and condition.
        let id = try! XCTUnwrap(store.splits.first?.id)
        let changed = await store.save(SplitInput(id: id, name: "Belege", position: 0,
                                                  condition: .subject(.contains, "Rechnung"),
                                                  target: "other", countAll: false))
        XCTAssertEqual(changed?.name, "Belege")
        XCTAssertEqual(changed?.target, "other")

        // Delete
        assertTrue(await store.delete(id))
        XCTAssertTrue(store.splits.isEmpty)
    }

    func testSplitsMergeAutoLabelTabsByPosition() async {
        let store = SplitsStore(toasts: toasts)
        store.client = core
        await core.seedSplits([
            SplitRule(id: 1, name: "Rechnungen", position: 3),
            SplitRule(id: 2, name: "Team", position: 1),
        ])
        await core.seedLabels([
            Label(id: 9, name: "News", color: "#2563eb", keyword: "ComailAutoNews", position: 2, isAuto: true),
            Label(id: 8, name: "Arbeit", color: "#16a34a", keyword: "K8", position: 0, isAuto: false),
        ])
        await store.load()
        XCTAssertEqual(store.tabs.map(\.name), ["Team", "News", "Rechnungen"])
        XCTAssertEqual(store.nextPosition, 4)
        // A user label is no tab.
        XCTAssertFalse(store.tabs.contains { $0.name == "Arbeit" })
    }

    func testMovingATabPersistsTheSharedOrder() async {
        let store = SplitsStore(toasts: toasts)
        store.client = core
        await core.seedSplits([
            SplitRule(id: 1, name: "Erste", position: 0),
            SplitRule(id: 2, name: "Zweite", position: 1),
        ])
        await core.seedLabels([])
        await store.load()
        XCTAssertEqual(store.tabs.map(\.name), ["Erste", "Zweite"])

        assertTrue(await store.move(from: 0, to: 1))
        let order = await core.tabOrder
        XCTAssertEqual(order, [TabRef.split(2), TabRef.split(1)])
        XCTAssertEqual(store.tabs.map(\.name), ["Zweite", "Erste"])
    }

    func testSplitPreviewSendsTheCondition() async {
        let store = SplitsStore(toasts: toasts)
        store.client = core
        await core.seedSplits([])
        await core.seedLabels([])
        await store.load()
        let preview = await store.preview(.sender(.contains, "@x.de"))
        XCTAssertEqual(preview?.total, 2)
        let sent = await core.previewedConditions
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first, .sender(.contains, "@x.de"))
    }

    func testRelabelAutoLabels() async {
        let store = SplitsStore(toasts: toasts)
        store.client = core
        let count = await store.relabelAutoLabels()
        XCTAssertEqual(count, 3)
        let calls = await core.relabelCalls
        XCTAssertEqual(calls, 1)
    }

    // MARK: Accounts

    func testAccountRenameAndRemove() async {
        await core.seedAccounts([
            Account(id: 7, email: "ich@example.de", displayName: "Ich", provider: "imap",
                    authKind: "password", syncState: "idle"),
        ])
        let box = MailboxStore(toasts: toasts, settings: SettingsStore(), writeAccess: Self.gate,
                               platform: platform)
        box.client = core
        await box.bootstrap()
        XCTAssertEqual(box.accounts.count, 1)

        assertTrue(await box.renameAccount(7, to: "Neuer Name"))
        let renamed = await core.renamedAccounts
        XCTAssertEqual(renamed.first?.name, "Neuer Name")
        XCTAssertEqual(box.accounts.first?.displayName, "Neuer Name")

        assertTrue(await box.removeAccount(7))
        let removed = await core.removedAccountIDs
        XCTAssertEqual(removed, [7])
        XCTAssertTrue(box.accounts.isEmpty)
    }

    // MARK: MCP

    func testMcpStoreMasksTheTokenAndCopiesIt() async {
        let store = McpStore(toasts: toasts, platform: platform)
        store.client = core
        await store.load()
        XCTAssertEqual(store.status?.running, true)
        XCTAssertEqual(store.clients.map(\.id), ["claude"])
        XCTAssertEqual(store.activity.count, 1)

        // Nothing fetched yet: the placeholder, not a guessed mask.
        XCTAssertEqual(store.displayedToken, "••••••••••••")
        XCTAssertFalse(store.tokenRevealed)

        assertTrue(await store.copyToken())
        XCTAssertEqual(platform.copied, ["test-token-123456"])
        XCTAssertFalse(store.tokenRevealed)

        assertTrue(await store.revealToken())
        XCTAssertEqual(store.displayedToken, "test-token-123456")
        store.hideToken()
        XCTAssertEqual(store.displayedToken, "test…3456")

        assertTrue(await store.regenerateToken())
        XCTAssertEqual(store.token, "test-token-654321")
    }

    func testMcpSnippetAndInstall() async {
        let store = McpStore(toasts: toasts, platform: platform)
        store.client = core
        assertTrue(await store.copySnippet(for: "claude"))
        XCTAssertEqual(platform.copied, ["{\"mcpServers\":{}}"])

        let result = await store.install("claude")
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.message, "eingerichtet")
    }

    // MARK: Signaturen (SettingsStore)

    private func loadedSettings() async -> SettingsStore {
        let settings = SettingsStore()
        settings.toasts = toasts
        settings.client = core
        await settings.load()
        XCTAssertTrue(settings.loaded)
        return settings
    }

    func testSignatureUpsertAndRemove() async {
        let settings = await loadedSettings()
        let first = Signature(id: "s1", accountId: 1, name: "Privat", html: "<p>Grüße</p>")
        settings.upsertSignature(first)
        await settings.waitForPendingWrites()

        var list = await lastSettings()["signatureList"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?["name"] as? String, "Privat")
        XCTAssertEqual(settings.signatures.first?.html, "<p>Grüße</p>")

        // Editing replaces in place instead of appending.
        settings.upsertSignature(Signature(id: "s1", accountId: 1, name: "Privat 2", html: "<p>Neu</p>"))
        await settings.waitForPendingWrites()
        list = await lastSettings()["signatureList"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?["name"] as? String, "Privat 2")

        // A default that points at the signature is cleared with it.
        settings.setSignatureDefaults(accountId: 1, newId: "s1", replyId: "s1")
        await settings.waitForPendingWrites()
        XCTAssertEqual(settings.signatureDefaults(for: 1).newId, "s1")

        settings.removeSignature(id: "s1")
        await settings.waitForPendingWrites()
        list = await lastSettings()["signatureList"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 0)
        let defaults = await lastSettings()["signatureDefaults"] as? [String: Any]
        XCTAssertNil(defaults?["1"])
        XCTAssertNil(settings.signatureDefaults(for: 1).newId)
    }

    func testGeneralSettingsWriteThrough() async {
        let settings = await loadedSettings()
        XCTAssertTrue(settings.soundEnabled)
        settings.set("soundEnabled", false)
        settings.set("dockBadgeEnabled", false)
        settings.set("inboxUi", "avatar")
        await settings.waitForPendingWrites()

        let written = await lastSettings()
        XCTAssertEqual(written["soundEnabled"] as? Bool, false)
        XCTAssertEqual(written["dockBadgeEnabled"] as? Bool, false)
        XCTAssertEqual(written["inboxUi"] as? String, "avatar")
        XCTAssertFalse(settings.soundEnabled)
        XCTAssertEqual(settings.inboxUI, "avatar")
    }

    func testCategoryDescriptionsWriteThrough() async {
        let settings = await loadedSettings()
        settings.setCategoryDescription("ComailAutoNews", "  Nachrichten und Digest  ")
        await settings.waitForPendingWrites()
        let written = await lastSettings()["aiCategoryDescriptions"] as? [String: Any]
        XCTAssertEqual(written?["ComailAutoNews"] as? String, "Nachrichten und Digest")
        XCTAssertEqual(settings.categoryDescription(for: "ComailAutoNews"), "Nachrichten und Digest")

        // An empty text removes the entry again.
        settings.setCategoryDescription("ComailAutoNews", "   ")
        await settings.waitForPendingWrites()
        let cleared = await lastSettings()["aiCategoryDescriptions"] as? [String: Any]
        XCTAssertNil(cleared?["ComailAutoNews"])
    }

    /// The settings object of the last write, decoded for assertions.
    private func lastSettings() async -> [String: Any] {
        let json = await core.lastSettingsJSON()
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// `XCTAssertTrue` cannot take an `async` expression (autoclosure).
    private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, file: file, line: line)
    }

    private static var gate: WriteAccess {
        WriteAccess(identifier: Instance.sandbox, mode: .sandbox)
    }
}
