import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.15b: Bearbeitungsrechte (2.2) und die Reihenfolge in der Terminliste (2.3).
@MainActor
final class M215bTests: XCTestCase {

    // MARK: Fixtures

    private func event(_ id: Int64,
                       starts: Int64,
                       ends: Int64? = nil,
                       summary: String = "Termin",
                       organizer: String? = nil,
                       attendees: [EventAttendee] = [],
                       isLocal: Bool = false,
                       calendarId: Int64? = 2,
                       status: String? = "CONFIRMED",
                       allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(
            id: id, accountId: 1, messageId: nil, summary: summary, location: nil,
            organizer: organizer, description: nil, attendees: attendees, joinUrl: nil,
            rsvpStatus: nil, isLocal: isLocal, calendarId: calendarId, rrule: nil,
            startsAt: starts, endsAt: ends, allDay: allDay, status: status, method: nil)
    }

    private func collection(_ id: Int64, readOnly: Bool = false) -> CalendarCollection {
        CalendarCollection(id: id, accountId: 1, url: "https://example.test/cal/\(id)/",
                           displayName: "K\(id)", color: nil, readOnly: readOnly,
                           enabled: true, isDefault: id == 2, lastSyncedAt: nil)
    }

    private let me: Set<String> = ["ich@example.com"]
    private let day: Int64 = 1_800_000_000_000
    private var calendars: [CalendarCollection] { [collection(1), collection(2)] }

    // MARK: 2.2 Adressen

    func testAddressesAreNormalized() {
        XCTAssertEqual(CalendarPermissions.address(" CS@Example.test "), "cs@example.test")
        XCTAssertEqual(CalendarPermissions.address("mailto:CS@example.test"), "cs@example.test")
        XCTAssertEqual(CalendarPermissions.address("Christian <CS@example.test>"), "cs@example.test")
        XCTAssertNil(CalendarPermissions.address(nil))
        XCTAssertNil(CalendarPermissions.address("   "))
        XCTAssertEqual(CalendarPermissions.ownAddresses(["A@x.test", "mailto:B@x.test"]),
                       ["a@x.test", "b@x.test"])
    }

    // MARK: 2.2 Bearbeiten

    /// Der Fall des Nutzers: ein Termin, der schon im iCloud-Kalender lag, hat
    /// keinen Organisator und liegt in einem beschreibbaren Kalender.
    func testPulledEventWithoutOrganizerIsEditable() {
        let pulled = event(10, starts: day)
        XCTAssertTrue(CalendarPermissions.canEdit(pulled, calendars: calendars, ownEmails: me))
    }

    /// Eigene Termine aus Apple Kalender tragen den Nutzer als Organisator.
    func testPulledEventWithOwnOrganizerIsEditable() {
        let own = event(11, starts: day, organizer: "MAILTO:ICH@example.com")
        XCTAssertTrue(CalendarPermissions.canEdit(own, calendars: calendars, ownEmails: me))
    }

    /// Einladungen anderer bleiben Anzeige — aber nicht ohne Antwortmöglichkeit.
    func testEventOrganizedBySomeoneElseIsViewOnlyButAnswerable() {
        let invite = event(12, starts: day, organizer: "chef@example.test",
                           attendees: [EventAttendee(email: "ich@example.com")])
        XCTAssertFalse(CalendarPermissions.canEdit(invite, calendars: calendars, ownEmails: me))
        XCTAssertTrue(CalendarPermissions.canRSVP(invite, ownEmails: me))
    }

    func testReadOnlyCalendarAndUnknownCalendarAreNotEditable() {
        let event = event(13, starts: day)
        XCTAssertFalse(CalendarPermissions.canEdit(
            event, calendars: [collection(2, readOnly: true)], ownEmails: me))
        XCTAssertFalse(CalendarPermissions.canEdit(
            event, calendars: [collection(9)], ownEmails: me))
    }

    func testCancelledEventsAreNotEditableAndNotAnswerable() {
        let cancelled = event(14, starts: day, organizer: "chef@example.test",
                              attendees: [EventAttendee(email: "ich@example.com")],
                              status: "CANCELLED")
        XCTAssertFalse(CalendarPermissions.canEdit(cancelled, calendars: calendars, ownEmails: me))
        XCTAssertFalse(CalendarPermissions.canRSVP(cancelled, ownEmails: me))
    }

    func testLocalOnlyEventStaysEditable() {
        let local = event(15, starts: day, isLocal: true, calendarId: nil)
        XCTAssertTrue(CalendarPermissions.canEdit(local, calendars: calendars, ownEmails: me))
    }

    // MARK: 2.2 Zu-/absagen

    func testRSVPNeedsTheUserAsAttendee() {
        // Kein Teilnehmer: nichts zu beantworten.
        let plain = event(16, starts: day, organizer: "chef@example.test")
        XCTAssertFalse(CalendarPermissions.canRSVP(plain, ownEmails: me))
        // Organisator ist jemand anderes, der Nutzer ist Teilnehmer.
        let invite = event(17, starts: day, organizer: "chef@example.test",
                           attendees: [EventAttendee(email: "ICH@example.com")])
        XCTAssertTrue(CalendarPermissions.canRSVP(invite, ownEmails: me))
        // Selbst organisiert: keine Antwort auf die eigene Einladung.
        let own = event(18, starts: day, organizer: "ich@example.com",
                        attendees: [EventAttendee(email: "ich@example.com")])
        XCTAssertFalse(CalendarPermissions.canRSVP(own, ownEmails: me))
    }

    // MARK: Audit-Restpunkte (https, Zeitumstellung)

    func testCalDAVNeedsHTTPSExceptLocalhost() {
        XCTAssertNil(CalendarStore.connectionProblem("https://caldav.icloud.com"))
        XCTAssertNil(CalendarStore.connectionProblem("http://localhost:28112/"))
        XCTAssertNil(CalendarStore.connectionProblem("http://127.0.0.1:28112/cal/"))
        XCTAssertNotNil(CalendarStore.connectionProblem("http://caldav.icloud.com"))
        XCTAssertNotNil(CalendarStore.connectionProblem("http://192.168.1.9/"))
        XCTAssertNotNil(CalendarStore.connectionProblem("ftp://example.test/"))
        XCTAssertNotNil(CalendarStore.connectionProblem(""))
        XCTAssertNotNil(CalendarStore.connectionProblem("caldav.icloud.com"))
    }

    /// Über die Zeitumstellung (letzter Sonntag im März): 27. bis 29. März sind
    /// nur 47 Stunden, aber drei Kalendertage. Die feste 24-h-Rechnung zählte
    /// „Tag 2 von 3".
    func testDayCountUsesTheCalendarAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        let math = CalendarMath(calendar: calendar, weekStartsOn: .monday)
        func ms(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0) -> Int64 {
            let date = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        let start = ms(2027, 3, 27, 9)
        let end = ms(2027, 3, 29, 9)
        let day = ms(2027, 3, 29)
        let event = self.event(50, starts: start, ends: end, summary: "Über die Umstellung")
        XCTAssertEqual(math.daysBetween(math.startOfDay(start), math.startOfDay(day)), 2)
        XCTAssertEqual(CalendarEventRules.dayCountLabel(event, day: day, math: math), "Tag 3 von 3")
        // Und der 24-h-Weg wäre falsch — der Test wäre sonst inhaltslos.
        let fixed = Int((math.startOfDay(day) - math.startOfDay(start)) / CalendarGrid.dayMs) + 1
        XCTAssertEqual(fixed, 2)
        // Ein einigermaßen normaler Termin bleibt bei einer Angabe.
        let normal = self.event(51, starts: ms(2027, 3, 27, 9), ends: ms(2027, 3, 27, 10))
        XCTAssertNil(CalendarEventRules.dayCountLabel(normal, day: math.startOfDay(start), math: math))
    }

    // MARK: 2.3 Reihenfolge in der Terminliste

    /// Mehrtägige Termine stehen in jeder Tagesgruppe, für `↑`/`↓` zählen sie
    /// einmal — an ihrer ersten Stelle.
    func testAgendaOrderDeduplicatesMultiDayEvents() {
        let today = CalendarMath(weekStartsOn: .monday).startOfDay(day)
        let days = [today, today + CalendarGrid.dayMs, today + 2 * CalendarGrid.dayMs]
        let long = event(20, starts: today + 20 * 3_600_000,
                         ends: today + CalendarGrid.dayMs + 2 * 3_600_000, summary: "Lang")
        let morning = event(21, starts: today + 9 * 3_600_000, summary: "Früh")
        let ordered = AgendaModel.orderedEvents(events: [morning, long], days: days)
        XCTAssertEqual(ordered.map(\.id), [21, 20])
        // Die Zeilen selbst zeigen den langen Termin an beiden Tagen.
        let rows = AgendaModel.rows(events: [morning, long], days: days, openEvent: nil, today: today)
        let eventIds = rows.compactMap { row -> Int64? in
            if case .event(let event) = row { return event.id }
            return nil
        }
        XCTAssertEqual(eventIds, [21, 20, 20])
    }

    /// In der Liste folgt die Auswahl der Anzeige: Tag für Tag, ganztägig
    /// zuerst. Vorher lief sie durch alle geladenen Termine.
    func testListNavigationFollowsTheDisplayedRows() async {
        let math = CalendarMath(weekStartsOn: .monday)
        let today = math.startOfDay(day)
        let events = [
            event(31, starts: today + 14 * 3_600_000, summary: "Nachmittag", isLocal: true, calendarId: nil),
            event(30, starts: today + 9 * 3_600_000, summary: "Vormittag", isLocal: true, calendarId: nil),
            event(32, starts: today + CalendarGrid.dayMs + 8 * 3_600_000,
                  summary: "Morgen", isLocal: true, calendarId: nil),
            // Termin gestern: liegt im 61-Tage-Fenster, aber oben in der Liste.
            event(29, starts: today - CalendarGrid.dayMs + 11 * 3_600_000,
                  summary: "Gestern", isLocal: true, calendarId: nil),
        ]
        let store = CalendarStore(toasts: ToastCenter(), anchor: today)
        store.client = FixedEvents(events: events)
        store.mode = .list
        await store.refresh()

        let expected = AgendaModel.orderedEvents(events: store.visibleEvents, days: store.listDays)
        XCTAssertEqual(store.navigationOrder().map(\.id), expected.map(\.id))
        XCTAssertEqual(expected.map(\.id), [29, 30, 31, 32])

        // Schritt für Schritt: dieselbe Reihenfolge wie die Liste.
        store.selectedEventId = nil
        var walked: [Int64] = []
        for _ in 0..<expected.count {
            store.selectAdjacent(1)
            walked.append(store.selectedEventId ?? -1)
        }
        XCTAssertEqual(walked, expected.map(\.id))
    }

    /// Die Liste öffnet mit ausgewähltem, aber nicht aufgeklapptem Termin; ein
    /// Termin in einem beschreibbaren Kalender geht per `openCard(edit:)` ins
    /// Formular (Regel 2.2 greift bis in den Store).
    func testStoreOpensEditablePulledEventInEditMode() async {
        let math = CalendarMath(weekStartsOn: .monday)
        let today = math.startOfDay(day)
        let pulled = event(40, starts: today + 10 * 3_600_000, calendarId: 2)
        let store = CalendarStore(toasts: ToastCenter(), anchor: today)
        store.client = FixedEvents(events: [pulled])
        store.ownEmails = me
        await store.loadCalendars()
        await store.refresh()

        store.openCard(40, edit: true)
        XCTAssertEqual(store.cardMode, .edit)
    }

    func testStoreKeepsForeignInviteInViewMode() async {
        let math = CalendarMath(weekStartsOn: .monday)
        let today = math.startOfDay(day)
        let invite = event(41, starts: today + 10 * 3_600_000,
                           organizer: "chef@example.test",
                           attendees: [EventAttendee(email: "ich@example.com")], calendarId: 2)
        let store = CalendarStore(toasts: ToastCenter(), anchor: today)
        store.client = FixedEvents(events: [invite])
        store.ownEmails = me
        await store.loadCalendars()
        await store.refresh()

        store.openCard(41, edit: true)
        XCTAssertEqual(store.cardMode, .view)
        XCTAssertTrue(store.canRSVP(invite))
    }
}

// MARK: - Test-Client

private final class FixedEvents: CalendarCore, @unchecked Sendable {
    private let events: [CalendarEvent]
    private let calendars: [CalendarCollection]

    init(events: [CalendarEvent], calendars: [CalendarCollection] = [
        CalendarCollection(id: 1, accountId: 1, url: "https://example.test/cal/1/",
                           displayName: "K1", color: nil, readOnly: false, enabled: true,
                           isDefault: false, lastSyncedAt: nil),
        CalendarCollection(id: 2, accountId: 1, url: "https://example.test/cal/2/",
                           displayName: "K2", color: nil, readOnly: false, enabled: true,
                           isDefault: true, lastSyncedAt: nil),
    ]) {
        self.events = events
        self.calendars = calendars
    }

    func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] {
        events.filter { CalendarEventRules.eventEnd($0) > startMs && $0.startsAt < endMs }
    }

    func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent] { [] }
    func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent {
        throw CoraxClientError.host("not used")
    }
    func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent {
        throw CoraxClientError.host("not used")
    }
    func deleteEvent(_ id: Int64, notify: Bool) async throws { throw CoraxClientError.host("not used") }
    func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent {
        throw CoraxClientError.host("not used")
    }
    func listCalendars(accountId: Int64?) async throws -> [CalendarCollection] { calendars }
    func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws {}
    func setCalendarColor(_ id: Int64, color: String?) async throws {}
    func setDefaultCalendar(_ id: Int64) async throws {}
    func calendarSyncNow(accountId: Int64?) async throws {}
}
