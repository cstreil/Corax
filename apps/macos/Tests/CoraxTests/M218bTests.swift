import AppKit
import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.18 Teil 1: Fokus, Bearbeitungsrecht, Endzeit, `Esc`, Serien als einzelne
/// Einträge, Geltungsbereich-Dialog und der schnellere Abgleich.
@MainActor
final class M218bTests: XCTestCase {

    private let base: Int64 = 1_800_000_000_000
    private var math: CalendarMath { CalendarMath(weekStartsOn: .monday) }

    private func day(_ offset: Int) -> Int64 {
        math.addDays(math.startOfDay(base), offset)
    }

    private func event(_ id: Int64,
                       day dayStart: Int64,
                       hour: Int = 9,
                       minutes: Int64 = 60,
                       summary: String = "Termin",
                       calendarId: Int64? = 1,
                       rrule: String? = nil,
                       organizer: String? = nil,
                       isLocal: Bool = false,
                       status: String? = "CONFIRMED") -> CalendarEvent {
        let start = math.at(dayStart, hour: hour)
        return CalendarEvent(
            id: id, accountId: 1, messageId: nil, summary: summary, location: nil,
            organizer: organizer, description: nil, attendees: [], joinUrl: nil,
            rsvpStatus: nil, isLocal: isLocal, calendarId: calendarId, rrule: rrule,
            startsAt: start, endsAt: start + minutes * 60_000, allDay: false,
            status: status, method: nil)
    }

    private func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    // MARK: §3 — Endzeit folgt der Startzeit

    func testStartChangeKeepsDuration() {
        let start = math.at(day(0), hour: 9)
        let end = math.at(day(0), hour: 10)
        let moved = math.at(day(0), hour: 14)
        XCTAssertEqual(EventTimes.end(afterStartChangeFrom: start, end: end, to: moved),
                       math.at(day(0), hour: 15))
    }

    func testStartChangeOnZeroLengthUsesMinimum() {
        let start = math.at(day(0), hour: 9)
        let moved = math.at(day(1), hour: 8)
        XCTAssertEqual(EventTimes.end(afterStartChangeFrom: start, end: start, to: moved),
                       moved + EventTimes.minimumMs)
    }

    func testEndNeverBeforeStart() {
        let start = math.at(day(0), hour: 9)
        XCTAssertEqual(EventTimes.clampedEnd(start: start, end: start - 3_600_000),
                       start + EventTimes.minimumMs)
        XCTAssertEqual(EventTimes.clampedEnd(start: start, end: start + 3_600_000),
                       start + 3_600_000)
    }

    // MARK: §5 — jede Wiederholung ein eigener Eintrag

    func testSeriesOccurrencesGetOwnIdsAndKeepTheCoreId() {
        let master = event(42, day: day(0), rrule: "FREQ=WEEKLY")
        var second = master
        second = CalendarEvent(id: 42, accountId: 1, messageId: nil, summary: "Termin", location: nil,
                               organizer: nil, description: nil, attendees: [], joinUrl: nil,
                               rsvpStatus: nil, isLocal: false, calendarId: 1, rrule: "FREQ=WEEKLY",
                               startsAt: master.startsAt + 7 * CalendarGrid.dayMs,
                               endsAt: (master.endsAt ?? master.startsAt) + 7 * CalendarGrid.dayMs,
                               allDay: false, status: "CONFIRMED", method: nil)
        let a = master.taggedAsSeriesOccurrence()
        let b = second.taggedAsSeriesOccurrence()
        XCTAssertNotEqual(a.id, b.id, "Wiederholungen brauchen verschiedene Kennungen")
        XCTAssertEqual(a.eventId, 42)
        XCTAssertEqual(b.eventId, 42)
        XCTAssertEqual(a.occurrenceStart, a.startsAt)
        XCTAssertEqual(CalendarOccurrenceID.eventId(of: a.id), 42)
        XCTAssertEqual(CalendarOccurrenceID.start(of: b.id), b.startsAt)
        // Zweimal taggen ändert nichts (idempotent).
        XCTAssertEqual(a.taggedAsSeriesOccurrence().id, a.id)
    }

    func testNavigationStepsThroughEveryOccurrence() async {
        let master = event(42, day: day(0), rrule: "FREQ=DAILY")
        let rows = (0..<3).map { index -> CalendarEvent in
            let start = master.startsAt + Int64(index) * CalendarGrid.dayMs
            return CalendarEvent(id: 42, accountId: 1, messageId: nil, summary: "Serie",
                                 location: nil, organizer: nil, description: nil, attendees: [],
                                 joinUrl: nil, rsvpStatus: nil, isLocal: false, calendarId: 1,
                                 rrule: "FREQ=DAILY", startsAt: start,
                                 endsAt: start + 3_600_000, allDay: false,
                                 status: "CONFIRMED", method: nil)
        }
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.client = RowsStub(rows)
        store.mode = .week
        await store.refresh()
        XCTAssertEqual(store.visibleEvents.count, 3)
        XCTAssertEqual(store.navigationOrder().count, 3, "keine Wiederholung wird übersprungen")
        let ids = store.visibleEvents.map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
        store.selectedEventId = ids[0]
        store.selectAdjacent(1)
        XCTAssertEqual(store.selectedEventId, ids[1])
        store.selectAdjacent(1)
        XCTAssertEqual(store.selectedEventId, ids[2])
    }

    func testOpenCardAcceptsTheCoreId() async {
        let master = event(42, day: day(0), rrule: "FREQ=DAILY")
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.client = RowsStub([master])
        store.mode = .week
        await store.refresh()
        store.openCard(42)
        XCTAssertEqual(store.openEventId, store.visibleEvents.first?.id)
        XCTAssertEqual(store.openEvent?.summary, "Termin")
    }

    func testCardShowsSeriesAndOpensTheOccurrenceDate() async {
        let master = event(42, day: day(0), rrule: "FREQ=WEEKLY")
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.client = RowsStub([master])
        store.mode = .week
        await store.refresh()
        let occurrence = try! XCTUnwrap(store.visibleEvents.first)
        XCTAssertTrue(occurrence.isSeriesOccurrence)
        XCTAssertEqual(occurrence.occurrenceStart, occurrence.startsAt)
    }

    // MARK: §6 — „Alle" ändert die Uhrzeit, nicht das Datum

    func testAllScopeKeepsTheSeriesDateAndTakesTheChosenTime() {
        let masterStart = math.at(day(0), hour: 9)
        let chosenStart = math.at(day(14), hour: 11)
        let chosenEnd = math.at(day(14), hour: 12)
        let times = SeriesShift.master(start: masterStart, chosenStart: chosenStart,
                                       chosenEnd: chosenEnd, math: math)
        XCTAssertEqual(times.start, math.at(day(0), hour: 11), "Datum bleibt beim Master")
        XCTAssertEqual(times.end, math.at(day(0), hour: 12), "Dauer kommt aus dem Formular")
    }

    func testSavingAnOccurrenceSendsTheMasterTimesToTheCore() async throws {
        let master = event(42, day: day(0), rrule: "FREQ=WEEKLY")
        let secondStart = master.startsAt + 14 * CalendarGrid.dayMs
        let second = CalendarEvent(id: 42, accountId: 1, messageId: nil, summary: "Serie",
                                   location: nil, organizer: nil, description: nil, attendees: [],
                                   joinUrl: nil, rsvpStatus: nil, isLocal: false, calendarId: 1,
                                   rrule: "FREQ=WEEKLY", startsAt: secondStart,
                                   endsAt: secondStart + 3_600_000, allDay: false,
                                   status: "CONFIRMED", method: nil)
        let core = RecordingStub([master, second], [CalendarCollection(
            id: 1, accountId: 1, url: "https://example.test/cal/", displayName: "cs",
            color: nil, readOnly: false, enabled: true, isDefault: true, lastSyncedAt: nil)])
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(14))
        store.client = core
        store.mode = .day
        await store.refresh()
        let occurrence = try XCTUnwrap(store.visibleEvents.first)
        XCTAssertTrue(occurrence.isSeriesOccurrence)

        let chosenStart = math.at(day(14), hour: 11)
        let chosenEnd = math.at(day(14), hour: 12)
        let ok = await store.updateSeriesOccurrence(occurrence, args: UpdateEventArgs(
            eventId: occurrence.eventId, summary: "Serie bearbeitet",
            startsAt: chosenStart, endsAt: chosenEnd, notify: false))
        XCTAssertTrue(ok)
        let sent = try XCTUnwrap(core.updates.last)
        XCTAssertEqual(sent.eventId, 42)
        XCTAssertEqual(sent.startsAt, math.at(day(0), hour: 11))
        XCTAssertEqual(sent.endsAt, math.at(day(0), hour: 12))
        XCTAssertEqual(sent.summary, "Serie bearbeitet")
    }

    // MARK: §4 — Esc führt nie zur Mail

    func testEscapeClearsTheSelectionAndStaysInTheCalendar() async {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.client = RowsStub([event(1, day: day(0))])
        store.mode = .week
        await store.refresh()
        store.selectedEventId = store.visibleEvents.first?.id
        var leftCalendar = false
        XCTAssertTrue(CalendarKeyboard.handle(key(53, "\u{1b}"), store: store,
                                              openNew: {}, close: { leftCalendar = true }))
        XCTAssertNil(store.selectedEventId)
        XCTAssertFalse(leftCalendar, "Esc darf den Kalender nicht verlassen")
        // Zweites Esc tut nichts mehr und bleibt im Kalender.
        XCTAssertTrue(CalendarKeyboard.handle(key(53, "\u{1b}"), store: store,
                                              openNew: {}, close: { leftCalendar = true }))
        XCTAssertFalse(leftCalendar)
    }

    func testEscapeWithoutSelectionDoesNotLeaveTheCalendar() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.client = RowsStub([])
        var leftCalendar = false
        XCTAssertTrue(CalendarKeyboard.handle(key(53, "\u{1b}"), store: store,
                                              openNew: {}, close: { leftCalendar = true }))
        XCTAssertFalse(leftCalendar)
    }

    func testDigitOneNoLongerLeavesTheCalendar() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.client = RowsStub([])
        var leftCalendar = false
        _ = CalendarKeyboard.handle(key(18, "1"), store: store,
                                    openNew: {}, close: { leftCalendar = true })
        XCTAssertFalse(leftCalendar)
    }

    // MARK: §2 — App-Regel spiegelt den Kern

    /// Dieselbe Tabelle wie `calendar::edit_blocked_reason` im Kern (dort
    /// `edit_rule_follows_organizer_and_calendar`), damit App und Kern nicht
    /// auseinanderlaufen.
    func testEditRuleMatchesTheCoreTable() {
        let me: Set<String> = ["cs@example.test"]
        let writable = CalendarCollection(id: 1, accountId: 1, url: "u", displayName: "cs",
                                          color: nil, readOnly: false, enabled: true,
                                          isDefault: true, lastSyncedAt: nil)
        let locked = CalendarCollection(id: 2, accountId: 1, url: "u2", displayName: "ro",
                                        color: nil, readOnly: true, enabled: true,
                                        isDefault: false, lastSyncedAt: nil)
        let calendars = [writable, locked]

        // Gezogen, ohne Organisator, beschreibbarer Kalender: bearbeitbar.
        XCTAssertNil(CalendarPermissions.blockReason(event(1, day: day(0)), calendars: calendars, ownEmails: me))
        // Eigener Organisator (MAILTO, andere Schreibweise): bearbeitbar.
        XCTAssertNil(CalendarPermissions.blockReason(
            event(2, day: day(0), organizer: "MAILTO:CS@example.test"), calendars: calendars, ownEmails: me))
        // Fremder Organisator: nur ansehen.
        XCTAssertEqual(CalendarPermissions.blockReason(
            event(3, day: day(0), organizer: "boss@example.test"), calendars: calendars, ownEmails: me),
            "only the organizer can edit this event")
        // Schreibgeschützter Kalender.
        XCTAssertEqual(CalendarPermissions.blockReason(
            event(4, day: day(0), calendarId: 2), calendars: calendars, ownEmails: me),
            "calendar is read-only")
        // Ohne Kalender nur lokale Termine.
        XCTAssertNil(CalendarPermissions.blockReason(
            event(5, day: day(0), calendarId: nil, isLocal: true), calendars: calendars, ownEmails: me))
        XCTAssertEqual(CalendarPermissions.blockReason(
            event(6, day: day(0), calendarId: nil), calendars: calendars, ownEmails: me),
            "event has no writable calendar")
        // Abgesagt ist abgesagt.
        XCTAssertEqual(CalendarPermissions.blockReason(
            event(7, day: day(0), status: "CANCELLED"), calendars: calendars, ownEmails: me),
            "event is cancelled")
        // Unbekannter Kalender: lokale Termine bleiben bearbeitbar (wie im Kern),
        // fremde brauchen einen bekannten Schreibschutz.
        XCTAssertNil(CalendarPermissions.blockReason(
            event(8, day: day(0), calendarId: 99, isLocal: true), calendars: calendars, ownEmails: me))
        XCTAssertEqual(CalendarPermissions.blockReason(
            event(9, day: day(0), calendarId: 99), calendars: calendars, ownEmails: me),
            "event has no writable calendar")
    }

    // MARK: Kern-Stub

    private final class RowsStub: CalendarCore, @unchecked Sendable {
        var rows: [CalendarEvent]
        var calendars: [CalendarCollection]
        init(_ rows: [CalendarEvent], _ calendars: [CalendarCollection] = []) {
            self.rows = rows
            self.calendars = calendars
        }
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

    private final class RecordingStub: CalendarCore, @unchecked Sendable {
        var rows: [CalendarEvent]
        var calendars: [CalendarCollection]
        var updates: [UpdateEventArgs] = []
        var deleted: [Int64] = []
        var syncRequests = 0
        init(_ rows: [CalendarEvent], _ calendars: [CalendarCollection]) {
            self.rows = rows
            self.calendars = calendars
        }
        func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] {
            rows.filter { $0.startsAt < endMs && CalendarEventRules.eventEnd($0) > startMs }
        }
        func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent] { [] }
        func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent { rows.first! }
        func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent {
            updates.append(args)
            return rows.first!
        }
        func deleteEvent(_ id: Int64, notify: Bool) async throws { deleted.append(id) }
        func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent { rows.first! }
        func listCalendars(accountId: Int64?) async throws -> [CalendarCollection] { calendars }
        func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws {}
        func setCalendarColor(_ id: Int64, color: String?) async throws {}
        func setDefaultCalendar(_ id: Int64) async throws {}
        func calendarSyncNow(accountId: Int64?) async throws { syncRequests += 1 }
    }
}
