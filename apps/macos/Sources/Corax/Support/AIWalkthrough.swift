import Foundation
import CoraxKit

#if DEBUG || CORAX_TEST_HOOKS

/// Canned answers for the M2.3 walkthrough, so the success UI can be shown
/// without a key and without a network call. Hook builds only, and only active
/// with `CORAX_AI_FAKE=1`.
///
/// Every text carries the marker `M2.3-Fake`; `strings` on the release bundle
/// must not find it (the whole file is compiled out there).
struct FakeAIProvider: AICore {
    let configured: Bool
    /// M2.4: how long a call takes. With a delay the walkthrough can feed
    /// token events while the call is still running, which is the streaming
    /// case (in a real run the host streams those tokens).
    var delay: Duration = .zero
    /// A `requestId` filter the walkthrough sets, so the canned provider can
    /// say which id it used (the app learns it from the draft/store instead).
    private func waitForDelay() async {
        if delay > .zero { try? await Task.sleep(for: delay) }
    }

    func aiStatus() async throws -> AIStatus {
        AIStatus(configured: configured, model: "M2.3-Fake-Modell",
                 baseUrl: "https://fake.invalid/v1", decisionConfigured: false)
    }

    func aiListModels() async throws -> [String] { ["M2.3-Fake-Modell", "M2.3-Fake-Klein"] }

    func aiUsageStats() async throws -> AIUsageStats {
        var days: [AIUsageDay] = []
        for index in 0..<7 {
            days.append(AIUsageDay(date: "2026-11-\(14 + index)",
                                   totalTokens: Int64(300 + index * 100),
                                   requests: Int64(index + 1)))
        }
        return AIUsageStats(totalTokens: 4200, totalRequests: 17, todayTokens: 900, yesterdayTokens: 700,
                            last7DaysTokens: 3100, last30DaysTokens: 4200, days: days)
    }

    func setAIKey(_ apiKey: String) async throws { /* canned: nothing is stored */ }
    func setDecisionKey(provider: String, apiKey: String) async throws { /* canned */ }
    func testDecisionProviders() async throws -> [DecisionTestResult] {
        [DecisionTestResult(provider: "openrouter", model: "M2.3-Fake-Entscheid", ok: true,
                            latencyMs: 120, probability: 0.91, error: ""),
         DecisionTestResult(provider: "openai", model: "M2.3-Fake-Entscheid", ok: false,
                            latencyMs: 0, probability: 0, error: "M2.3-Fake-Fehler")]
    }
    func learnVoice() async throws -> String { "M2.3-Fake-Stil: kurz, freundlich, du." }
    func embeddingStatus() async throws -> EmbeddingStatus {
        EmbeddingStatus(enabled: true, model: "M2.3-Fake-Embedding", total: 208, embedded: 200, pending: 8, ready: true)
    }
    func semanticReindex() async throws -> Int64 { 208 }

    func summarizeThread(_ threadId: Int64) async throws -> AIThreadSummary {
        await waitForDelay()
        return AIThreadSummary(
            timeline: [AITimelineEntry(actor: "Ana", event: "schickt die Rechnung (M2.3-Fake)"),
                       AITimelineEntry(actor: "Du", event: "sagst die Prüfung zu (M2.3-Fake)")],
            keyPoints: ["M2.3-Fake: Rechnung 2026-11 liegt bei", "M2.3-Fake: Zahlung bis Freitag"],
            nextAction: "M2.3-Fake: Betrag prüfen und überweisen",
            proposedReply: "M2.3-Fake: Danke, ich prüfe die Rechnung bis Freitag.")
    }

    func quickReplies(_ threadId: Int64) async throws -> [String] {
        ["M2.3-Fake: Mache ich.", "M2.3-Fake: Danke für die Info."]
    }

    func aiDraft(threadId: Int64?, replyToMessageId: Int64?, instruction: String, currentDraft: String?,
                 senderName: String?, voice: Bool?, hasSignature: Bool?, requestId: String?) async throws -> String {
        await waitForDelay()
        return "M2.3-Fake: Guten Tag, vielen Dank. Zur Anweisung „\(instruction)“ sage ich zu."
    }

    func aiDraftActions(threadId: Int64?, draft: String) async throws -> [AIDraftAction] {
        [.createEvent(AICalendarSuggestion(title: "M2.3-Fake: Termin aus dem Entwurf",
                                           start: "2026-11-24T14:00:00+01:00",
                                           end: "2026-11-24T14:30:00+01:00",
                                           allDay: false, location: nil, description: nil))]
    }

    func proofread(_ body: String) async throws -> String {
        "M2.3-Fake: Guten Tag, vielen Dank. Ich sage zu."
    }

    func aiSignature(name: String, email: String) async throws -> String {
        "M2.3-Fake:\nViele Grüße\n\(name)"
    }

    func aiCommand(_ query: String) async throws -> AIIntent {
        AIIntent(kind: "search", query: "M2.3-Fake: \(query)")
    }

    func aiSearchFilter(request: String, history: [AIFilterTurn]) async throws -> AISearchFilter {
        if history.isEmpty {
            return .ask(AIFilterQuestion(question: "M2.3-Fake: Von wem?",
                                         options: [AIFilterOption(label: "M2.3-Fake: Ana", value: "from:ana@example.test"),
                                                   AIFilterOption(label: "M2.3-Fake: Alle", value: "from:any")]))
        }
        return .query("from:ana@example.test")
    }

    func aiPlanAutomation(_ prompt: String) async throws -> AIAutomationPlan {
        AIAutomationPlan(supported: true, name: "M2.3-Fake-Regel",
                         instruction: "M2.3-Fake: Ist das eine offene Rechnung?",
                         actions: [], summary: "M2.3-Fake: Leitet Rechnungen weiter.", issues: [])
    }

    func aiAsk(question: String, requestId: String, accountId: Int64?) async throws -> AskResult {
        await waitForDelay()
        return AskResult(answer: "M2.3-Fake: Der Termin war am 3. März.",
                  citations: [AskCitation(messageId: 1, threadId: 1, subject: "M2.3-Fake: Termin",
                                          from: "ana@example.test", date: 1_700_000_000_000,
                                          snippet: "M2.3-Fake: am 3. März")])
    }
}

/// M2.3 walkthrough helpers. Hook builds only (`CORAX_TEST_HOOKS=1`), sandbox
/// only: the real instance refuses every step.
@MainActor
enum AIWalkthrough {
    static var installed = false

    /// Installs the canned provider when the run asked for it. Without it the
    /// core is used, which — with `COMAIL_CREDENTIALS_INSECURE_FILE` — reports
    /// "not configured" without touching the keychain.
    static func install() {
        guard Instance.isSandbox else { log("install refused=not_sandbox"); return }
        guard ProcessInfo.processInfo.environment["CORAX_AI_FAKE"] == "1" else {
            log("install fake=0 (core answers ai_status)")
            return
        }
        let provider = FakeAIProvider(configured: true)
        let model = AppModel.shared
        model.aiClientOverride = provider
        model.ai.client = provider
        model.assistant.client = provider
        installed = true
        log("install fake=1")
    }

    /// `ai status` — reads `ai_status` through the store and logs the result.
    static func status() async {
        await AppModel.shared.ai.refreshStatus()
        let status = AppModel.shared.ai.status
        log("status configured=\(status?.configured == true ? 1 : 0) model=\(status?.model ?? "-")")
    }

    /// `ai summary` — opens a thread and summarizes it.
    static func summarize() async {
        ensureOpenThread()
        guard let id = AppModel.shared.mailbox.expandedId else { log("summary no_thread"); return }
        await AppModel.shared.assistant.summarize(id)
        let state = AppModel.shared.assistant.summaryState(id)
        log("summary thread=\(id) pending=\(state?.pending == true ? 1 : 0) "
            + "points=\(state?.summary?.keyPoints.count ?? 0) failure=\(state?.failure != nil ? 1 : 0)")
    }

    /// `ai ask <question>` — opens the Ask surface and asks.
    static func ask(_ question: String) async {
        AppModel.shared.askOpen = true
        await AppModel.shared.assistant.ask(question, accountId: AppModel.shared.mailbox.accountId)
        let assistant = AppModel.shared.assistant
        log("ask status=\(assistant.askStatus) answer=\(assistant.askAnswer.count) citations=\(assistant.askCitations.count)")
    }

    /// `ai draft <instruction>` — reply composer plus `ai_draft`.
    static func draft(_ instruction: String) async {
        ensureOpenThread()
        let model = AppModel.shared
        guard model.mailbox.expandedId != nil else { log("draft no_thread"); return }
        if model.mailbox.inlineCompose == nil { model.reply(.reply) }
        for _ in 0..<80 where model.mailbox.inlineCompose == nil { try? await Task.sleep(for: .milliseconds(25)) }
        guard let draft = model.mailbox.inlineCompose else { log("draft no_composer"); return }
        let ok = await draft.aiDraft(instruction: instruction)
        log("draft ok=\(ok ? 1 : 0) chars=\(draft.body.count) actions=\(draft.draftActions.count) undo=\(draft.canUndoAIChange ? 1 : 0)")
        await draft.loadQuickReplies()
        log("quickreplies count=\(draft.quickReplies.count)")
    }

    /// `ai draftwin <instruction>` — the same `ai_draft` in the compose window,
    /// which is small enough to screenshot without scrolling the thread.
    static func draftWindow(_ instruction: String) async {
        let model = AppModel.shared
        model.composeNew()
        for _ in 0..<80 where model.composeDrafts.isEmpty { try? await Task.sleep(for: .milliseconds(25)) }
        guard let draft = model.composeDrafts.values.first else { log("draftwin no_draft"); return }
        let ok = await draft.aiDraft(instruction: instruction)
        log("draftwin ok=\(ok ? 1 : 0) chars=\(draft.body.count) undo=\(draft.canUndoAIChange ? 1 : 0)")
    }

    /// The draft the AI steps act on: the inline one, else the compose window's.
    private static func activeDraft() -> ComposeDraft? {
        let model = AppModel.shared
        return model.mailbox.inlineCompose ?? model.composeDrafts.values.first
    }

    /// `ai proofread` — proofread proposal on the open draft.
    static func proofread() async {
        for _ in 0..<80 where activeDraft() == nil { try? await Task.sleep(for: .milliseconds(25)) }
        guard let draft = activeDraft() else { log("proofread no_composer"); return }
        let offered = await draft.aiProofread()
        log("proofread offered=\(offered ? 1 : 0) suggestion=\(draft.proofreadSuggestion?.count ?? 0)")
    }

    /// `ai accept` — takes the proofread text over.
    static func acceptProofread() async {
        guard let draft = activeDraft() else { log("accept no_composer"); return }
        draft.acceptProofread()
        log("accept chars=\(draft.body.count) undo=\(draft.canUndoAIChange ? 1 : 0)")
    }

    /// `ai undo` — takes the last AI change back (`⌘Z` path).
    static func undo() async {
        guard let draft = activeDraft() else { log("undo no_composer"); return }
        let ok = draft.undoAIChange()
        log("undo ok=\(ok ? 1 : 0) chars=\(draft.body.count)")
    }

    /// `ai filter <text>` — `ai_search_filter` on the search field's text.
    static func filter(_ text: String) async {
        let model = AppModel.shared
        guard let filter = await model.assistant.searchFilter(text) else { log("filter error=1"); return }
        switch filter {
        case .query(let query):
            model.aiFilterQuestion = nil
            model.mailbox.searchText = query
            model.mailbox.runSearch()
            log("filter kind=query text=\(query)")
        case .ask(let question):
            model.aiFilterQuestion = question
            model.aiFilterRequest = text
            log("filter kind=ask options=\(question.options.count) question=\(question.question)")
        }
    }

    /// `ai palette <text>` — the free-text palette row, executed.
    static func palette(_ text: String) async {
        AppModel.shared.paletteOpen = true
        AppModel.shared.runAICommand(text)
        log("palette started query=\(text.count) chars")
    }

    /// `ai settings` — Settings → Intelligenz.
    static func settingsPage() {
        SettingsNavigation.request(.intelligence)
        log("settings open=intelligence")
    }

    static func state() {
        let model = AppModel.shared
        let assistant = model.assistant
        let threadId = model.mailbox.expandedId
        let summary = threadId.flatMap { assistant.summaryState($0) }
        let draft = model.mailbox.inlineCompose
        log("state fake=\(installed ? 1 : 0) askOpen=\(model.askOpen ? 1 : 0) ask=\(assistant.askStatus) "
            + "aiConfigured=\(model.ai.isConfigured ? 1 : 0) "
            + "summary=\(summary != nil ? 1 : 0) summaryPending=\(summary?.pending == true ? 1 : 0) "
            + "filter=\(model.aiFilterQuestion != nil ? 1 : 0) "
            + "compose=\(draft != nil ? 1 : 0) undoAI=\(draft?.canUndoAIChange == true ? 1 : 0) "
            + "proofread=\(draft?.proofreadSuggestion != nil ? 1 : 0) "
            + "quickReplies=\(draft?.quickReplies.count ?? 0) toast=\(model.toasts.current?.text ?? "-")")
    }

    // MARK: M2.4 — Streaming, mailto, Avatare, Fensterleben, Erinnerung

    /// `ai:stream:<summary|draft|ask>`: a slow fake provider plus the token
    /// events the host would send. Proves that the text grows while the call
    /// runs and that the final answer replaces it.
    static func stream(_ kind: String) {
        let model = AppModel.shared
        let provider = FakeAIProvider(configured: true, delay: .milliseconds(1_400))
        switch kind {
        case "summary":
            ensureOpenThread()
            guard let id = model.mailbox.expandedId else { log("stream no_thread"); return }
            // Start from an empty card, so the screenshot shows the stream, not
            // the answer of a previous run.
            model.assistant.dismissSummary(id)
            model.assistant.client = provider
            Task {
                let call = Task { await model.assistant.summarize(id) }
                for (index, chunk) in summaryChunks.enumerated() {
                    try? await Task.sleep(for: .milliseconds(120))
                    model.debugReceive(tokenEvent("ai:summary:token", ["threadId": id, "delta": chunk]))
                    let partial = model.assistant.summaryState(id)?.partial
                    log("stream summary chunk=\(index + 1) chars=\(model.assistant.summaryState(id)?.streamedCharacters ?? 0) "
                        + "points=\(partial?.keyPoints.count ?? 0) timeline=\(partial?.timeline.count ?? 0)")
                }
                await call.value
                let state = model.assistant.summaryState(id)
                log("stream summary done pending=\(state?.pending == true ? 1 : 0) points=\(state?.summary?.keyPoints.count ?? 0)")
            }
        case "draft":
            // The draft takes its AI client from the app model when it is built,
            // so the slow provider has to be in place before the composer opens.
            model.mailbox.inlineCompose = nil
            model.aiClientOverride = provider
            let known = Set(model.composeDrafts.keys)
            model.composeNew()
            guard let draft = model.composeDrafts.first(where: { !known.contains($0.key) })?.value else {
                log("stream no_composer")
                return
            }
            Task {
                let call = Task { await draft.aiDraft(instruction: "Bitte kurz zusagen") }
                try? await Task.sleep(for: .milliseconds(60))
                let id = draft.aiRequestId ?? "-"
                for (index, chunk) in draftChunks.enumerated() {
                    try? await Task.sleep(for: .milliseconds(120))
                    model.debugReceive(tokenEvent("ai:draft:token", ["requestId": id, "delta": chunk]))
                    log("stream draft chunk=\(index + 1) chars=\(draft.body.count) streaming=\(draft.aiStreaming ? 1 : 0)")

                }
                let ok = await call.value
                log("stream draft done ok=\(ok ? 1 : 0) chars=\(draft.body.count) undo=\(draft.canUndoAIChange ? 1 : 0)")
            }
        case "ask":
            model.askOpen = true
            Task {
                let call = Task { await model.assistant.ask("Wann war der Termin mit dem Steuerberater?") }
                try? await Task.sleep(for: .milliseconds(60))
                let id = model.assistant.askRequestId ?? "-"
                for (index, chunk) in askChunks.enumerated() {
                    try? await Task.sleep(for: .milliseconds(120))
                    model.debugReceive(tokenEvent("ai:ask:token", ["requestId": id, "delta": chunk]))
                    log("stream ask chunk=\(index + 1) chars=\(model.assistant.askAnswer.count) status=\(model.assistant.askStatus)")
                }
                await call.value
                log("stream ask done status=\(model.assistant.askStatus) chars=\(model.assistant.askAnswer.count)")
            }
        default:
            log("stream unknown=\(kind)")
        }
    }

    /// The draft the streaming steps write into: the inline one, else a fresh
    /// compose window.
    private static func activeOrNewDraft() -> ComposeDraft? {
        let model = AppModel.shared
        if let inline = model.mailbox.inlineCompose { return inline }
        if let existing = model.composeDrafts.values.first { return existing }
        model.composeNew()
        for _ in 0..<80 where model.composeDrafts.isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return model.composeDrafts.values.first
    }

    private static var summaryChunks: [String] {
        ["{\"timeline\":[{\"actor\":\"Ana\",\"event\":\"schickt die Rechnung (M2.4-Fake)\"},",
         "{\"actor\":\"Du\",\"event\":\"sagst die Prüfung zu (M2.4-Fake)\"}],",
         "\"keyPoints\":[\"M2.4-Fake: Rechnung 2026-11 liegt bei\",",
         "\"M2.4-Fake: Zahlung bis Freitag\"],",
         "\"nextAction\":\"M2.4-Fake: Betrag prüfen und überweisen\"}"]
    }

    private static var draftChunks: [String] {
        ["M2.4-Fake: Guten Tag, ", "vielen Dank für die ", "Rechnung. ", "Ich prüfe sie bis Freitag."]
    }

    private static var askChunks: [String] {
        ["M2.4-Fake: Der Termin ", "mit dem Steuerberater ", "war am 3. März um 14:30."]
    }

    private static func tokenEvent(_ name: String, _ payload: [String: Any]) -> String {
        let object: [String: Any] = ["name": name, "payload": payload]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `mailto:<url>`: the same parser and the same composer as `onOpenURL`,
    /// without asking LaunchServices which app owns the scheme.
    static func mailto(_ text: String) {
        guard let url = URL(string: text) else { log("mailto bad_url"); return }
        AppModel.shared.composeMailto(url)
        log("mailto opened url=\(url.absoluteString)")
    }

    /// `avatars:state` / `avatars:request:<email>`.
    static func avatars(_ argument: String) {
        let model = AppModel.shared
        switch argument {
        case "state":
            log("avatars \(model.debugAvatarState()) lookups=\(model.mailbox.threads.prefix(3).count)")
        case "off":
            model.settings.set("showSenderPhotos", false)
            log("avatars setting=0 enabled=\(model.avatars.enabled ? 1 : 0)")
        case "on":
            model.settings.set("showSenderPhotos", true)
            log("avatars setting=1 enabled=\(model.avatars.enabled ? 1 : 0)")
        default:
            log("avatars unknown=\(argument)")
        }
    }

    /// `window:close` / `window:show`: closing the main window must not end the
    /// process (Tauri's tray behaviour).
    static func window(_ argument: String) {
        let model = AppModel.shared
        switch argument {
        case "close":
            let closed = model.debugCloseMainWindow()
            log("window close ok=\(closed ? 1 : 0)")
        case "show":
            model.debugShowMainWindow()
            log("window show requested")
        default:
            log("window unknown=\(argument)")
        }
    }

    /// `reminder:fake`: a `calendar:reminder` through the normal routing, so the
    /// notification path (permission check, body, click target) is exercised
    /// without waiting for the core's scheduler.
    ///
    /// Note: the core's scheduler is the real source of that event (it honours
    /// `meetingNotifyLeadMinutes`); this hook only replaces the timing.
    static func reminder() {
        let start = Int64(Date().timeIntervalSince1970 * 1000) + 5 * 60_000
        let event: [String: Any] = [
            "id": 9_001, "accountId": 1, "messageId": NSNull(), "summary": "M2.4-Fake: Standup",
            "location": "Raum 2", "organizer": NSNull(), "description": NSNull(), "attendees": [],
            "joinUrl": NSNull(), "rsvpStatus": NSNull(), "isLocal": true, "calendarId": NSNull(),
            "rrule": NSNull(), "startsAt": start, "endsAt": start + 900_000, "allDay": false,
            "status": NSNull(), "method": NSNull(),
        ]
        let json = tokenEvent("calendar:reminder", ["event": event, "occurrenceStart": start])
        AppModel.shared.debugReceive(json)
        log("reminder fed start=\(start)")
    }

    /// The first row, expanded, when nothing is open yet.
    private static func ensureOpenThread() {
        let box = AppModel.shared.mailbox
        if box.expandedId == nil {
            if box.selectedId == nil, let first = box.threads.first { box.select(first.id) }
            if let id = box.selectedId { box.expand(id) }
        }
    }

    private static func log(_ text: String) {
        PerfLog.shared.write("ai_walk \(text)")
    }
}

#endif
