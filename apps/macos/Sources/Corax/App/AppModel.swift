import AppKit
import Foundation
import Observation
import CoraxKit
import UserNotifications

/// Root of the app state. Created once, as early as possible: `init` starts the
/// host before any UI is built (the host sets environment variables while it
/// starts, which must happen before other threads exist).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let identifier: String?
    /// P2g: the one write gate, shared by menu, status line, client and stores.
    let writeAccess: WriteAccess
    private(set) var client: CoraxClient?
    let bridge: DelegateBridge
    private(set) var startError: String?
    /// M3.1: Ergebnis der Datenübernahme in diesem Start (für Dialog und Log).
    private(set) var migrationOutcome: LegacyMigration.Outcome = .notNeeded
    /// M3.1: wie viele Schlüsselbund-Einträge übernommen wurden.
    private(set) var credentialsAdopted = 0
    private(set) var coreReady = false

    /// The Mac side of `PlatformServices` (M2.0): created here and handed to
    /// the bridge and the store, so `CoraxKit` needs no AppKit and no globals.
    let platform = MacPlatformServices()

    let toasts = ToastCenter()
    let settings = SettingsStore()
    let sync = SyncStore()
    let mailbox: MailboxStore
    // M2.1 settings editors
    let snippets: SnippetsStore
    let labels: LabelsStore
    let splits: SplitsStore
    let mcp: McpStore
    // M2.2 calendar
    let calendar: CalendarStore
    // M2.3 AI
    let ai: AIStore
    let assistant: AIAssistStore
    // M2.4 sender pictures. The resolver reads the client lazily: the store is
    // created with the app model, the client a few lines later.
    let avatars = AvatarPhotos(resolve: { email in
        await AppModel.avatar(for: email)
    })
    /// M2.4: copy a one-time code, unsubscribe from a newsletter.
    let aux = AuxActionsStore()

    // UI state shared by window, menus and the palette
    var systemDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    var paletteOpen = false
    /// M2.18m: „Gehe zu Ordner/Label …“ (`G` `O`).
    var goToOpen = false
    /// M2.18n: die `G`-Folge wartet auf ihre zweite Taste — die Statuszeile
    /// zeigt so lange, was zur Wahl steht.
    private(set) var goSequenceActive = false
    /// Zählt die Folgen; eine ältere Frist darf keine neuere beenden.
    @ObservationIgnored private var goSequenceGeneration = 0
    /// The calendar screen replaces the mail list while it is open (M2.2).
    var calendarOpen = false
    /// The "Fragen an das Postfach" surface (`ai_ask`).
    var askOpen = false
    /// Hook runs only (`AIWalkthrough`): a canned AI provider that replaces the
    /// core for AI commands, so the success UI can be shown without a key and
    /// without network. Nil in every normal run.
    var aiClientOverride: (any AICore)?
    /// Bumped by ⌘O / the search sparkle: the toolbar runs `ai_search_filter`
    /// on the text in the search field.
    var searchAIRequest = 0
    /// The clarifying question the AI filter came back with, if any.
    var aiFilterQuestion: AIFilterQuestion?
    /// The request that question belongs to (for the history round).
    var aiFilterRequest = ""
    var shortcutsOpen = false
    var accountSheetOpen = false
    var perfOverlay = false
    var searchFocusRequest = 0
    // M2.5: the four pickers and the confirmation dialog of the list.
    var moveOpen = false
    var labelOpen = false
    var permanentDeleteOpen = false
    /// The threads the delete dialog was opened on (W3): the dialog and its
    /// confirmation act on this list, not on whatever is selected later.
    var permanentDeleteIds: [Int64] = []
    var splitOpen = false
    /// The sender-domain suggestion of "Split nach Absender" (`nil` = nothing to
    /// split by, the popover then explains why).
    var splitSuggestion: (name: String, domain: String, sender: String)?
    var composeDrafts: [UUID: ComposeDraft] = [:]
    var openComposeWindow: ((UUID) -> Void)?
    /// M2.9 Stufe B: Reihenfolge, Zustand und Fokus der Entwürfe im Panel.
    let compose = ComposeDock()
    /// M2.9: die Seitenleiste des Hauptfensters (Breitenregel, Nutzerwahl).
    let sidebar = SidebarState(defaults: .standard,
                               key: Instance.isSandbox ? "sidebarVisible.sandbox" : "sidebarVisible")

    var theme: Theme { Theme.resolve(settings.themeID, systemDark: systemDark, accentKey: settings.accentKey) }

    /// R6: the list gets the keyboard once per launch; the search field only via
    /// `/` or a click.
    private var focusDone = false
    private var focusRetryScheduled = false

    private init() {
        // M3.1: erst die Datenübernahme, dann alles andere. Der neue Ordner
        // darf noch nicht existieren, sonst hielte die App eine leere Datenbank
        // für ihren Stand. `configureDefault` setzt nur den Logpfad.
        let selection = try? Instance.selected()
        let sandbox = selection == Instance.sandbox
        let identity = selection ?? AppIdentity.bundleID
        PerfLog.shared.configureDefault(identifier: identity)
        PerfLog.shared.markStartNow()
        if selection != nil {
            let taken = Self.takeOverLegacyData(sandbox: sandbox, identity: identity)
            migrationOutcome = taken.outcome
            credentialsAdopted = taken.credentials
            if case .migrated = taken.outcome {
                // `sidebar` entsteht als Eigenschaft, also vor dieser Zeile und
                // damit vor den übernommenen Defaults; ohne das Neuladen zeigte
                // der erste Start die Standardwahl.
                sidebar.reloadFromDefaults()
            }
        }
        PerfLog.shared.write("phase model_init ms=\(PerfLog.shared.elapsedMilliseconds)")

        // The gate first: `shared` is built lazily here, so its initial state
        // lands in the log file `PerfLog` just configured.
        writeAccess = .shared
        mailbox = MailboxStore(toasts: toasts, settings: settings, writeAccess: writeAccess, platform: platform)
        snippets = SnippetsStore(toasts: toasts)
        labels = LabelsStore(toasts: toasts)
        splits = SplitsStore(toasts: toasts)
        mcp = McpStore(toasts: toasts, platform: platform)
        calendar = CalendarStore(toasts: toasts)
        calendar.shell = sidebar
        ai = AIStore(toasts: toasts)
        assistant = AIAssistStore(toasts: toasts)
        settings.toasts = toasts
        // M2.4: "Absenderfotos" follows the switch without polling the object.
        settings.onLocalChange = { key in
            guard key == "showSenderPhotos" else { return }
            AppModel.shared.avatars.enabled = AppModel.shared.settings.showSenderPhotos
        }
        mailbox.onUnreadCounts = { counts in
            AppModel.shared.updateBadge(counts)
        }
        // M2.8b: picking a mailbox, account, tab or search leaves the calendar
        // (Tauri's `setView`/`selectFolder` do the same), so the choice shows.
        mailbox.onUserNavigation = { AppModel.shared.leaveCalendarForMail() }
        aux.use(toasts)
        aux.copyToClipboard = { text in AppModel.shared.platform.copyToClipboard(text) }
        aux.openURL = { url in AppModel.shared.platform.open(url) }
        // A refused core command becomes a toast; installed once, before the
        // first command (P2f: the client layer refuses what is not on the list).
        CoraxClient.onRefused = { text in
            Task { @MainActor in AppModel.shared.toasts.show(text, isError: true) }
        }
        bridge = DelegateBridge(
            platform: platform,
            onEventJSON: { json in Task { @MainActor in AppModel.shared.receive(json) } },
            onRefused: { url in Task { @MainActor in AppModel.shared.toasts.show(Strings.errorText(.core(code: "url_refused", message: url)), isError: true) } },
            onComposeMailto: { url in Task { @MainActor in AppModel.shared.composeMailto(url) } }
        )

        do {
            identifier = try Instance.selected()
        } catch {
            identifier = nil
            startError = error.localizedDescription
            PerfLog.shared.write("identifier_refused \(error.localizedDescription)")
            return
        }
        // M3.1: ohne Übernahme kein Hoststart. Sonst legte der Host eine leere
        // Datenbank im neuen Ordner an, und der nächste Start hielte sie für
        // den übernommenen Stand.
        switch migrationOutcome {
        case .legacyRunning:
            startError = "Rabe Native läuft noch. Bitte beenden und \(AppIdentity.displayName) neu starten — dann werden die Daten übernommen."
            PerfLog.shared.write("migration_blocked reason=legacy_running")
            return
        case .failed(let reason):
            startError = "Die Datenübernahme aus Rabe Native ist fehlgeschlagen: \(reason) Es wurde nichts verändert."
            PerfLog.shared.write("migration_blocked reason=failed")
            return
        case .notNeeded, .migrated:
            break
        }
        do {
            let client = try CoraxClient.start(identifier: identifier!, delegate: bridge)
            self.client = client
            mailbox.client = client
            settings.client = client
            sync.client = client
            snippets.client = client
            labels.client = client
            splits.client = client
            mcp.client = client
            calendar.client = client
            calendar.settings = settings
            ai.client = client
            assistant.client = client
            aux.client = client
            PerfLog.shared.configure(dataDirectory: client.dataDirectory)
            PerfLog.shared.write("host_started ms=\(PerfLog.shared.elapsedMilliseconds) instance=\(identifier!)")
        } catch {
            startError = CoraxClientError.from(error).errorDescription
            PerfLog.shared.write("host_failed \(error.localizedDescription)")
        }
        // M2.9: das Panel öffnet Fenster-Entwürfe und bekommt Entwürfe, die der
        // Thread beim Verlassen abgibt, als Leiste (§3.7).
        compose.onOpenWindow = { id in AppModel.shared.openComposeWindow?(id) }
        mailbox.onInlineDraftAbandoned = { draft in AppModel.shared.dockAbandonedInlineDraft(draft) }
    }

    /// After the window is up: wait for the core, then load settings and list.
    func start() async {
        guard let client, !coreReady else { return }
        do {
            try await client.waitReady()
            coreReady = true
            PerfLog.shared.write("host_ready ms=\(PerfLog.shared.elapsedMilliseconds)")
            await settings.load()
            // M2.8b: a language that follows the OS is stored as a concrete
            // code for the core; re-resolve it so a changed macOS language
            // arrives on the next launch.
            settings.syncSystemLanguage()
            avatars.enabled = settings.showSenderPhotos
            await mailbox.bootstrap()
            sync.refreshSoon()
            if mailbox.accounts.isEmpty { accountSheetOpen = true }
            focusListAtLaunch(reason: "start")
        } catch {
            startError = CoraxClientError.from(error).errorDescription
        }
    }

    /// Leaves the calendar for the mail list. A no-op while the calendar is
    /// closed, so every navigation path can call it.
    func leaveCalendarForMail() {
        guard calendarOpen else { return }
        calendarOpen = false
        mailbox.focusList()
        PerfLog.shared.write("calendar_left reason=navigation")
    }

    /// Called by the settings window when it appears: the editors load their
    /// own lists once, after the core is ready.
    func loadSettingsEditors() async {
        guard coreReady else { return }
        if !labels.loaded { await labels.load() }
        if !splits.loaded { await splits.load() }
        if !snippets.loaded { await snippets.load() }
        await mcp.load()
    }

    /// One label or rule changed the shared tab list: both editors reload.
    func reloadOrganisation() async {
        await labels.load()
        await splits.load()
    }

    /// N2 aus dem Audit M2: before the process ends, send the `mark_read`s the
    /// label window still holds back. `applicationShouldTerminate` waits for
    /// this (at most 2 s), then lets the app quit.
    func prepareForTermination() async {
        await mailbox.flushBeforeTermination()
    }

    func shutdown() {
        client?.shutdown()
        PerfLog.shared.write("host_shutdown")
    }

    private func receive(_ json: String) {
        guard let event = EventRouter.parse(json) else { return }
        switch event {
        case .ready(let ms):
            PerfLog.shared.write("event host:ready coreStartMs=\(Int(ms))")
        case .failed(let code, let message):
            startError = Strings.errorText(.core(code: code, message: message))
        case .mailUpdated(let ids), .mailNew(_, let ids):
            mailbox.mailUpdated(ids)
        case .syncProgress:
            sync.refreshSoon()
        case .actionFailed(let actionId, let threadId, let kind, let reason, let error):
            actionFailed(actionId: actionId, threadId: threadId, kind: kind, reason: reason, error: error)
        case .networkState(let online):
            sync.setOnline(online)
        case .calendarUpdated:
            guard calendarOpen else { break }
            Task { await calendar.refresh() }
        case .calendarReminder(let reminder):
            showReminder(reminder)
        case .aiToken(let token):
            route(token)
        case .aiCitations(let requestId, let citations):
            assistant.receiveAskCitations(citations, requestId: requestId)
        case .aiAskReset(let requestId):
            assistant.receiveAskReset(requestId: requestId)
        case .aiAskDone(let requestId):
            assistant.receiveAskDone(requestId: requestId)
        case .other:
            break
        }
    }

    #if DEBUG || CORAX_TEST_HOOKS
    /// Hook path (M2.16): hand one host event line to the production parser,
    /// exactly as the host would deliver it.
    func receiveDebugEvent(_ json: String) { receive(json) }
    #endif

    /// M2.16: the core gave up on a move (the server no longer has the mail,
    /// or the deferral ran out). Say so — the row has just rolled back, and a
    /// silent jump into the old folder looks like a bug.
    private func actionFailed(actionId: Int64, threadId: Int64?, kind: String, reason: String, error: String) {
        PerfLog.shared.write("action_failed id=\(actionId) kind=\(kind) reason=\(reason) thread=\(threadId.map(String.init) ?? "-")")
        let what = Strings.moveFailure(kind: kind)
        toasts.show(reason == "source_missing" ? "\(what): \(Strings.moveSourceMissing)" : what, isError: true)
    }

    /// M2.4: streamed text goes to the composer whose call it belongs to, else
    /// to the summary/ask store.
    private func route(_ token: AIStreamToken) {
        guard token.kind == .draft else {
            assistant.receive(token)
            return
        }
        if let inline = mailbox.inlineCompose, inline.consumeDraftToken(token) { return }
        for draft in composeDrafts.values where draft.aiRequestId == token.requestId {
            draft.consumeDraftToken(token)
            return
        }
    }

    // MARK: Kalender-Erinnerung (M2.4)

    /// `calendar:reminder` from the core's scheduler, shown as a desktop
    /// notification like Tauri's `notifyMeetingReminder`. The core already
    /// honours the lead time (`meetingNotifyLeadMinutes`), so nothing is
    /// filtered here beyond the permission.
    private func showReminder(_ reminder: CalendarReminder) {
        guard bridge.notificationsAllowed() else {
            PerfLog.shared.write("reminder skipped reason=notifications_denied event=\(reminder.event.id)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = reminder.event.summary ?? "Termin"
        content.body = Self.reminderBody(reminder)
        content.sound = .default
        content.userInfo = ["calendarEventId": reminder.event.id, "occurrenceStart": reminder.occurrenceStart]
        let id = AppIdentity.bundleID + ".event.\(reminder.event.id).\(reminder.occurrenceStart)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                PerfLog.shared.write("reminder_failed event=\(reminder.event.id) \(error.localizedDescription)")
            } else {
                PerfLog.shared.write("reminder_shown event=\(reminder.event.id)")
            }
        }
    }

    /// "Um 14:30 · Raum 2" — the time is the occurrence, not the series start.
    private static func reminderBody(_ reminder: CalendarReminder) -> String {
        let start = Date(timeIntervalSince1970: Double(reminder.occurrenceStart) / 1000)
        let time = Format.messageTime(start)     // HH:mm in the user's locale
        var text = "Um \(time)"
        if let location = reminder.event.location, !location.isEmpty, !location.hasPrefix("http") {
            text += " · \(location)"
        }
        return text
    }

    /// `join-next-meeting` (M2.6): opens the join link of the next or running
    /// meeting. The range is Tauri's (one hour back, one day ahead); the link
    /// must be `http`/`https`, because it comes from somebody else's calendar.
    func joinNextMeeting() {
        guard let client = calendar.client else { return }
        let now = Date()
        let range = MeetingLink.range(now: now)
        Task {
            do {
                let rows = try await client.listEvents(startMs: range.start, endMs: range.end)
                guard let next = MeetingLink.next(from: rows, now: now) else {
                    toasts.show("Kein Meeting zum Beitreten")
                    PerfLog.shared.write("join_meeting none")
                    return
                }
                guard let url = MeetingLink.url(next.joinUrl) else {
                    toasts.show("Meeting-Link ist keine Webadresse", isError: true)
                    PerfLog.shared.write("join_meeting refused event=\(next.id) scheme=other")
                    return
                }
                platform.open(url)
                PerfLog.shared.write("join_meeting event=\(next.id) scheme=\(url.scheme ?? "-")")
            } catch {
                toasts.error(error)
            }
        }
    }

    /// Clicking a reminder opens the calendar on that day with the event shown.
    func openEventFromNotification(eventId: Int64, occurrenceStart: Int64) {
        NSApp.activate()
        calendarOpen = true
        calendar.settings = settings
        calendar.go(to: occurrenceStart)
        Task {
            await calendar.loadCalendars()
            await calendar.refresh()
            PerfLog.shared.write("reminder_open event=\(eventId)")
        }
    }

    // MARK: Notifications

    /// R6: after `host:ready` and the first list the table takes the keyboard.
    /// SwiftUI puts the search field first responder while the window becomes
    /// key, so the request is repeated twice shortly after — only while the
    /// search field is still empty and no text field has the focus by a click.
    func focusListAtLaunch(reason: String) {
        guard !accountSheetOpen, !paletteOpen, mailbox.searchQuery == nil, mailbox.searchText.isEmpty else { return }
        focusDone = true
        mailbox.focusList()
        PerfLog.shared.write("focus_list reason=\(reason)")
        guard !focusRetryScheduled else { return }
        focusRetryScheduled = true
        for delay in [0.5, 1.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.mailbox.searchQuery == nil, self.mailbox.searchText.isEmpty,
                      let window = NSApp.keyWindow, window.title == Instance.title,
                      !(window.firstResponder is MailTableView) else { return }
                self.mailbox.focusList()
                PerfLog.shared.write("focus_list reason=retry")
            }
        }
    }

    /// N3: a permission revoked in System Settings is noticed on the next
    /// activation (the host would otherwise retry every 5 minutes).
    func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [bridge] settings in
            let allowed = settings.authorizationStatus != .denied
            bridge.setNotificationsAllowed(allowed)
            PerfLog.shared.write("notification_status status=\(settings.authorizationStatus.rawValue) allowed=\(allowed)")
        }
    }

    func didBecomeActive() {
        refreshNotificationPermission()
        guard !focusDone else { return }
        focusListAtLaunch(reason: "activate")
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [bridge] granted, _ in
            center.getNotificationSettings { settings in
                bridge.setNotificationsAllowed(settings.authorizationStatus != .denied)
                PerfLog.shared.write("notification_permission granted=\(granted) status=\(settings.authorizationStatus.rawValue)")
            }
        }
    }

    func openThreadFromNotification(_ threadId: Int64) {
        NSApp.activate()
        if mailbox.index(of: threadId) != nil {
            mailbox.select(threadId)
            mailbox.expand(threadId)
        } else {
            mailbox.setView(.inbox)
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                if mailbox.index(of: threadId) != nil { mailbox.select(threadId); mailbox.expand(threadId) }
            }
        }
    }

    // MARK: KI (M2.3)

    /// The open thread, if any (the summary and the quick replies need it).
    var openThreadId: Int64? { mailbox.expandedId }

    /// `ai_summarize` for the open thread; the summary shows above its messages.
    func summarizeOpenThread() {
        guard let id = mailbox.expandedId else { return }
        Task { await assistant.summarize(id) }
    }

    /// `ai_command`: a palette query in plain language. The actions match
    /// `src/lib/aiCommand.ts`; the palette closes first, so the result is visible.
    func runAICommand(_ query: String) {
        paletteOpen = false
        Task {
            guard let intent = await assistant.runCommand(query) else { return }
            switch intent.kind {
            case "create_event":
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let startsAt = intent.startsAt ?? now + 3_600_000
                let endsAt = intent.endsAt ?? startsAt + 3_600_000
                NotificationCenter.default.post(name: .coraxCalendarPrefill, object: nil, userInfo: [
                    "summary": intent.summary ?? query,
                    "location": intent.location ?? "",
                    "startsAt": startsAt,
                    "endsAt": endsAt,
                    "allDay": intent.allDay ?? false,
                ])
                calendarOpen = true
                Task {
                    calendar.settings = settings
                    await calendar.loadCalendars()
                    await calendar.refresh()
                }
            case "compose":
                composeNew(to: (intent.to ?? []).map { Address(name: nil, email: $0) },
                           subject: intent.subject ?? "", body: intent.body ?? "")
            case "search":
                mailbox.searchText = intent.query ?? query
                mailbox.runSearch()
                mailbox.focusList()
            case "go_to":
                if let raw = intent.view, let view = MailView(rawValue: raw) {
                    mailbox.setView(view)
                    mailbox.focusList()
                } else {
                    toasts.show("Nicht verstanden – bitte anders formulieren")
                }
            default:
                toasts.show("Nicht verstanden – bitte anders formulieren")
            }
        }
    }

    /// The summary's proposed reply goes into the inline composer of the open
    /// thread, so the user edits and sends it like their own text.
    func useAIProposedReply(_ text: String, threadId: Int64) {
        if mailbox.selectedId != threadId { mailbox.select(threadId) }
        if mailbox.expandedId != threadId { mailbox.expand(threadId) }
        reply(.reply)
        Task {
            for _ in 0..<40 where mailbox.inlineCompose == nil { try? await Task.sleep(for: .milliseconds(25)) }
            mailbox.inlineCompose?.body = text
        }
    }

    /// Opens the event editor with the summary's suggested event (the user
    /// still confirms; nothing is written from here).
    func createEventFromSuggestion(_ suggestion: AICalendarSuggestion) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let startsAt = AIDateParser.milliseconds(suggestion.start) ?? now + 3_600_000
        let endsAt = suggestion.end.flatMap(AIDateParser.milliseconds) ?? startsAt + 3_600_000
        NotificationCenter.default.post(name: .coraxCalendarPrefill, object: nil, userInfo: [
            "summary": suggestion.title,
            "location": suggestion.location ?? "",
            "startsAt": startsAt,
            "endsAt": endsAt,
            "allDay": suggestion.allDay,
        ])
        calendarOpen = true
        Task {
            calendar.settings = settings
            await calendar.loadCalendars()
            await calendar.refresh()
        }
    }

    /// `ai_search_filter` for the text in the search field (⌘O). A ready query
    /// runs immediately; a question shows the option card first.
    func runAISearchFilter(history: [AIFilterTurn] = []) {
        let request = mailbox.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            toasts.show("Erst etwas in die Suche schreiben")
            return
        }
        aiFilterRequest = request
        Task {
            guard let filter = await assistant.searchFilter(request, history: history) else { return }
            switch filter {
            case .query(let query):
                aiFilterQuestion = nil
                mailbox.searchText = query
                mailbox.runSearch()
                mailbox.focusList()
            case .ask(let question):
                aiFilterQuestion = question
            }
        }
    }

    /// Answers the AI filter's clarifying question and asks again.
    func answerAIFilter(_ question: AIFilterQuestion, answer: String) {
        aiFilterQuestion = nil
        Task {
            let history = [AIFilterTurn(question: question.question, answer: answer)]
            guard let filter = await assistant.searchFilter(aiFilterRequest, history: history) else { return }
            switch filter {
            case .query(let query):
                mailbox.searchText = query
                mailbox.runSearch()
                mailbox.focusList()
            case .ask(let next):
                aiFilterQuestion = next
            }
        }
    }

    // MARK: M3.1 — Umbenennen: Daten und Zugangsdaten übernehmen

    /// Datenordner der bisherigen Instanz kopieren und, wenn dabei etwas
    /// ankam, die Schlüsselbund-Einträge übernehmen. Läuft nur hier, einmal je
    /// Start, **vor** dem Host: der Host legt sonst schon den neuen Ordner an.
    private static func takeOverLegacyData(sandbox: Bool, identity: String) -> (outcome: LegacyMigration.Outcome, credentials: Int) {
        // M3.5: zwei Altkennungen, neueste zuerst. Übernommen wird eine Quelle.
        let legacySources = AppIdentity.legacyIdentifiers(sandbox: sandbox)
        let appSupport = LegacyMigration.applicationSupport
        let outcome = LegacyMigration.runIfNeeded(
            appSupport: appSupport,
            from: legacySources,
            to: identity,
            // Sperre des alten Ordners statt Bundle-Kennung: die Sandbox trug
            // früher dieselbe Bundle-Kennung wie die echte Instanz.
            isRunning: { legacy in
                ApplicationChecks.isDataDirectoryLocked(appSupport.appendingPathComponent(legacy))
                    || ApplicationChecks.isRunning(bundleID: legacy)
            },
            defaults: .standard,
            copyDatabase: { source, target in try DatabaseCopy.vacuum(from: source, to: target) }
        )
        guard case .migrated = outcome else { return (outcome, 0) }
        let database = appSupport.appendingPathComponent(identity).appendingPathComponent("comail.db")
        let accounts = CredentialAdoption.accounts(fromIDs: DatabaseCopy.accountIDs(in: database))
        let result = CredentialAdoption.run(
            from: legacySources,
            to: identity,
            accounts: accounts,
            exists: KeychainAccess.exists(service:account:),
            read: KeychainAccess.secret(service:account:),
            write: KeychainAccess.store(service:account:secret:)
        )
        return (outcome, result.adopted)
    }

    // MARK: M2.18n — die `G`-Folge

    /// Start der `g`-Folge: die Statuszeile zeigt den Hinweis, und nach
    /// `GoSequence.window` ist die Folge vorbei, wenn keine zweite Taste kam.
    func beginGoSequence() {
        goSequenceActive = true
        goSequenceGeneration &+= 1
        let generation = goSequenceGeneration
        PerfLog.shared.write("key_go start window=\(Int(GoSequence.window))")
        DispatchQueue.main.asyncAfter(deadline: .now() + GoSequence.window) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.goSequenceActive, self.goSequenceGeneration == generation else { return }
                self.endGoSequence(reason: "timeout")
            }
        }
    }

    /// Ende der Folge: durch die zweite Taste, `Esc` oder die Frist.
    func endGoSequence(reason: String? = nil) {
        guard goSequenceActive else { return }
        goSequenceActive = false
        goSequenceGeneration &+= 1
        if let reason { PerfLog.shared.write("key_go end reason=\(reason)") }
    }

    // MARK: M2.5 — Verschieben, Label, Spam, endgültig löschen, Ansichten

    /// `V`: the move popover for the current selection; it loads the folders.
    func openMovePopover() {
        guard !mailbox.targetIds.isEmpty else { toasts.show("Wähle zuerst einen Thread"); return }
        moveOpen = true
        Task { await mailbox.loadFolders() }
        PerfLog.shared.write("move_popover targets=\(mailbox.targetIds.count)")
    }

    /// `L`: the label popover, on the labels the settings already loaded.
    func openLabelPopover() {
        guard !mailbox.targetIds.isEmpty else { toasts.show("Wähle zuerst einen Thread"); return }
        labelOpen = true
        if !labels.loaded { Task { await labels.load() } }
        PerfLog.shared.write("label_popover targets=\(mailbox.targetIds.count)")
    }

    /// `#` in the Papierkorb: nothing is deleted before the dialog is confirmed.
    func confirmPermanentDelete() {
        guard !mailbox.targetIds.isEmpty else { return }
        permanentDeleteIds = mailbox.targetIds
        permanentDeleteOpen = true
        PerfLog.shared.write("permanent_delete_ask n=\(permanentDeleteIds.count)")
    }

    /// The address the visible thread is about (the other side of the mail).
    func senderAddress(of threadId: Int64?) -> Address? {
        guard let threadId else { return nil }
        if let detail = mailbox.details[threadId] {
            let me = selfEmails
            if let message = detail.messages.last(where: { !me.contains($0.from.email.lowercased()) }) {
                return message.from
            }
            return detail.messages.last?.from
        }
        let me = selfEmails
        return mailbox.thread(threadId)?.participants.first { !me.contains($0.email.lowercased()) }
            ?? mailbox.thread(threadId)?.participants.first
    }

    /// `view-from-sender`: a search for everything from this sender.
    func viewFromSender() {
        guard let sender = senderAddress(of: mailbox.expandedId ?? mailbox.selectedId) else {
            toasts.show("Kein Absender gefunden")
            return
        }
        mailbox.searchText = "from:\(sender.email)"
        mailbox.runSearch()
        mailbox.focusList()
        PerfLog.shared.write("view_from_sender from_len=\(sender.email.count)")
    }

    /// `split-by-sender`: the popover proposes a whole-domain rule; nothing is
    /// written before "Anlegen" (which goes through `save_split`).
    func openSplitPopover() {
        guard let sender = senderAddress(of: mailbox.expandedId ?? mailbox.selectedId) else {
            toasts.show("Kein Absender gefunden")
            return
        }
        splitSuggestion = Pickers.domainSplit(for: sender.email)
        splitOpen = splitSuggestion != nil
        if splitSuggestion == nil { toasts.show("Für diese Adresse gibt es keine Domain") }
        PerfLog.shared.write("split_popover domain=\(splitSuggestion?.domain ?? "-")")
    }

    /// "Auto-Labels neu vergeben" (`relabel_auto`): the splits editor owns the
    /// call, the list only refreshes afterwards.
    ///
    /// K5 aus dem Audit M2: from the palette it clears the sender cache and
    /// classifies the whole inbox, which costs AI calls — so it asks first.
    func relabelAutoLabels() {
        toasts.show("Auto-Labels für den ganzen Posteingang neu vergeben? Das kostet KI-Aufrufe.",
                    actionTitle: "Neu vergeben", duration: 8) { [weak self] in
            self?.runRelabelAutoLabels()
        }
    }

    /// The confirmed step: the settings page's own button and the walkthrough
    /// call it directly.
    func runRelabelAutoLabels() {
        Task {
            guard let count = await splits.relabelAutoLabels() else { return }
            toasts.show(count == 1 ? "1 Thread neu vergeben" : "\(count) Threads neu vergeben")
            mailbox.refresh()
            PerfLog.shared.write("relabel_auto count=\(count)")
        }
    }

    /// The composer commands (`send-done`, `send-later`, `instant-send`,
    /// `attach-files`, `insert-snippet`, `quote-selection`). The composer that
    /// holds the key window acts on them; with no draft open the user is told.
    func composeCommand(_ command: String) {
        guard mailbox.inlineCompose != nil || !composeDrafts.isEmpty else {
            toasts.show("Öffne zuerst einen Entwurf")
            return
        }
        // M2.9: Panel und Inline-Entwurf können gleichzeitig offen sein; das
        // Kürzel gehört dem Entwurf mit der Tastatur, nicht beiden.
        let target = compose.commandTarget ?? mailbox.inlineCompose?.id
        NotificationCenter.default.post(name: .coraxComposeAction, object: command,
                                        userInfo: target.map { ["draft": $0] } ?? [:])
        PerfLog.shared.write("compose_command \(command) target=\(target?.uuidString.prefix(8) ?? "none")")
    }

    /// Ziel für die KI-Kürzel (`⌘J`, `⌘⇧P`): derselbe Entwurf wie bei den
    /// Sende-Kürzeln, sonst der Inline-Entwurf.
    var composeCommandTarget: [String: UUID] {
        (compose.commandTarget ?? mailbox.inlineCompose?.id).map { ["draft": $0] } ?? [:]
    }

    /// `R` / `⇧R` mit markiertem Text: nur die Auswahl wird zitiert (M2.14 §6).
    /// Ohne Auswahl antwortet `fallback` — bei `R` der Absender, bei `⇧R` allen.
    func quoteSelection(fallback: ComposeMode = .replyAll) {
        Task {
            let text = await WebViewPool.shared.selectedText()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                PerfLog.shared.write("quote_selection empty fallback=\(fallback.rawValue)")
                reply(fallback)
                return
            }
            PerfLog.shared.write("quote_selection chars=\(trimmed.count)")
            if mailbox.inlineCompose != nil || !composeDrafts.isEmpty {
                NotificationCenter.default.post(name: .coraxComposeAction, object: "quote:" + trimmed)
                return
            }
            guard let id = mailbox.expandedId ?? mailbox.selectedId else { return }
            if mailbox.selectedId != id { mailbox.select(id) }
            reply(.reply)
            Task {
                for _ in 0..<40 where mailbox.inlineCompose == nil { try? await Task.sleep(for: .milliseconds(25)) }
                mailbox.inlineCompose?.insertQuote(trimmed)
            }
        }
    }

    /// `Space` on an open thread: Quick Look for the focused message's
    /// attachments (inline pictures are skipped, as Tauri does).
    func previewAttachments(startAt index: Int = 0) {
        guard let id = mailbox.expandedId, let detail = mailbox.details[id] else {
            toasts.show("Öffne zuerst einen Thread")
            return
        }
        let message = mailbox.focusedMessage(in: detail) ?? detail.messages.last
        let attachments = (message?.attachments ?? []).filter { !$0.isInline }
        guard !attachments.isEmpty else {
            toasts.show("Keine Anhänge in dieser Nachricht")
            PerfLog.shared.write("preview_none thread=\(id)")
            return
        }
        AttachmentPreview.shared.show(attachments: attachments, startAt: index, threadId: id)
    }

    // MARK: Compose

    var selfEmails: Set<String> { Set(mailbox.accounts.map { $0.email.lowercased() }) }

    /// `C` legt den Entwurf ins Panel, `⌥C` und `mailto:` ins eigene Fenster.
    func composeNew(to: [Address] = [], cc: [Address] = [], bcc: [Address] = [], subject: String = "",
                    body: String = "", docked: Bool = true) {
        guard let client else { return }
        guard let account = mailbox.accounts.first(where: { $0.id == mailbox.accountId }) ?? mailbox.accounts.first else {
            accountSheetOpen = true; return
        }
        // Die Obergrenze gilt vor dem Anlegen: ein fünftes `C` legt nichts an
        // und sagt warum (§3.4).
        if docked, compose.isFull {
            toasts.show("Höchstens \(ComposeDock.maxDrafts) Entwürfe – einen senden oder schließen")
            PerfLog.shared.write("compose_dock_refused full=1")
            return
        }
        let draft = ComposeDraft(mode: .new, accountId: account.id, inReplyTo: nil, to: to, cc: cc, subject: subject,
                                 body: body, client: client, aiClient: aiClientOverride,
                                 toasts: toasts, settings: settings)
        draft.bcc = bcc
        composeDrafts[draft.id] = draft
        if docked {
            compose.add(draft.id, as: .open)
        } else {
            compose.add(draft.id, as: .window)
            openComposeWindow?(draft.id)
        }
    }

    // MARK: Verfassen-Panel (M2.9 Stufe B)

    /// „Lösen" im Inline-Entwurf: derselbe Entwurf wandert ins Panel, nichts
    /// wird kopiert (§3.7).
    func detachInlineDraft() {
        guard let draft = mailbox.inlineCompose else {
            PerfLog.shared.write("inline_detach none=1")
            return
        }
        guard !compose.isFull else {
            toasts.show("Höchstens \(ComposeDock.maxDrafts) Entwürfe – einen senden oder schließen")
            PerfLog.shared.write("inline_detach refused=full")
            return
        }
        mailbox.inlineCompose = nil
        composeDrafts[draft.id] = draft
        compose.add(draft.id, as: .open)
        PerfLog.shared.write("inline_detach id=\(draft.id.uuidString.prefix(8))")
    }

    /// Der Thread wird zugeklappt oder gewechselt: ein nicht leerer Entwurf
    /// wird zur Leiste, statt still zu verschwinden (§3.7).
    func dockAbandonedInlineDraft(_ draft: ComposeDraft) {
        guard composeDrafts[draft.id] == nil else { return }
        guard !draft.isEmpty else { return }
        guard !compose.isFull else {
            toasts.show("Höchstens \(ComposeDock.maxDrafts) Entwürfe – einen senden oder schließen")
            PerfLog.shared.write("inline_abandoned full=1")
            return
        }
        composeDrafts[draft.id] = draft
        compose.add(draft.id, as: .minimized)
        PerfLog.shared.write("inline_abandoned id=\(draft.id.uuidString.prefix(8))")
    }

    /// Nach dem Senden: der Platz wird frei, der Fokus geht an die Liste.
    func composeDraftLeft(_ draft: ComposeDraft, presentation: ComposePresentation,
                          closeWindow: () -> Void) {
        composeDrafts[draft.id] = nil
        compose.remove(draft.id)
        if presentation == .inline, mailbox.inlineCompose?.id == draft.id { mailbox.inlineCompose = nil }
        if presentation == .window { closeWindow() }
        mailbox.focusList()
    }

    /// „Rückgängig" nach dem Senden: der Entwurf kommt dorthin zurück, wo er war.
    func composeDraftReturned(_ draft: ComposeDraft, presentation: ComposePresentation) {
        switch presentation {
        case .inline:
            mailbox.inlineCompose = draft
        case .window:
            composeDrafts[draft.id] = draft
            compose.add(draft.id, as: .window)
            openComposeWindow?(draft.id)
        case .docked:
            composeDrafts[draft.id] = draft
            compose.add(draft.id, as: .open)
        }
        toasts.show(Strings.undone)
    }

    /// `xmark` im Panel-Kopf: der Entwurf bleibt erhalten (wie Gmail), das
    /// Panel schließt und der Fokus geht an die Liste.
    func closeDockedDraft(_ id: UUID) {
        guard let draft = composeDrafts[id] else { return }
        composeDrafts[id] = nil
        compose.remove(id)
        mailbox.focusList()
        if !draft.savedOnce, !draft.isEmpty {
            Task { _ = await draft.saveNow() }
            toasts.show("Entwurf gesichert")
        }
        PerfLog.shared.write("compose_close id=\(id.uuidString.prefix(8)) saved=\(draft.savedOnce ? 1 : 0)")
    }

    /// `trash` bzw. `⌘⇧⌫`: verwerfen, mit Rückgängig-Toast.
    func discardDockedDraft(_ id: UUID) {
        guard let draft = composeDrafts[id] else { return }
        let hadContent = !draft.isEmpty
        composeDrafts[id] = nil
        compose.remove(id)
        draft.discard()
        mailbox.focusList()
        guard hadContent else {
            PerfLog.shared.write("compose_discard empty=1")
            return
        }
        toasts.show("Entwurf verworfen", actionTitle: Strings.undo, action: { [weak self] in
            guard let self else { return }
            let copy = draft.restoredCopy()
            self.composeDrafts[copy.id] = copy
            self.compose.add(copy.id, as: .open)
        })
        PerfLog.shared.write("compose_discard id=\(id.uuidString.prefix(8))")
    }

    /// `⌘⇧⌫` ohne Maus: den offenen bzw. fokussierten Entwurf verwerfen.
    func discardOpenDraft() {
        if let id = compose.openId ?? compose.keyboardFocus {
            discardDockedDraft(id)
        } else if mailbox.inlineCompose != nil {
            discardInlineDraft()
        } else {
            toasts.show("Kein Entwurf offen")
        }
    }

    /// „Im Hauptfenster andocken" aus dem Fenster: der Entwurf wird offen.
    func dockComposeWindow(_ id: UUID) {
        compose.dock(id)
        PerfLog.shared.write("compose_redock id=\(id.uuidString.prefix(8))")
    }

    /// Das Fenster wurde geschlossen (roter Knopf) oder der Entwurf verlässt es:
    /// ein noch nicht gesendeter Entwurf wird zur Leiste.
    func composeWindowClosed(_ id: UUID) {
        guard let draft = composeDrafts[id], compose.state(id) != nil else { return }
        guard compose.state(id) == .window else { return }
        guard !compose.isFull else {
            toasts.show("Höchstens \(ComposeDock.maxDrafts) Entwürfe – einen senden oder schließen")
            return
        }
        compose.dock(id, as: .minimized)
        PerfLog.shared.write("compose_window_closed id=\(id.uuidString.prefix(8)) saved=\(draft.savedOnce ? 1 : 0)")
    }

    /// `⌃Tab` / `⌃⇧Tab`: Fokus reihum, zuletzt zurück an die Liste (§3.5).
    func cycleDraftFocus(backward: Bool = false) {
        guard let id = compose.cycleFocus(backward: backward) else {
            mailbox.focusList()
            return
        }
        composeDrafts[id]?.editorHost?.focusEditor()
    }

    /// `⌘⇧M`: minimieren bzw. den letzten Entwurf wieder öffnen.
    func toggleComposeDock() {
        guard !compose.isEmpty else {
            toasts.show("Kein Entwurf offen")
            return
        }
        compose.toggleMinimize()
        if let id = compose.openId { composeDrafts[id]?.editorHost?.focusEditor() }
    }

    /// A `mailto:` URL, from the system (`onOpenURL`, the bundle registers the
    /// scheme) or from a link inside a mail (the core's `open_url`). The same
    /// parser handles both (M2.4, requirement 3).
    func composeMailto(_ url: URL) {
        guard let link = MailtoLink.parse(url) else {
            toasts.show("Kein gültiger mailto:-Link", isError: true)
            PerfLog.shared.write("mailto refused chars=\(url.absoluteString.count)")
            return
        }
        PerfLog.shared.write("mailto open to=\(link.to.count) cc=\(link.cc.count) bcc=\(link.bcc.count) "
                             + "subject=\(link.subject.count) body=\(link.body.count)")
        composeNew(to: link.toAddresses, cc: link.ccAddresses, bcc: link.bcc.map { Address(name: nil, email: $0) },
                   subject: link.subject, body: link.body)
    }

    // MARK: M2.4 — Bestätigungscode und Abmelden

    /// "Bestätigungscode kopieren" (`latest_verification_code`).
    func copyLatestVerificationCode() {
        Task { await aux.copyVerificationCode() }
    }

    /// "Abmelden" (`⌘U`): resolve the thread's unsubscribe message, then ask
    /// before the core acts (K3 aus dem Audit M2 — see `AuxActionsStore`).
    func unsubscribeThread(_ threadId: Int64) {
        let sender = senderAddress(of: threadId)?.email
        Task { await aux.unsubscribe(threadId: threadId, sender: sender) }
    }

    // MARK: Zähler für Menüleiste und Dock (M2.4)

    /// Ungelesen im Posteingang — the number the menu bar icon and the Dock
    /// badge show (Tauri's badge source default; the setting is not exposed).
    var unreadBadge: Int64 { mailbox.unread?.inbox ?? 0 }

    private func updateBadge(_ counts: UnreadCounts) {
        guard NSApp != nil else { return }
        let value = settings.dockBadgeEnabled ? counts.inbox : 0
        NSApp.dockTile.badgeLabel = value > 0 ? "\(value)" : nil
    }

    /// The avatar lookup runs off the main actor; it only reads the client.
    nonisolated static func avatar(for email: String) async -> String? {
        guard let client = await MainActor.run(body: { AppModel.shared.client }) else { return nil }
        return try? await client.senderAvatar(email)
    }

    #if DEBUG || CORAX_TEST_HOOKS
    /// Walkthrough (hook builds only): feeds one `{"name","payload"}` line
    /// through the normal event routing, so streaming and reminders are
    /// exercised on the same path the host uses.
    func debugReceive(_ json: String) { receive(json) }

    /// Closes the main window the way the red button does.
    func debugCloseMainWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == Instance.title }) else { return false }
        window.performClose(nil)
        return true
    }

    /// Brings the main window back after it was closed (menu bar / Dock path).
    func debugShowMainWindow() {
        NotificationCenter.default.post(name: .coraxShowMainWindow, object: nil)
    }

    /// The avatar cache as one log line.
    func debugAvatarState() -> String {
        let photos = avatars.entries.values.filter { if case .photo = $0 { return true } else { return false } }.count
        return "enabled=\(avatars.enabled ? 1 : 0) entries=\(avatars.entries.count) photos=\(photos) "
            + "bytes=\(avatars.bytes) revision=\(avatars.revision)"
    }
    #endif

    /// `Esc` in the inline draft (TASTATUR.md): discard at once, no question;
    /// the toast restores text and draft.
    func discardInlineDraft() {
        guard let draft = mailbox.inlineCompose else { return }
        let threadId = mailbox.expandedId
        let hadContent = !draft.isEmpty
        draft.discard()
        mailbox.inlineCompose = nil
        mailbox.focusList()
        guard hadContent else { return }
        toasts.show("Entwurf verworfen", actionTitle: Strings.undo, action: { [weak self] in
            guard let self else { return }
            if let threadId, self.mailbox.expandedId != threadId { self.mailbox.expand(threadId) }
            self.mailbox.inlineCompose = draft.restoredCopy()
        })
    }

    /// `A`/`⇧A`/`W` (`R`/`⇧R`/`F`): inline under the expanded thread, on the
    /// focused message (state B) or the newest one (state A).
    func reply(_ mode: ComposeMode) {
        guard let client, let id = mailbox.selectedId else { return }
        let wasOpen = mailbox.expandedId == id
        let open = {
            guard let detail = self.mailbox.details[id] else { return }
            let target = wasOpen ? self.mailbox.focusedMessage(in: detail)?.id : nil
            let sender = self.mailbox.accounts.first { $0.id == detail.thread.accountId }
            let draft = ComposeDraft.reply(mode: mode, to: detail, messageId: target, selfEmails: self.selfEmails,
                                           senderName: sender?.displayName ?? sender?.email,
                                           aiClient: self.aiClientOverride, client: client,
                                           toasts: self.toasts, settings: self.settings)
            self.mailbox.inlineCompose = draft
        }
        if mailbox.expandedId != id { mailbox.expand(id) }
        if mailbox.details[id] != nil {
            open()
        } else {
            Task {
                for _ in 0..<40 where mailbox.details[id] == nil { try? await Task.sleep(for: .milliseconds(25)) }
                open()
            }
        }
    }
}
