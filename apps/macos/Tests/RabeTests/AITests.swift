import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.3: every AI feature against `FakeCore` — one success and one error path
/// each, no key and no network (requirement 9). The decoding tests pin the DTO
/// shapes of `models.rs`, the tests at the bottom the policy entries.
@MainActor
final class AITests: XCTestCase {
    private var core: FakeCore!
    private var toasts: ToastCenter!

    override func setUp() {
        super.setUp()
        core = FakeCore()
        toasts = ToastCenter()
    }

    private func makeStore() -> AIStore {
        let store = AIStore(toasts: toasts)
        store.client = core
        return store
    }

    private func makeAssist() -> AIAssistStore {
        let store = AIAssistStore(toasts: toasts)
        store.client = core
        return store
    }

    private func makeDraft(mode: ComposeMode = .reply, body: String = "Alter Text") -> ComposeDraft {
        ComposeDraft(mode: mode, accountId: 1, inReplyTo: 5, to: [Address(name: nil, email: "ana@example.test")],
                     cc: [], subject: "Re: Termin", body: body, threadId: 7, senderName: "Christian",
                     client: core, toasts: toasts, settings: SettingsStore())
    }

    private var notConfigured: RabeClientError { .core(code: "ai_not_configured", message: "") }
    private var networkDown: RabeClientError { .core(code: "network", message: "down") }

    // MARK: - Settings and configuration (requirement 6)

    func testStatusSuccess() async {
        let store = makeStore()
        await store.refreshStatus()
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(store.status?.model, "fake-model")
        XCTAssertNil(store.lastFailure)
        let calls = await core.aiCalls
        XCTAssertEqual(calls, ["ai_status"])
    }

    func testStatusFailureShowsNotConfigured() async {
        await core.setAIError(notConfigured)
        let store = makeStore()
        await store.refreshStatus()
        XCTAssertNil(store.status)
        XCTAssertEqual(store.lastFailure, .notConfigured)
        XCTAssertEqual(store.lastFailure?.text, Strings.aiNotConfigured)
    }

    func testSaveKeyWritesOnlyTheKey() async {
        let store = makeStore()
        let ok = await store.saveKey("  fake-key  ")
        XCTAssertTrue(ok)
        let saved = await core.savedAIKey
        XCTAssertEqual(saved, "fake-key", "der Wert wird getrimmt und unverändert weitergereicht")
        // Nothing of the value ends up in a toast: it says only that it was saved.
        XCTAssertEqual(toasts.current?.text, "Schlüssel gespeichert")
        XCTAssertFalse(toasts.current?.text.contains("fake-key") ?? false)
    }

    func testSaveKeyFailureIsReported() async {
        await core.setAIError(networkDown)
        let store = makeStore()
        let ok = await store.saveKey("x")
        XCTAssertFalse(ok)
        XCTAssertEqual(store.lastFailure, .message(Strings.errorText(networkDown)))
        let saved = await core.savedAIKey
        XCTAssertNil(saved, "kein Schlüssel bei einem Fehler")
    }

    func testSaveDecisionKey() async {
        let store = makeStore()
        let ok = await store.saveDecisionKey(provider: "openrouter", key: "dkey")
        XCTAssertTrue(ok)
        let saved = await core.savedDecisionKey
        XCTAssertEqual(saved?.provider, "openrouter")
        XCTAssertEqual(saved?.key, "dkey")
    }

    func testUsageEmbeddingAndVoice() async {
        let store = makeStore()
        await store.refreshUsage()
        XCTAssertEqual(store.usage?.totalRequests, 4)
        await store.refreshEmbedding()
        XCTAssertEqual(store.embedding?.pending, 4)
        let profile = await store.learnVoice()
        XCTAssertEqual(profile, "Kurz und freundlich.")
        XCTAssertEqual(store.voiceProfile, "Kurz und freundlich.")
    }

    func testDecisionTestAndReindex() async {
        let store = makeStore()
        let results = await store.testDecisionProviders()
        XCTAssertEqual(results?.count, 1)
        XCTAssertEqual(store.decisionResults?.first?.ok, true)
        let queued = await store.reindex()
        XCTAssertEqual(queued, 12)
        XCTAssertFalse(store.reindexing)
    }

    func testDecisionTestFailureKeepsTheError() async {
        await core.setAIError(networkDown)
        let store = makeStore()
        let results = await store.testDecisionProviders()
        XCTAssertNil(results)
        XCTAssertNil(store.decisionResults)
        XCTAssertNotNil(store.decisionTestError)
    }

    // MARK: - Thread summary (requirement 1)

    func testSummarySuccess() async {
        let assist = makeAssist()
        await assist.summarize(7)
        let state = assist.summaryState(7)
        XCTAssertEqual(state?.pending, false)
        XCTAssertEqual(state?.summary?.keyPoints, ["Rechnung offen"])
        XCTAssertEqual(state?.summary?.nextAction, "Zahlen")
        XCTAssertNil(state?.failure)
        let calls = await core.aiCalls
        XCTAssertEqual(calls, ["ai_summarize"])
    }

    func testSummaryFailureAndNotConfigured() async {
        await core.setAIError(notConfigured)
        let assist = makeAssist()
        await assist.summarize(7)
        XCTAssertEqual(assist.summaryState(7)?.failure, .notConfigured)
        XCTAssertEqual(assist.summaryState(7)?.needsSetup, true)
        XCTAssertNil(toasts.current, "der Einrichtungs-Hinweis steht im Block, nicht im Toast")

        await core.setAIError(networkDown)
        await assist.summarize(8)
        XCTAssertEqual(assist.summaryState(8)?.failure, .message(Strings.errorText(networkDown)))
        XCTAssertNotNil(toasts.current, "ein echter Fehler erscheint zusätzlich als Toast")
    }

    func testSummaryShowsPendingAndDismiss() async {
        await core.setAIDelay(.milliseconds(120))
        let assist = makeAssist()
        let task = Task { await assist.summarize(9) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(assist.summaryState(9)?.pending, true)
        await task.value
        XCTAssertEqual(assist.summaryState(9)?.pending, false)
        assist.dismissSummary(9)
        XCTAssertNil(assist.summaryState(9))
    }

    // MARK: - Ask (requirement 3)

    func testAskSuccessWithCitations() async {
        let assist = makeAssist()
        await assist.ask("Wann war der Termin?", accountId: 3)
        XCTAssertEqual(assist.askStatus, .done)
        XCTAssertEqual(assist.askAnswer, "Am 3. März.")
        XCTAssertEqual(assist.askCitations.count, 1)
        XCTAssertEqual(assist.askCitations.first?.threadId, 7)
        let request = await core.aiAskRequest
        XCTAssertEqual(request?.question, "Wann war der Termin?")
        XCTAssertEqual(request?.accountId, 3)
        XCTAssertFalse(request?.requestId.isEmpty ?? true, "requestId ist gesetzt")
    }

    func testAskFailureAndReset() async {
        await core.setAIError(notConfigured)
        let assist = makeAssist()
        await assist.ask("Frage")
        XCTAssertEqual(assist.askStatus, .error)
        XCTAssertEqual(assist.askFailure, .notConfigured)
        XCTAssertTrue(assist.askAnswer.isEmpty)
        assist.resetAsk()
        XCTAssertEqual(assist.askStatus, .idle)
        XCTAssertNil(assist.askFailure)
    }

    // MARK: - Palette in plain language (requirement 4)

    func testPaletteCommandReturnsTheIntent() async {
        await core.setAIIntent(AIIntent(kind: "compose", to: ["ana@example.test"], subject: "Hi", body: "Text"))
        let assist = makeAssist()
        let intent = await assist.runCommand("schreib ana eine mail")
        XCTAssertEqual(intent?.kind, "compose")
        XCTAssertEqual(intent?.to, ["ana@example.test"])
        let calls = await core.aiCalls
        XCTAssertEqual(calls, ["ai_command"])
    }

    func testPaletteCommandFailureIsAToast() async {
        await core.setAIError(networkDown)
        let assist = makeAssist()
        let intent = await assist.runCommand("mach was")
        XCTAssertNil(intent)
        XCTAssertEqual(toasts.current?.isError, true)
    }

    // MARK: - Search filter (requirement 5)

    func testSearchFilterQuery() async {
        await core.setAIFilter(.query("from:ana has:attachment"))
        let assist = makeAssist()
        let filter = await assist.searchFilter("Mails von Ana mit Anhang")
        XCTAssertEqual(filter, .query("from:ana has:attachment"))
        let history = await core.aiSearchHistory
        XCTAssertEqual(history.first?.isEmpty, true)
    }

    func testSearchFilterAskCarriesTheHistory() async {
        await core.setAIFilter(.ask(AIFilterQuestion(question: "Von wem?", options: [
            AIFilterOption(label: "Ana", value: "from:ana@example.test")
        ])))
        let assist = makeAssist()
        let first = await assist.searchFilter("Mails mit Anhang")
        guard case .ask(let question)? = first else { return XCTFail("erwartet: Rückfrage") }
        XCTAssertEqual(question.options.first?.value, "from:ana@example.test")
        _ = await assist.searchFilter("Mails mit Anhang",
                                      history: [AIFilterTurn(question: "Von wem?", answer: "Ana")])
        let history = await core.aiSearchHistory
        XCTAssertEqual(history.last?.first?.answer, "Ana")
    }

    func testSearchFilterFailure() async {
        await core.setAIError(networkDown)
        let assist = makeAssist()
        let filter = await assist.searchFilter("x")
        XCTAssertNil(filter)
        XCTAssertEqual(toasts.current?.isError, true)
    }

    // MARK: - Rule planner and signature (requirement 7)

    func testPlanAutomation() async {
        let assist = makeAssist()
        let plan = await assist.planAutomation("Rechnungen nach Wichtig")
        XCTAssertEqual(plan?.supported, true)
        XCTAssertEqual(plan?.instruction, "Ist es eine offene Rechnung?")
        let calls = await core.aiCalls
        XCTAssertEqual(calls, ["ai_plan_automation"])
    }

    func testPlanAutomationFailure() async {
        await core.setAIError(notConfigured)
        let assist = makeAssist()
        let plan = await assist.planAutomation("x")
        XCTAssertNil(plan)
        XCTAssertNotNil(toasts.current)
    }

    func testSignatureSuggestion() async {
        await core.setAISignatureValue("Viele Grüße\nChristian")
        let assist = makeAssist()
        let text = await assist.signature(name: "Christian", email: "christian@sandbox.invalid")
        XCTAssertEqual(text, "Viele Grüße\nChristian")
    }

    func testSignatureFailure() async {
        await core.setAIError(networkDown)
        let assist = makeAssist()
        let text = await assist.signature(name: "C", email: "c@d.de")
        XCTAssertNil(text)
    }

    // MARK: - Composer (requirement 2)

    func testDraftReplacesBodyAndUndoRestoresIt() async {
        let draft = makeDraft()
        let ok = await draft.aiDraft(instruction: "Kurz zusagen")
        XCTAssertTrue(ok)
        XCTAssertEqual(draft.body, "Guten Tag, ich sage zu.")
        XCTAssertTrue(draft.canUndoAIChange)

        let request = await core.aiDraftRequest
        XCTAssertEqual(request?.threadId, 7)
        XCTAssertEqual(request?.instruction, "Kurz zusagen")
        XCTAssertEqual(request?.currentDraft, "Alter Text", "der vorhandene Text geht als currentDraft mit")

        XCTAssertTrue(draft.undoAIChange())
        XCTAssertEqual(draft.body, "Alter Text")
        XCTAssertFalse(draft.canUndoAIChange)
    }

    func testDraftFailureKeepsTheText() async {
        await core.setAIError(notConfigured)
        let draft = makeDraft()
        let ok = await draft.aiDraft(instruction: "Etwas")
        XCTAssertFalse(ok)
        XCTAssertEqual(draft.body, "Alter Text")
        XCTAssertFalse(draft.canUndoAIChange)
        XCTAssertEqual(draft.aiFailure, .notConfigured)
    }

    func testEmptyAnswerIsAFailure() async {
        await core.setAIDraftValue("   ")
        let draft = makeDraft()
        let ok = await draft.aiDraft(instruction: "Etwas")
        XCTAssertFalse(ok)
        XCTAssertEqual(draft.body, "Alter Text")
    }

    func testProofreadOffersAcceptAndUndo() async {
        await core.setProofreadValue("Alter Text.")
        let draft = makeDraft()
        let offered = await draft.aiProofread()
        XCTAssertTrue(offered)
        XCTAssertEqual(draft.proofreadSuggestion, "Alter Text.")
        XCTAssertEqual(draft.body, "Alter Text", "nichts wird ohne Zustimmung geändert")

        draft.acceptProofread()
        XCTAssertEqual(draft.body, "Alter Text.")
        XCTAssertNil(draft.proofreadSuggestion)
        XCTAssertTrue(draft.undoAIChange())
        XCTAssertEqual(draft.body, "Alter Text")
    }

    func testProofreadCleanTextSaysSo() async {
        await core.setProofreadValue("Alter Text")
        let draft = makeDraft()
        let offered = await draft.aiProofread()
        XCTAssertFalse(offered)
        XCTAssertNil(draft.proofreadSuggestion)
        XCTAssertEqual(toasts.current?.text, Strings.aiProofreadClean)
    }

    func testProofreadFailure() async {
        await core.setAIError(networkDown)
        let draft = makeDraft()
        let offered = await draft.aiProofread()
        XCTAssertFalse(offered)
        XCTAssertEqual(draft.aiFailure, .message(Strings.errorText(networkDown)))
    }

    func testQuickRepliesFillTheBody() async {
        await core.setQuickReplies(["Mache ich."])
        let draft = makeDraft()
        await draft.loadQuickReplies()
        XCTAssertEqual(draft.quickReplies, ["Mache ich."])
        draft.useQuickReply("Mache ich.")
        XCTAssertEqual(draft.body, "Mache ich.")
        XCTAssertTrue(draft.canUndoAIChange, "auch eine Schnellantwort ist rückgängig zu machen")
        XCTAssertTrue(draft.quickReplies.isEmpty)
    }

    func testQuickRepliesStayEmptyOnFailure() async {
        await core.setAIError(networkDown)
        let draft = makeDraft()
        await draft.loadQuickReplies()
        XCTAssertTrue(draft.quickReplies.isEmpty, "ohne Antwort zeigt der Entwurf keine Chips")
        XCTAssertNil(toasts.current, "ein fehlender Vorschlag ist kein Fehler")
    }

    func testDraftActionsComeFromTheCore() async {
        await core.setDraftActions([.createEvent(AICalendarSuggestion(title: "Termin", start: "2026-11-24T14:00:00+01:00"))])
        let draft = makeDraft()
        await draft.aiDraft(instruction: "Termin zusagen")
        XCTAssertEqual(draft.draftActions.count, 1)
        XCTAssertEqual(draft.draftActions.first?.suggestion.title, "Termin")
        draft.removeDraftAction(draft.draftActions[0])
        XCTAssertTrue(draft.draftActions.isEmpty)
    }

    // MARK: - Decoding the core's DTOs

    func testSummaryDecodesWithoutOptionalFields() throws {
        let json = #"{"keyPoints":["a"]}"#
        let summary = try JSONDecoder().decode(AIThreadSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.keyPoints, ["a"])
        XCTAssertTrue(summary.timeline.isEmpty)
        XCTAssertNil(summary.nextAction)
        XCTAssertNil(summary.proposedReply)
        XCTAssertNil(summary.calendarSuggestion)
    }

    func testSummaryWithSuggestionAndDates() throws {
        let json = #"""
        {"timeline":[{"actor":"Ana","event":"fragt"}],"keyPoints":["x"],"nextAction":"antworten",
         "proposedReply":"gern","calendarSuggestion":{"title":"Termin","start":"2026-11-24T14:00:00+01:00",
         "end":"2026-11-24T14:30:00+01:00","allDay":false,"location":null,"description":null}}
        """#
        let summary = try JSONDecoder().decode(AIThreadSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.timeline.first?.actor, "Ana")
        XCTAssertEqual(summary.calendarSuggestion?.title, "Termin")
        XCTAssertNotNil(summary.suggestedStart)
        XCTAssertNotNil(summary.suggestedEnd)
    }

    func testSearchFilterDecodesBothShapes() throws {
        let query = try JSONDecoder().decode(AISearchFilter.self, from: Data(#"{"kind":"query","query":"from:a"}"#.utf8))
        XCTAssertEqual(query, .query("from:a"))
        let ask = try JSONDecoder().decode(
            AISearchFilter.self,
            from: Data(#"{"kind":"ask","question":"Von wem?","options":[{"label":"A","value":"from:a"}]}"#.utf8))
        guard case .ask(let question) = ask else { return XCTFail("erwartet: Rückfrage") }
        XCTAssertEqual(question.question, "Von wem?")
        XCTAssertEqual(question.options.first?.label, "A")
    }

    func testDraftActionIsInternallyTagged() throws {
        let json = #"{"kind":"create_event","title":"Termin","start":"2026-11-24T14:00:00+01:00","allDay":false}"#
        let action = try JSONDecoder().decode(AIDraftAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.suggestion.title, "Termin")
        XCTAssertEqual(action.suggestion.start, "2026-11-24T14:00:00+01:00")
    }

    func testIntentDecodesNullableFields() throws {
        let json = #"{"kind":"create_event","summary":"Treffen","startsAt":1000,"endsAt":2000,"allDay":null}"#
        let intent = try JSONDecoder().decode(AIIntent.self, from: Data(json.utf8))
        XCTAssertEqual(intent.kind, "create_event")
        XCTAssertEqual(intent.summary, "Treffen")
        XCTAssertEqual(intent.startsAt, 1000)
        XCTAssertNil(intent.allDay)
    }

    func testAutomationPlanDecodesWithDefaults() throws {
        let plan = try JSONDecoder().decode(AIAutomationPlan.self, from: Data(#"{"supported":false}"#.utf8))
        XCTAssertFalse(plan.supported)
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertTrue(plan.issues.isEmpty)
    }

    func testStatusDecodesWithoutDecisionFields() throws {
        let json = #"{"configured":true,"model":"m","baseUrl":"https://x","appleIntelligence":"available"}"#
        let status = try JSONDecoder().decode(AIStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.configured)
        XCTAssertFalse(status.decisionConfigured)
        XCTAssertEqual(status.decisionModel, "")
        XCTAssertFalse(status.usesAppleIntelligence)
        XCTAssertTrue(AIStatus.isAppleBaseURL("apple://intelligence"))
    }

    // MARK: - Date strings from the model

    func testDateParserHandlesTheShapesTheModelUses() {
        XCTAssertNotNil(AIDateParser.milliseconds("2026-11-24T14:00:00+01:00"))
        XCTAssertNotNil(AIDateParser.milliseconds("2026-11-24T14:00:00Z"))
        XCTAssertNotNil(AIDateParser.milliseconds("2026-11-24T14:00"))
        XCTAssertNotNil(AIDateParser.milliseconds("2026-11-24"))
        XCTAssertNotNil(AIDateParser.milliseconds("2026-11-24T14:00:00.123+01:00"))
        XCTAssertNil(AIDateParser.milliseconds(""))
        XCTAssertNil(AIDateParser.milliseconds("nächsten Dienstag"))
    }

    func testDateParserKeepsTheOffset() {
        let summer = AIDateParser.milliseconds("2026-07-01T12:00:00+02:00")
        let sameInstantInUTC = AIDateParser.milliseconds("2026-07-01T10:00:00Z")
        XCTAssertEqual(summer, sameInstantInUTC)
    }

    // MARK: - Links in an answer (W4 aus dem Audit M2)

    /// A model answer is mail content: a prompt injection can make it write
    /// `file:`, `smb:` or an app scheme. Only a web address may open.
    func testAnswerLinksOpenOnlyWebAddresses() {
        for allowed in ["https://example.test/a", "http://example.test", "HTTPS://example.test/x?y=1"] {
            XCTAssertTrue(SafeLink.isOpenable(allowed), "erlaubt: \(allowed)")
        }
        for refused in ["file:///etc/passwd", "smb://server/share", "javascript:alert(1)",
                        "data:text/html,x", "mailto:a@b.de", "x-app://open", "https://",
                        "tel:+49123", "ssh://host"] {
            XCTAssertFalse(SafeLink.isOpenable(refused), "abgelehnt: \(refused)")
        }
    }
}
