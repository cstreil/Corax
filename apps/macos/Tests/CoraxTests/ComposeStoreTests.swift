import XCTest
@testable import Corax
@testable import CoraxKit

/// W2/R-W2: draft saves are serialized, and a save that is still queued when
/// the draft is discarded must not create a draft nobody deletes.
@MainActor
final class ComposeStoreTests: XCTestCase {
    private func makeDraft(_ core: FakeCore) -> ComposeDraft {
        ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil, to: [Address(name: nil, email: "a@b.de")],
                     cc: [], subject: "s", body: "x", client: core, toasts: ToastCenter(), settings: SettingsStore())
    }

    /// W1 aus dem Audit M2: Ein Zeilenumbruch im Betreff wird von
    /// `mail-builder` roh geschrieben und wäre eine zweite Header-Zeile
    /// (`Bcc: …`, `Reply-To: …`). Er darf den Entwurf nicht verlassen.
    func testSubjectLosesHeaderLineBreaksBeforeSaving() async {
        let core = FakeCore()
        let draft = ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil,
                                 to: [Address(name: nil, email: "a@b.de")], cc: [],
                                 subject: "Hallo\r\nBcc: opfer@example.org",
                                 body: "x", client: core, toasts: ToastCenter(), settings: SettingsStore())
        XCTAssertEqual(draft.subject, "Hallo Bcc: opfer@example.org")
        _ = await draft.saveNow()
        let saved = await core.savedDrafts.last
        XCTAssertEqual(saved?.subject, "Hallo Bcc: opfer@example.org")
        XCTAssertFalse(saved?.subject.contains("\r") ?? true)
        XCTAssertFalse(saved?.subject.contains("\n") ?? true)
        // Nothing else is lost: a subject without control characters stays as typed.
        let plain = ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil, to: [], cc: [],
                                 subject: "Grüße  aus  Kiel", body: "", client: core,
                                 toasts: ToastCenter(), settings: SettingsStore())
        XCTAssertEqual(plain.subject, "Grüße  aus  Kiel")
    }

    func testOneSaveKeepsTheDraftId() async {
        let core = FakeCore()
        let draft = makeDraft(core)
        let saved = await draft.saveNow()
        XCTAssertTrue(saved)
        XCTAssertEqual(draft.draftId, 1)
        XCTAssertTrue(draft.savedOnce)
    }

    /// R-W2: save 1 is running, save 2 is queued, then `discard()`. Save 2 must
    /// not run at all, and the draft save 1 created must be deleted too.
    func testDiscardStopsAQueuedSave() async {
        let core = FakeCore()
        await core.setSaveDelay(.milliseconds(150))
        let draft = makeDraft(core)

        let first = Task { await draft.saveNow() }
        try? await Task.sleep(for: .milliseconds(40))   // save 1 is in flight
        let second = Task { await draft.saveNow() }
        // Give the second call the main actor once so it really queues behind
        // save 1 (enqueueing happens synchronously inside `saveNow`).
        try? await Task.sleep(for: .milliseconds(20))
        draft.discard()

        _ = await first.value
        _ = await second.value
        await draft.waitForDiscard()

        let saved = await core.savedDraftCount()
        let deleted = await core.deletedDraftIds
        XCTAssertEqual(saved, 1, "das eingereihte zweite Speichern läuft nach dem Verwerfen nicht mehr")
        XCTAssertEqual(deleted, [1], "auch der Entwurf des ersten Speicherns wird gelöscht")
        XCTAssertNil(draft.draftId)
    }
}

/// N4-Rest: settings changes are written one after the other, each write carries
/// everything still pending — no change is lost.
@MainActor
final class SettingsStoreTests: XCTestCase {
    private func store(_ core: FakeCore) async -> SettingsStore {
        let store = SettingsStore()
        store.client = core
        await store.load()
        return store
    }

    func testTwoQuickChangesBothLand() async {
        let core = FakeCore()
        let store = await store(core)
        store.set("theme", "carbon")
        store.set("accentColor", "violet")
        await store.waitForPendingWrites()

        let written = await core.lastSettings()
        let writes = await core.writtenSettings.count
        XCTAssertEqual(written["theme"], "carbon")
        XCTAssertEqual(written["accentColor"], "violet")
        XCTAssertEqual(writes, 1, "beide Änderungen gehen in einem Schreibvorgang raus")
    }

    func testTheLaterValueOfTheSameKeyWins() async {
        let core = FakeCore()
        let store = await store(core)
        store.set("theme", "paper")
        store.set("theme", "carbon")
        await store.waitForPendingWrites()

        let written = await core.lastSettings()
        XCTAssertEqual(written["theme"], "carbon")
    }
}
