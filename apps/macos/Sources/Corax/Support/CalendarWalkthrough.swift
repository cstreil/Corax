import AppKit
import Foundation
import CoraxKit

#if DEBUG || CORAX_TEST_HOOKS

/// M2.2 walkthrough helpers. Hook builds only (`CORAX_TEST_HOOKS=1`), and only
/// against the sandbox: the real instance refuses every step.
///
/// There is no calendar in the sandbox (no CalDAV account), so the seed creates
/// local events through the *existing* `create_event` command with no
/// `calendarId` — that is exactly what a user gets without a connected
/// calendar. Nothing is written to the core.
@MainActor
enum CalendarWalkthrough {
    static func open() {
        guard requireSandbox("open") else { return }
        let model = AppModel.shared
        model.calendarOpen = true
        Task {
            await model.calendar.loadCalendars()
            await model.calendar.refresh()
            log("open mode=\(model.calendar.mode.rawValue) events=\(model.calendar.events.count)")
        }
    }

    static func setMode(_ raw: String) {
        guard requireSandbox("mode") else { return }
        guard let mode = CalendarStore.Mode(rawValue: raw) else { log("mode unknown=\(raw)"); return }
        let store = AppModel.shared.calendar
        store.settings = AppModel.shared.settings
        store.setMode(mode)
        Task {
            await store.refresh()
            log("mode \(mode.rawValue) days=\(store.days.count) events=\(store.events.count)")
        }
    }

    static func today() {
        guard requireSandbox("today") else { return }
        AppModel.shared.calendar.jumpToToday()
    }

    static func page(_ delta: Int) {
        guard requireSandbox("page") else { return }
        AppModel.shared.calendar.page(delta)
    }

    /// Seeds a week of local events (incl. an all-day and a multi-day one), then
    /// runs the write cycle: move, edit, delete, undo.
    static func runScenario() async {
        guard requireSandbox("scenario") else { return }
        let model = AppModel.shared
        let store = model.calendar
        store.settings = model.settings
        await store.loadCalendars()
        await store.refresh()
        guard let accountId = model.mailbox.accounts.first?.id else {
            log("scenario no_account"); return
        }
        guard let client = store.client else { log("scenario no_client"); return }

        let math = store.math
        // Seeds are relative to the week start, so they are always inside the
        // visible week (the old version anchored on "today", which fell out of
        // the week as the clock crossed midnight mid-run).
        let weekStart = math.startOfWeek(store.anchor)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Int64 {
            math.at(math.addDays(weekStart, dayOffset), hour: hour, minute: minute)
        }
        let seed: [(String, Int64, Int64, Bool, String?)] = [
            ("Team-Sync", at(0, 9), at(0, 9, 30), false, "Raum 2"),
            ("Design-Review", at(0, 10), at(0, 11), false, nil),
            ("Mittag mit Sam", at(0, 12), at(0, 13), false, "Café Nord"),
            ("Planung nächste Woche", at(1, 14), at(1, 15, 30), false, nil),
            ("Zahnarzt", at(2, 8, 30), at(2, 9, 15), false, "Praxis am Ring"),
            ("Konferenz", at(3, 0), math.addDays(at(3, 0), 3), true, "Berlin"),
            ("Fokuszeit", at(4, 9), at(4, 12), false, nil),
            ("Abendessen", at(5, 19), at(5, 20, 30), false, nil),
        ]
        var ids: [Int64] = []
        for (title, start, end, allDay, location) in seed {
            do {
                let event = try await client.createEvent(CreateEventArgs(
                    accountId: accountId, calendarId: nil, summary: title,
                    description: nil, location: location, joinUrl: nil,
                    startsAt: start, endsAt: end, allDay: allDay, attendees: []))
                ids.append(event.id)
            } catch {
                log("scenario create_failed title=\(title) error=\(CoraxClientError.from(error).code)")
            }
        }
        await store.refresh()
        log("scenario seed count=\(ids.count) events=\(store.events.count)")

        guard !ids.isEmpty else { return }

        // 1. Move: the second event one day later and 30 minutes down.
        if let event = store.events.first(where: { $0.summary == "Design-Review" }) {
            let moved = math.shiftEvent(startsAt: event.startsAt,
                                        endsAt: CalendarEventRules.eventEnd(event),
                                        dayDelta: 2, minuteDelta: 30)
            let ok = await store.move(event, startsAt: moved.startsAt, endsAt: moved.endsAt)
            log("scenario move ok=\(ok) from=\(CalendarChrome.time(event.startsAt)) to=\(CalendarChrome.time(moved.startsAt)) day=\(math.dayOfMonth(moved.startsAt))")
        }

        // 2. Edit: rename the first event, keep its times.
        if let event = store.events.first(where: { $0.summary == "Team-Sync" }) {
            let ok = await store.update(UpdateEventArgs(
                eventId: event.id, summary: "Team-Sync (geändert)", description: "Notiz aus dem Walkthrough",
                location: event.location, joinUrl: nil, startsAt: event.startsAt,
                endsAt: CalendarEventRules.eventEnd(event), allDay: event.allDay,
                attendees: [], notify: true))
            let seen = store.events.first { $0.id == event.id }?.summary ?? "-"
            log("scenario update ok=\(ok) title=\(seen)")
        }

        // 3. Delete + undo through the toast's own action (the real path).
        if let event = store.events.first(where: { $0.summary == "Planung nächste Woche" }) {
            let before = store.events.count
            await store.delete(event)
            let afterDelete = store.events.count
            let undone = model.toasts.runAction()
            try? await Task.sleep(for: .milliseconds(300))
            let afterUndo = store.events.count
            log("scenario delete title=\(event.summary ?? "-") before=\(before) after=\(afterDelete) undo=\(undone) restored=\(afterUndo)")
        }

        let model0 = store.weekModel
        log("scenario done events=\(store.events.count) bars=\(model0?.allDaySpans.count ?? -1) rows=\(model0?.allDayRows ?? -1)")
    }

    /// Requirement 7: 200 events in one week, then 20 week switches end to end
    /// (fetch + layout). The layout duration is the `week_switch` signpost.
    static func runPerf() async {
        guard requireSandbox("perf") else { return }
        let model = AppModel.shared
        let store = model.calendar
        store.settings = model.settings
        await store.refresh()
        guard let accountId = model.mailbox.accounts.first?.id else {
            log("perf no_account"); return
        }
        guard let client = store.client else { log("perf no_client"); return }

        let math = store.math
        let weekStart = math.startOfWeek(store.anchor)
        let created = await seedMany(count: 200, weekStart: weekStart, accountId: accountId, client: client)
        await store.refresh()
        log("perf seeded count=\(created.count) events=\(store.events.count)")

        var totals: [Double] = []
        var layouts: [Double] = []
        var fetchMax = 0.0
        for i in 0..<20 {
            // Let the previous week's render settle, otherwise its main-thread
            // work lands in this measurement (it did: 123 ms for an empty week).
            try? await Task.sleep(for: .milliseconds(250))
            let start = Date()
            store.anchor = store.math.addDays(weekStart, (i % 2 == 0 ? 7 : 0))
            await store.refresh()
            let total = Date().timeIntervalSince(start) * 1000
            totals.append(total)
            layouts.append(store.lastLayoutMilliseconds)
            fetchMax = max(fetchMax, store.lastFetchMilliseconds)
            log(String(format: "perf step=%d events=%d total=%.2fms fetch=%.2fms layout=%.2fms",
                       i, store.visibleEvents.count, total, store.lastFetchMilliseconds,
                       store.lastLayoutMilliseconds))
        }
        let sorted = layouts.sorted()
        let median = sorted[sorted.count / 2]
        log(String(format: "perf result n=%d layout min=%.2fms median=%.2fms max=%.2fms fetch max=%.2fms",
                   layouts.count, sorted.first ?? 0, median, sorted.last ?? 0,
                   fetchMax))

        for id in created {
            try? await client.deleteEvent(id, notify: false)
        }
        store.anchor = math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000))
        await store.refresh()
        log("perf cleanup left=\(store.events.count)")
    }

    private static func seedMany(count: Int, weekStart: Int64, accountId: Int64,
                                 client: any CalendarCore) async -> [Int64] {
        var ids: [Int64] = []
        ids.reserveCapacity(count)
        for i in 0..<count {
            let day = weekStart + Int64(i % 5) * CalendarGrid.dayMs
            let start = day + Int64(8 + (i % 10)) * 3_600_000 + Int64(i % 4) * 15 * 60_000
            let end = start + Int64(20 + (i % 5) * 10) * 60_000
            do {
                let event = try await client.createEvent(CreateEventArgs(
                    accountId: accountId, calendarId: nil, summary: "Lasttest \(i)",
                    startsAt: start, endsAt: end))
                ids.append(event.id)
            } catch { log("perf create_failed i=\(i)") }
        }
        return ids
    }

    /// `calendar:seedday:<n>` — n short events on the anchor day (one with a
    /// join link), so the month view has to fold rows behind "+N weitere" and
    /// `join-next-meeting` has something to open.
    static func seedDay(count: Int) async {
        guard requireSandbox("seedday") else { return }
        let model = AppModel.shared
        let store = model.calendar
        store.settings = model.settings
        await store.loadCalendars()
        await store.refresh()
        guard let accountId = model.mailbox.accounts.first?.id, let client = store.client else {
            log("seedday no_account"); return
        }
        let math = store.math
        let day = math.startOfDay(store.anchor)
        var created = 0
        for index in 0..<max(0, count) {
            let start = day + Int64(9 + index) * 3_600_000
            do {
                _ = try await client.createEvent(CreateEventArgs(
                    accountId: accountId, calendarId: nil,
                    summary: index == 0 ? "Team-Meeting" : "Termin \(index + 1)",
                    description: nil, location: index == 0 ? "Raum 2" : nil,
                    joinUrl: index == 0 ? "https://meet.example.test/team" : nil,
                    startsAt: start, endsAt: start + 30 * 60_000, allDay: false, attendees: []))
                created += 1
            } catch {
                log("seedday failed i=\(index) error=\(CoraxClientError.from(error).code)")
            }
        }
        await store.refresh()
        let onDay = store.visibleEvents.filter { $0.startsAt < day + CalendarGrid.dayMs &&
            CalendarEventRules.eventEnd($0) > day }
        log("seedday created=\(created) day=\(CalendarChrome.dayNumber(day)) ms=\(day) events=\(onDay.count)")
    }

    /// `calendar:join[:dry]` — which meeting "Nächstem Meeting beitreten" would
    /// open, and whether its link passes the allowlist. `dry` never opens it.
    static func join(dry: Bool) async {
        guard requireSandbox("join") else { return }
        let model = AppModel.shared
        guard let client = model.calendar.client else { log("join no_client"); return }
        let now = Date()
        let range = MeetingLink.range(now: now)
        let rows = (try? await client.listEvents(startMs: range.start, endMs: range.end)) ?? []
        let next = MeetingLink.next(from: rows, now: now)
        let url = MeetingLink.url(next?.joinUrl)
        log("join events=\(rows.count) next=\(next?.id ?? -1) title=\(next?.summary ?? "-") "
            + "allowed=\(url != nil ? 1 : 0) dry=\(dry ? 1 : 0)")
        if next != nil, url == nil { log("join refused=link") }
        if !dry { model.joinNextMeeting() }
    }

    static func sidebar() {
        guard requireSandbox("sidebar") else { return }
        let store = AppModel.shared.calendar
        store.sidebarVisible.toggle()
        log("sidebar visible=\(store.sidebarVisible ? 1 : 0)")
    }

    /// `calendar:daylist:<day-ms>` opens the "+N weitere" card for a screenshot.
    static func dayList(_ argument: String) {
        guard requireSandbox("daylist") else { return }
        let store = AppModel.shared.calendar
        let day = Int64(argument) ?? store.todayStart
        NotificationCenter.default.post(name: .coraxCalendarDayList, object: nil, userInfo: ["day": day])
        let events = store.visibleEvents.filter { event in
            event.startsAt < day + CalendarGrid.dayMs && CalendarEventRules.eventEnd(event) > day
        }
        log("daylist day=\(CalendarChrome.dayNumber(day)) events=\(events.count) "
            + "titles=\(events.map { $0.summary ?? "-" }.joined(separator: " | "))")
    }

    static func state() {
        let store = AppModel.shared.calendar
        let events = store.visibleEvents
        let sync: String
        switch store.syncStatus {
        case .noCalendars: sync = "noCalendars"
        case .neverSynced: sync = "neverSynced"
        case .current: sync = "current"
        case .stale: sync = "stale"
        }
        // M2.13: `selDay` und `rows` belegen die Jahresansicht und die
        // Terminliste (gewählter Tag, Zeilenzahl der Liste).
        let rows = AgendaModel.rows(events: events, days: store.days,
                                    openEvent: store.openEventId, today: store.todayStart)
        log("calendar_state open=\(AppModel.shared.calendarOpen) mode=\(store.mode.rawValue) anchorDay=\(store.math.dayOfMonth(store.anchor)) selDay=\(store.math.dayOfMonth(store.selectedDayOrToday)) rows=\(rows.count) days=\(store.days.count) events=\(events.count) bars=\(store.weekModel?.allDaySpans.count ?? -1) calendars=\(store.calendars.count) hidden=\(store.hiddenCalendars.sorted()) local=\(!store.hiddenLocal) sync=\(sync) layoutMs=\(String(format: "%.2f", store.lastLayoutMilliseconds)) \(cardState())")
    }

    /// `calendar:dump` — jeder sichtbare Termin mit Anzeige- und Kern-Kennung,
    /// Wiederholungsmarke, Bearbeitungsrecht und Grund. Der Beleg für M2.18 §2/§5:
    /// ohne diese Zeilen sieht man im Log nicht, *warum* ein Stift fehlt.
    static func dump() {
        guard requireSandbox("dump") else { return }
        let store = AppModel.shared.calendar
        let events = store.visibleEvents.sorted { $0.startsAt < $1.startsAt }
        log("calendar_dump n=\(events.count) mode=\(store.mode.rawValue) "
            + "sel=\(store.selectedEventId.map(String.init) ?? "-") "
            + "open=\(store.openEventId.map(String.init) ?? "-")")
        for event in events {
            let reason = store.editBlockReason(event) ?? "-"
            log("event id=\(event.id) core=\(event.eventId) start=\(event.startsAt) "
                + "series=\(event.isSeriesOccurrence ? 1 : 0) "
                + "canEdit=\(store.canEdit(event) ? 1 : 0) reason=\(reason) "
                + "title=\"\(event.summary ?? "")\"")
        }
    }

    /// `calendar:card:…` — die Karte am Ort (M2.9 Stufe C), ohne Zeiger:
    ///   card:open:<id> | edit | close | new | cancel | select:<±1> | save | state
    static func card(_ argument: String) {
        guard requireSandbox("card") else { return }
        let store = AppModel.shared.calendar
        // `argument` kommt als "card:open:…" an: das erste Stück ist der Befehl.
        let spec = Array(argument.split(separator: ":").dropFirst()).map(String.init)
        switch spec.first ?? "state" {
        case "open":
            // Ohne Kennung: den ausgewählten Termin (nach `select`).
            if spec.count > 1, let id = Int64(spec[1]) {
                store.openCard(id)
            } else if let selected = store.selectedEvent {
                store.openCard(selected.id)
            }
        case "edit":
            store.editOpenCard()
        case "close":
            store.closeCard()
        case "cancel":
            store.cancelEdit()
        case "new":
            let start = store.math.at(store.math.startOfDay(store.anchor), hour: 11)
            store.beginDraft(CalendarEventDraft(startsAt: start, endsAt: start + 60 * 60_000,
                                                title: "Neuer Termin"))
        case "select":
            store.selectAdjacent(Int(spec.count > 1 ? spec[1] : "1") ?? 1)
        case "save":
            store.requestSave()
        default:
            break
        }
        log("card \(cardState())")
    }

    /// Der Zustand der Karte als eine Zeile.
    static func cardState() -> String {
        let store = AppModel.shared.calendar
        return "open=\(store.openEventId.map(String.init) ?? "-")"
            + " mode=\(store.cardMode.rawValue) draft=\(store.draft == nil ? 0 : 1)"
            + " selected=\(store.selectedEventId.map(String.init) ?? "-")"
            + " visible=\(store.visibleEvents.count)"
    }

    /// `calendar:click:<id>` — one click on a block, fed into the grid's own
    /// handler (`click` → click router → card). Used when a real
    /// pointer click cannot be delivered: on this Mac the user is working, and
    /// a background app drops synthetic HID clicks.
    static func click(id: Int64, times: Int) {
        guard requireSandbox("click") else { return }
        for index in 0..<max(1, times) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.08) {
                NotificationCenter.default.post(name: .coraxCalendarClick, object: nil,
                                                userInfo: ["id": NSNumber(value: id)])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            PerfLog.shared.write("calendar_walk card \(cardState()) clicks=\(times) id=\(id)")
        }
    }

    /// Which windows besides the main one are on screen (the detail card is an
    /// `_NSPopoverWindow`; the editor is the window's sheet).
    static func popoverState() -> String {
        let main = NSApp.windows.first { $0.title == Instance.title }
        let others = NSApp.windows
            .filter { $0 !== main && $0.isVisible && $0.frame.width > 80 && $0.frame.height > 40 }
            .map { "\(String(describing: type(of: $0))):\(Int($0.frame.width))x\(Int($0.frame.height))" }
        return "sheet=\(main?.attachedSheet != nil ? 1 : 0) windows=[\(others.joined(separator: ","))]"
    }

    /// `calendar:editorstate` — M2.9: die Bearbeitung liegt in der Karte, es
    /// gibt kein Sheet und kein Popover mehr.
    static func editorState() {
        let main = NSApp.windows.first { $0.title == Instance.title }
        PerfLog.shared.write("calendar_walk editor sheet=\(main?.attachedSheet != nil ? 1 : 0) "
                             + "firstResponder=\(String(describing: main?.firstResponder.map { type(of: $0) })) "
                             + "\(cardState()) \(popoverState())")
    }

    // MARK: M2.12 — Verbinden, Status, Navigation

    /// `calendar:seedm212` — fünf Termine in dieser Woche und zwei in der
    /// nächsten, damit `↓` über den Wochenrand läuft. Räumt den Seed eines
    /// früheren Laufs vorher weg (gleiche Sandbox-Datenbank).
    static func seedM212() async {
        guard requireSandbox("seedm212") else { return }
        let model = AppModel.shared
        let store = model.calendar
        store.settings = model.settings
        await store.loadCalendars()
        guard let accountId = model.mailbox.accounts.first?.id, let client = store.client else {
            log("seedm212 no_account"); return
        }
        let math = store.math
        let weekStart = math.startOfWeek(store.anchor)
        let range = (start: math.addDays(weekStart, -1), end: math.addDays(weekStart, 15))
        let existing = (try? await client.listEvents(startMs: range.start, endMs: range.end)) ?? []
        var removed = 0
        for event in existing where (event.summary ?? "").hasPrefix("M212 ") {
            try? await client.deleteEvent(event.id, notify: false)
            removed += 1
        }
        func at(_ dayOffset: Int, _ hour: Int) -> Int64 {
            math.at(math.addDays(weekStart, dayOffset), hour: hour)
        }
        let seed: [(String, Int64, Int64, String?)] = [
            ("M212 Wochenstart", at(0, 9), at(0, 10), "Raum 2"),
            ("M212 Dienstag", at(1, 11), at(1, 12), nil),
            ("M212 Mittwoch", at(2, 14), at(2, 15), nil),
            ("M212 Donnerstag", at(3, 8), at(3, 9), nil),
            ("M212 Freitag", at(4, 16), at(4, 17), "Café Nord"),
            ("M212 Montag nächste Woche", at(7, 10), at(7, 11), nil),
            ("M212 Dienstag nächste Woche", at(8, 13), at(8, 14), nil),
        ]
        var ids: [Int64] = []
        for (title, start, end, location) in seed {
            if let event = try? await client.createEvent(CreateEventArgs(
                accountId: accountId, calendarId: nil, summary: title, description: nil,
                location: location, joinUrl: nil, startsAt: start, endsAt: end,
                allDay: false, attendees: [])) {
                ids.append(event.id)
            }
        }
        store.anchor = weekStart
        store.setMode(.week)
        await store.refresh()
        store.selectedEventId = ids.first
        log("seedm212 removed=\(removed) created=\(ids.count) week=\(store.heading()) "
            + "events=\(store.visibleEvents.count) first=\(ids.first ?? -1)")
    }

    /// `calendar:connect:<server>|<user>|<password>` — derselbe Aufruf wie der
    /// „Verbinden“-Knopf der Einstellungen. Das Passwort steht nie im Log.
    static func connect(_ argument: String) async {
        guard requireSandbox("connect") else { return }
        let model = AppModel.shared
        let store = model.calendar
        let payload = argument.hasPrefix("connect:")
            ? String(argument.dropFirst("connect:".count)) : argument
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let server = parts.count > 0 ? parts[0] : ""
        let user = parts.count > 1 ? parts[1] : ""
        let secret = parts.count > 2 ? parts[2] : ""
        guard let accountId = model.mailbox.accounts.first?.id else {
            log("connect no_account"); return
        }
        let ok = await store.connectCalendar(accountId: accountId, server: server,
                                             username: user, password: secret)
        log("connect done ok=\(ok ? 1 : 0) server=\(server) user=\(user) calendars=\(store.calendars.count) "
            + "error=\(store.connectError ?? "-") notice=\(store.connectNotice ?? "-")")
    }

    /// `calendar:connectstate` — Statuszeile der Einstellungen als eine Zeile.
    static func connectState() {
        let store = AppModel.shared.calendar
        let status: String
        switch store.syncStatus {
        case .noCalendars: status = "noCalendars"
        case .neverSynced: status = "neverSynced"
        case .current: status = "current"
        case .stale: status = "stale"
        }
        log("connectstate status=\(status) calendars=\(store.calendars.count) "
            + "lastSync=\(store.lastSyncAt.map(String.init) ?? "-") "
            + "unconfirmed=\(store.lastSyncUnconfirmed ? 1 : 0) "
            + "error=\(store.connectError ?? "-") notice=\(store.connectNotice ?? "-")")
    }

    /// `calendar:syncnow` — derselbe Aufruf wie „Jetzt synchronisieren“ in den
    /// Einstellungen (inkl. der Bestätigung über `last_synced_at`).
    static func syncNow() async {
        guard requireSandbox("syncnow") else { return }
        let store = AppModel.shared.calendar
        let ok = await store.syncNow()
        connectState()
        log("syncnow confirmed=\(ok ? 1 : 0) toast=\(AppModel.shared.toasts.current?.text ?? "-")")
    }

    private static func requireSandbox(_ step: String) -> Bool {
        guard Instance.isSandbox else {
            log("\(step) refused=not_sandbox")
            return false
        }
        return true
    }

    private static func log(_ line: String) { PerfLog.shared.write("calendar_walk \(line)") }
}
#else
@MainActor
enum CalendarWalkthrough {
    static func open() {}
    static func setMode(_ raw: String) {}
    static func today() {}
    static func page(_ delta: Int) {}
    static func runScenario() async {}
    static func runPerf() async {}
    static func seedDay(count: Int) async {}
    static func join(dry: Bool) async {}
    static func sidebar() {}
    static func dayList(_ argument: String) {}
    static func click(id: Int64, times: Int) {}
    static func editorState() {}
    static func state() {}
    static func dump() {}
    static func seedM212() async {}
    static func connect(_ argument: String) async {}
    static func connectState() {}
    static func syncNow() async {}
}
#endif
