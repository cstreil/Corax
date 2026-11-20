import Foundation
import Observation
import os

/// Calendar state for the native app (M2.2). Owns the visible range, the events
/// the core returned for it, the calendars and the week model the grids draw.
/// Every write goes through `CalendarCore` (the real client, or a fake in the
/// tests) and is followed by a reload, so the UI never shows an event the core
/// did not keep.
@MainActor
@Observable
public final class CalendarStore {
    public enum Mode: String, Sendable, CaseIterable, Identifiable {
        case day, week, month
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .day: "Tag"
            case .week: "Woche"
            case .month: "Monat"
            }
        }
    }

    public private(set) var calendars: [CalendarCollection] = []
    /// Everything the core returned for the visible range, unfiltered.
    public private(set) var events: [CalendarEvent] = []
    public private(set) var messageEvents: [Int64: [CalendarEvent]] = [:]
    public private(set) var loaded = false
    public private(set) var loading = false
    public private(set) var busy = false
    /// Layout of the day/week grids for the current range (nil in month view).
    public private(set) var weekModel: CalendarWeekModel?
    /// Duration of the last grid build in milliseconds (same number as the
    /// `week_switch` signpost interval; the perf hook reads it).
    public private(set) var lastLayoutMilliseconds: Double = 0
    /// Duration of the last `list_events` round trip in milliseconds.
    public private(set) var lastFetchMilliseconds: Double = 0

    /// The event a click last picked (M2.8b): `Return` opens it, `⌫` deletes
    /// it, like the mail list's row cursor.
    public var selectedEventId: Int64?

    /// The selected event while it is still in the visible range.
    public var selectedEvent: CalendarEvent? {
        guard let selectedEventId else { return nil }
        return visibleEvents.first { $0.id == selectedEventId }
    }

    /// Local midnight of the focused day.
    public var anchor: Int64
    public var mode: Mode = .week
    public var sidebarVisible = true
    /// Calendars the user switched off (kept across launches).
    public var hiddenCalendars: Set<Int64> {
        didSet { UserDefaults.standard.set(hiddenCalendars.map(String.init), forKey: Self.hiddenKey) }
    }
    /// The "Einladungen & lokal" row: events without a CalDAV collection.
    public var hiddenLocal: Bool {
        didSet { UserDefaults.standard.set(hiddenLocal, forKey: Self.hiddenLocalKey) }
    }

    public var client: (any CalendarCore)?
    public weak var settings: SettingsStore?
    public let toasts: ToastCenter

    private static let hiddenKey = "rabe.calendarHidden"
    private static let hiddenLocalKey = "rabe.calendarHiddenLocal"
    private static let signposter = OSSignposter(subsystem: "de.streil.rabe.native", category: "calendar")

    public init(toasts: ToastCenter, anchor: Int64? = nil) {
        self.toasts = toasts
        self.anchor = anchor ?? Int64(Date().timeIntervalSince1970 * 1000)
        let stored = UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []
        hiddenCalendars = Set(stored.compactMap(Int64.init))
        hiddenLocal = UserDefaults.standard.bool(forKey: Self.hiddenLocalKey)
    }

    // MARK: Derived state

    public var weekStartsOn: CalendarWeekStart { CalendarWeekStart(setting: settings?.calendarWeekStart ?? "monday") }
    public var math: CalendarMath { CalendarMath(weekStartsOn: weekStartsOn) }
    public var meetingReminderMinutes: Int { settings?.meetingNotifyLeadMinutes ?? 10 }
    public var todayStart: Int64 { math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000)) }

    /// Day starts of the visible range (`TimeGrid`/`MonthView` in Tauri).
    public var days: [Int64] {
        switch mode {
        case .day: [math.startOfDay(anchor)]
        case .week: math.weekDays(anchor)
        case .month: math.monthGridDays(anchor)
        }
    }

    /// Half-open epoch range the core is asked for.
    public var range: (start: Int64, end: Int64) {
        let days = days
        guard let first = days.first, let last = days.last else {
            let day = math.startOfDay(anchor)
            return (day, day + CalendarGrid.dayMs)
        }
        return (first, last + CalendarGrid.dayMs)
    }

    /// Events the user can see: hidden calendars and the "invites & local" row
    /// are filtered out.
    public var visibleEvents: [CalendarEvent] {
        events.filter { event in
            if let id = event.calendarId { return !hiddenCalendars.contains(id) }
            return !hiddenLocal
        }
    }

    public var enabledCalendars: [CalendarCollection] { calendars.filter(\.enabled) }

    /// Calendars grouped by account for the sidebar, with the account label.
    public func calendarGroups(accounts: [Account]) -> [(account: Account?, calendars: [CalendarCollection])] {
        var order: [Int64] = []
        var byAccount: [Int64: [CalendarCollection]] = [:]
        for calendar in enabledCalendars {
            if byAccount[calendar.accountId] == nil { order.append(calendar.accountId) }
            byAccount[calendar.accountId, default: []].append(calendar)
        }
        return order.map { id in (accounts.first { $0.id == id }, byAccount[id] ?? []) }
    }

    // MARK: Loading

    public func loadCalendars() async {
        guard let client else { return }
        do { calendars = try await client.listCalendars(accountId: nil) } catch { toasts.error(error) }
    }

    /// Fetches the visible range and rebuilds the grid model.
    public func refresh() async {
        guard let client, !loading else { return }
        loading = true
        defer { loading = false }
        let range = self.range
        do {
            let fetchStarted = Date()
            let rows = try await client.listEvents(startMs: range.start, endMs: range.end)
            lastFetchMilliseconds = Date().timeIntervalSince(fetchStarted) * 1000
            events = rows
            loaded = true
        } catch {
            toasts.error(error)
            return
        }
        rebuildWeekModel()
    }

    /// Recomputes the day/week layout. The signpost interval is the measurement
    /// for the "week switch under 50 ms" requirement; `PerfLog` keeps the number
    /// in the same log file as the host's timings.
    public func rebuildWeekModel() {
        guard mode != .month else { weekModel = nil; return }
        let days = self.days
        let events = self.visibleEvents
        let math = self.math
        let state = Self.signposter.beginInterval("week_switch")
        let started = Date()
        let model = CalendarWeekModel.build(events: events, days: days, math: math)
        Self.signposter.endInterval("week_switch", state)
        weekModel = model
        let ms = Date().timeIntervalSince(started) * 1000
        lastLayoutMilliseconds = ms
        PerfLog.shared.write("calendar_layout ms=\(String(format: "%.2f", ms)) days=\(days.count) events=\(events.count)")
    }

    /// Called by the settings window once the settings object is loaded.
    public func weekStartChanged() {
        guard mode != .month else { return }
        refreshAfterNavigation()
    }

    // MARK: Navigation (Tauri: `-` / `=` / `t` / `d` / `w` / `m`)

    public func go(to day: Int64) {
        anchor = math.startOfDay(day)
        refreshAfterNavigation()
    }

    public func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        refreshAfterNavigation()
    }

    /// One page back/forward: a day, a week or a month.
    public func page(_ delta: Int) {
        switch mode {
        case .day: anchor = math.addDays(anchor, delta)
        case .week: anchor = math.addDays(anchor, delta * 7)
        case .month: anchor = math.addMonths(math.startOfMonth(anchor), delta)
        }
        refreshAfterNavigation()
    }

    public func jumpToToday() {
        anchor = math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000))
        refreshAfterNavigation()
    }

    /// The heading of `CalendarScreen.tsx` ("Juli 2026", "29. Juni – 5. Juli 2026").
    public func heading() -> String {
        let days = self.days
        func format(_ ms: Int64, _ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Format.locale
            formatter.timeZone = .current
            formatter.dateFormat = pattern
            return formatter.string(from: math.date(ms))
        }
        switch mode {
        case .day:
            return format(anchor, "EEEE, d. MMMM yyyy")
        case .month:
            return format(math.startOfMonth(anchor), "LLLL yyyy")
        case .week:
            guard let first = days.first, let last = days.last else { return "" }
            if math.monthIndex(first) == math.monthIndex(last) {
                return format(first, "LLLL yyyy")
            }
            let sameYear = math.calendar.component(.year, from: math.date(first))
                == math.calendar.component(.year, from: math.date(last))
            return "\(format(first, sameYear ? "MMM" : "MMM yyyy")) – \(format(last, "MMM yyyy"))"
        }
    }

    private func refreshAfterNavigation() {
        weekModel = nil
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    // MARK: Writes

    @discardableResult
    public func create(_ args: CreateEventArgs) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let event = try await client.createEvent(args)
            await refresh()
            let invites = event.attendees.count
            toasts.show(invites > 0
                        ? "Termin erstellt, Einladung an \(invites) Teilnehmende wird gesendet"
                        : "Termin zum Kalender hinzugefügt")
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func update(_ args: UpdateEventArgs) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let event = try await client.updateEvent(args)
            await refresh()
            let invited = args.notify && !event.attendees.isEmpty
            toasts.show(invited ? "Termin aktualisiert, Änderung an Teilnehmende gemailt"
                                : "Termin aktualisiert")
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// Drag move/resize: the event's fields with new times.
    ///
    /// K4 aus dem Audit M2: with attendees the core mails an update to everybody
    /// on `notify: true`. A drag is easy to trigger, so the event moves quietly
    /// first and the mail is a separate, explicit click.
    @discardableResult
    public func move(_ event: CalendarEvent, startsAt: Int64, endsAt: Int64) async -> Bool {
        let attendees = event.attendees.count
        let moved = await update(UpdateEventArgs(event, startsAt: startsAt, endsAt: endsAt, notify: attendees == 0))
        guard moved, attendees > 0 else { return moved }
        let args = UpdateEventArgs(event, startsAt: startsAt, endsAt: endsAt, notify: true)
        let text = attendees == 1
            ? "Termin verschoben. Änderung an 1 Teilnehmenden mailen?"
            : "Termin verschoben. Änderung an \(attendees) Teilnehmende mailen?"
        toasts.show(text, actionTitle: "Mailen", duration: 8) { [weak self] in
            guard let self else { return }
            Task { await self.update(args) }
        }
        PerfLog.shared.write("event_notify_ask n=\(attendees)")
        return moved
    }

    /// Deletes an event after the UI confirmed it. For an event we created
    /// without attendees the toast offers undo; the core has no event trash, so
    /// the undo re-creates it (with a new id) instead of restoring rows.
    public func delete(_ event: CalendarEvent) async {
        guard let client, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.deleteEvent(event.id, notify: true)
            events.removeAll { $0.id == event.id }
            rebuildWeekModel()
            let invited = event.isLocal && !event.attendees.isEmpty
            let text = invited
                ? "Termin abgesagt, Absage an \(event.attendees.count) Teilnehmende gemailt"
                : "Termin gelöscht"
            if event.isLocal && event.attendees.isEmpty {
                toasts.show(text, actionTitle: Strings.undo) { [weak self] in
                    guard let self else { return }
                    Task { await self.recreate(event) }
                }
            } else {
                toasts.show(text)
            }
        } catch {
            toasts.error(error)
        }
    }

    /// Undo of a deletion: a fresh local event with the same fields. Nobody is
    /// emailed again (the original had no attendees).
    private func recreate(_ event: CalendarEvent) async {
        guard let client else { return }
        let args = CreateEventArgs(
            accountId: event.accountId, calendarId: event.calendarId, summary: event.summary ?? "",
            description: event.description, location: event.location, joinUrl: event.joinUrl,
            startsAt: event.startsAt, endsAt: CalendarEventRules.eventEnd(event),
            allDay: event.allDay, attendees: [])
        do {
            _ = try await client.createEvent(args)
            await refresh()
            toasts.show("Termin wiederhergestellt")
        } catch {
            toasts.error(error)
        }
    }

    // MARK: Invites in the thread (requirement 4)

    public func loadMessageEvents(_ messageId: Int64) async {
        guard let client, messageEvents[messageId] == nil else { return }
        do { messageEvents[messageId] = try await client.eventsForMessage(messageId) } catch {
            messageEvents[messageId] = []
            toasts.error(error)
        }
    }

    @discardableResult
    public func rsvp(_ event: CalendarEvent, response: RsvpResponse) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let updated = try await client.rsvpEvent(event.id, response: response)
            if let messageId = event.messageId, let rows = messageEvents[messageId] {
                messageEvents[messageId] = rows.map { $0.id == updated.id ? updated : $0 }
            }
            events = events.map { $0.id == updated.id ? updated : $0 }
            rebuildWeekModel()
            let text: String = switch response {
            case .accepted: "Zugesagt, Antwort an die einladende Person gesendet"
            case .tentative: "Mit Vorbehalt zugesagt, Antwort an die einladende Person gesendet"
            case .declined: "Abgesagt, Antwort an die einladende Person gesendet"
            }
            toasts.show(text)
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    // MARK: Calendar settings (requirement 5)

    @discardableResult
    public func setCalendarEnabled(_ id: Int64, enabled: Bool) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.setCalendarEnabled(id, enabled: enabled)
            await loadCalendars()
            await refresh()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func setCalendarColor(_ id: Int64, color: String?) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.setCalendarColor(id, color: color)
            await loadCalendars()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func setDefaultCalendar(_ id: Int64) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.setDefaultCalendar(id)
            await loadCalendars()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func syncNow() async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.calendarSyncNow(accountId: nil)
            toasts.show("Abgleich gestartet")
            await loadCalendars()
            await refresh()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    // MARK: Hiding

    public func toggleCalendar(_ id: Int64) {
        if hiddenCalendars.contains(id) { hiddenCalendars.remove(id) } else { hiddenCalendars.insert(id) }
        rebuildWeekModel()
    }

    public func toggleLocal() {
        hiddenLocal.toggle()
        rebuildWeekModel()
    }
}
