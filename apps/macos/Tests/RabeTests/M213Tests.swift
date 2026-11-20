import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.13: Startsperre, Jahresansicht, Terminliste.
final class M213Tests: XCTestCase {

    // MARK: Teil A — Startsperre (§3.1)

    func testHookBuildRefusesAnythingButTheSandbox() {
        XCTAssertTrue(StartGuard.shouldRefuseStart(hooks: true, identifier: ""))
        XCTAssertTrue(StartGuard.shouldRefuseStart(hooks: true, identifier: Instance.native))
        XCTAssertTrue(StartGuard.shouldRefuseStart(hooks: true, identifier: "de.streil.rabe.native.fremd"))
        XCTAssertFalse(StartGuard.shouldRefuseStart(hooks: true, identifier: Instance.sandbox))
    }

    func testReleaseBuildNeverRefuses() {
        XCTAssertFalse(StartGuard.shouldRefuseStart(hooks: false, identifier: ""))
        XCTAssertFalse(StartGuard.shouldRefuseStart(hooks: false, identifier: Instance.native))
        XCTAssertFalse(StartGuard.shouldRefuseStart(hooks: false, identifier: Instance.sandbox))
    }

    // MARK: Teil B — Jahresansicht (§8.3)

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        cal.firstWeekday = 2
        return cal
    }

    func testYearGridHas365DaysAndHandlesLeapYears() {
        let normal = YearGrid.days(year: 2026, calendar: calendar)
        XCTAssertEqual(normal.count, 365)
        let leap = YearGrid.days(year: 2028, calendar: calendar)
        XCTAssertEqual(leap.count, 366)
        // Erster und letzter Tag sind der 1.1. und der 31.12.
        let cal = calendar
        XCTAssertEqual(cal.component(.month, from: Date(timeIntervalSince1970: Double(normal.first!) / 1000)), 1)
        XCTAssertEqual(cal.component(.day, from: Date(timeIntervalSince1970: Double(normal.first!) / 1000)), 1)
        XCTAssertEqual(cal.component(.month, from: Date(timeIntervalSince1970: Double(normal.last!) / 1000)), 12)
        XCTAssertEqual(cal.component(.day, from: Date(timeIntervalSince1970: Double(normal.last!) / 1000)), 31)
        // Lückenlos und kalendarisch aufeinanderfolgend. An den Umstellungstagen
        // ist der Abstand 23 bzw. 25 Stunden (82,8 / 90 Mio. ms) — deshalb
        // rechnet das Raster mit `Calendar`, nicht mit festen 24 h.
        for (a, b) in zip(normal, normal.dropFirst()) {
            let step = cal.dateComponents([.day], from: Date(timeIntervalSince1970: Double(a) / 1000),
                                          to: Date(timeIntervalSince1970: Double(b) / 1000)).day
            XCTAssertEqual(step, 1, "Folgetag muss der nächste Kalendertag sein")
            let dayStart = cal.startOfDay(for: Date(timeIntervalSince1970: Double(b) / 1000))
            XCTAssertEqual(Double(b), dayStart.timeIntervalSince1970 * 1000, accuracy: 0.5)
        }
    }

    func testYearGridHasTwelveMonths() {
        let months = YearGrid.months(year: 2026, calendar: calendar)
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(calendar.component(.month, from: Date(timeIntervalSince1970: Double(months[10]) / 1000)), 11)
    }

    func testMonthGridFollowsTheWeekStart() {
        var monday = CalendarMath(weekStartsOn: .monday)
        monday.calendar = calendar
        var sunday = CalendarMath(weekStartsOn: .sunday)
        sunday.calendar = calendar
        let november = YearGrid.months(year: 2026, calendar: calendar)[10]
        let firstMonday = monday.monthGridDays(november).first!
        let firstSunday = sunday.monthGridDays(november).first!
        XCTAssertEqual(calendar.component(.weekday, from: Date(timeIntervalSince1970: Double(firstMonday) / 1000)), 2)
        XCTAssertEqual(calendar.component(.weekday, from: Date(timeIntervalSince1970: Double(firstSunday) / 1000)), 1)
    }

    // MARK: Teil B — Terminliste (§8.4)

    private func event(_ id: Int64, day: Int64, hour: Int, summary: String,
                       allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, accountId: 1, messageId: nil, summary: summary, location: nil,
                      organizer: nil, description: nil, attendees: [], joinUrl: nil,
                      rsvpStatus: nil, isLocal: true, calendarId: nil, rrule: nil,
                      startsAt: day + Int64(hour) * 3_600_000,
                      endsAt: day + Int64(hour + 1) * 3_600_000,
                      allDay: allDay, status: "CONFIRMED", method: nil)
    }

    func testAgendaDropsEmptyDaysKeepsTodayAndPutsTheBandBelowItsEvent() {
        var math = CalendarMath(weekStartsOn: .monday)
        math.calendar = calendar
        let today = math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000))
        let tomorrow = math.addDays(today, 1)
        let dayAfter = math.addDays(today, 2)
        let events = [event(1, day: today, hour: 9, summary: "Früh"),
                      event(2, day: today, hour: 15, summary: "Spät"),
                      event(3, day: dayAfter, hour: 10, summary: "Übermorgen")]
        let rows = AgendaModel.rows(events: events, days: [today, tomorrow, dayAfter],
                                    openEvent: 2, today: today)
        // Heute, zwei Termine, Band unter dem zweiten, dann der leere Tag
        // entfällt, übermorgen kommt wieder.
        guard case .day(today) = rows[0] else { return XCTFail("erste Zeile ist kein Tageskopf") }
        guard case .event(let first) = rows[1] else { return XCTFail() }
        XCTAssertEqual(first.id, 1)
        guard case .event(let second) = rows[2] else { return XCTFail() }
        XCTAssertEqual(second.id, 2)
        guard case .band(2) = rows[3] else { return XCTFail("Band fehlt unter seinem Termin") }
        guard case .day(dayAfter) = rows[4] else { return XCTFail("Tag ohne Termin muss entfallen") }
        XCTAssertEqual(rows.count, 6)
    }

    func testAgendaShowsEmptyTodaySoTheAnchorStaysVisible() {
        var math = CalendarMath(weekStartsOn: .monday)
        math.calendar = calendar
        let today = math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000))
        let rows = AgendaModel.rows(events: [], days: [math.addDays(today, -1), today],
                                    openEvent: nil, today: today)
        XCTAssertEqual(rows, [.day(today), .emptyDay(today)])
    }

    func testAgendaOrdersAllDayFirstThenByStart() {
        var math = CalendarMath(weekStartsOn: .monday)
        math.calendar = calendar
        let today = math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000))
        let allDay = event(9, day: today, hour: 0, summary: "Ganztägig", allDay: true)
        let rows = AgendaModel.rows(events: [event(2, day: today, hour: 15, summary: "Spät"),
                                             event(1, day: today, hour: 8, summary: "Früh"),
                                             allDay],
                                    days: [today], openEvent: nil, today: today)
        let ids = rows.compactMap { row -> Int64? in
            if case .event(let event) = row { return event.id }
            return nil
        }
        XCTAssertEqual(ids, [9, 1, 2])
    }

    // MARK: Teil C — Kalenderkürzel (§3.8, §3.10)

    /// Jede Einzeltaste, die `ShortcutMap` dem Kalender gibt, muss der
    /// Tastenempfänger auch auswerten — sonst steht in der Kürzelhilfe etwas,
    /// das nicht funktioniert.
    @MainActor
    func testEveryCalendarSingleKeyInTheMapIsHandled() {
        for shortcut in ShortcutMap.all where shortcut.context == .calendar {
            for single in shortcut.singles {
                let token = single.replacingOccurrences(of: "⇧", with: "")
                let character = token.lowercased()
                XCTAssertTrue(CalendarKeyboard.handledCharacters.contains(character)
                              || CalendarKeyboard.keyOnlyTokens.contains(single),
                              "Kürzelhilfe nennt „\(single)“ (\(shortcut.action)), der Kalender wertet sie nicht aus")
            }
        }
    }

    /// Und keine Einzeltaste darf im Kalender zweimal vergeben sein.
    func testCalendarSingleKeysAreNotDoubleBooked() {
        var seen: [String: String] = [:]
        for shortcut in ShortcutMap.all where shortcut.context == .calendar {
            for single in shortcut.singles {
                if let other = seen[single] {
                    XCTFail("„\(single)“ doppelt belegt: \(other) und \(shortcut.action)")
                }
                seen[single] = shortcut.action
            }
        }
    }

    /// Die Tabelle aus `BRIEFING-M2.14` §6 muss im Kalender vollständig sein:
    /// `D W M Y L`, `T`, `-`/`+`, `B`, `Tab`/`⇧Tab`, `↵`, `⌘E`, `O`, `⌫`.
    func testCalendarMapCoversTheAgreedKeys() {
        let singles = Set(ShortcutMap.all.filter { $0.context == .calendar }.flatMap { $0.singles })
        for key in ["D", "W", "M", "Y", "L", "T", "-", "+", "B", "Tab", "⇧Tab"] {
            XCTAssertTrue(singles.contains(key), "Einzeltaste \(key) fehlt in der Tabelle")
        }
        let combos = Set(ShortcutMap.all.filter { $0.context == .calendar }.flatMap { $0.combos })
        for key in ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘T", "⌘←", "⌘→", "⌘N", "↵", "⌘E", "⌘O", "⌫"] {
            XCTAssertTrue(combos.contains(key), "Kombi \(key) fehlt in der Tabelle")
        }
    }

    /// M2.13 §3.8: `Tab`/`⇧Tab` wählen den nächsten/vorigen Termin.
    @MainActor
    func testTabMovesTheSelectionBothWays() async {
        var math = CalendarMath(weekStartsOn: .monday)
        math.calendar = calendar
        let today = math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000))
        let weekStart = math.startOfWeek(today)
        let store = CalendarStore(toasts: ToastCenter(), anchor: weekStart)
        store.client = RowsStub([event(1, day: weekStart, hour: 9, summary: "Erster"),
                                 event(2, day: weekStart, hour: 11, summary: "Zweiter")])
        store.mode = .week
        await store.refresh()
        store.selectedEventId = 2
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                   context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                   isARepeat: false, keyCode: 48)!
        let backTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                       context: nil, characters: "\u{19}",
                                       charactersIgnoringModifiers: "\u{19}",
                                       isARepeat: false, keyCode: 48)!
        XCTAssertTrue(CalendarKeyboard.handle(backTab, store: store, openNew: {}, close: {}))
        XCTAssertEqual(store.selectedEventId, 1, "⇧Tab geht zum vorigen Termin")
        XCTAssertTrue(CalendarKeyboard.handle(tab, store: store, openNew: {}, close: {}))
        XCTAssertEqual(store.selectedEventId, 2, "Tab geht zum nächsten Termin")
    }

    /// Kleiner Kern-Stub für die Liste: liefert die Termine der Spanne.
    private final class RowsStub: CalendarCore, @unchecked Sendable {
        var rows: [CalendarEvent]
        var calendars: [CalendarCollection] = []
        init(_ rows: [CalendarEvent]) { self.rows = rows }
        func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] {
            rows.filter { $0.startsAt < endMs && CalendarEventRules.eventEnd($0) > startMs }
        }
        func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent] { [] }
        func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent { rows.first! }
        func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent { rows.first! }
        func deleteEvent(_ id: Int64, notify: Bool) async throws {}
        func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent { rows.first! }
        func listCalendars(accountId: Int64?) async throws -> [CalendarCollection] { calendars }
        func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws {}
        func setCalendarColor(_ id: Int64, color: String?) async throws {}
        func setDefaultCalendar(_ id: Int64) async throws {}
        func calendarSyncNow(accountId: Int64?) async throws {}
    }
}
