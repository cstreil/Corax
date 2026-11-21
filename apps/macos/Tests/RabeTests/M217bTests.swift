import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.17 Teil 1: Suche in der Terminliste, Nachladen, Chip „Antwort offen",
/// Jahresansicht mit einem Punkt je Kalender und der Sprung aus dem Jahr in die
/// Liste.
@MainActor
final class M217bTests: XCTestCase {

    // MARK: Fixtures

    private let base: Int64 = 1_800_000_000_000

    private var math: CalendarMath { CalendarMath(weekStartsOn: .monday) }

    private func event(_ id: Int64,
                       day: Int64,
                       hour: Int = 9,
                       summary: String = "Termin",
                       location: String? = nil,
                       notes: String? = nil,
                       organizer: String? = nil,
                       attendees: [EventAttendee] = [],
                       calendarId: Int64? = 1,
                       status: String? = "CONFIRMED",
                       rsvp: String? = nil,
                       allDay: Bool = false,
                       minutes: Int64 = 60,
                       ends: Int64? = nil) -> CalendarEvent {
        let start = math.at(day, hour: hour)
        return CalendarEvent(
            id: id, accountId: 1, messageId: nil, summary: summary, location: location,
            organizer: organizer, description: notes, attendees: attendees, joinUrl: nil,
            rsvpStatus: rsvp, isLocal: false, calendarId: calendarId, rrule: nil,
            startsAt: start, endsAt: ends ?? start + minutes * 60_000,
            allDay: allDay, status: status, method: nil)
    }

    private func day(_ offset: Int) -> Int64 {
        math.addDays(math.startOfDay(base), offset)
    }

    private var me: Set<String> { ["cs@example.test"] }

    // MARK: 1 — Suche

    func testSearchMatchesTitlePlaceDescriptionAndAttendees() {
        let title = event(1, day: day(0), summary: "Projekt Nord")
        let place = event(2, day: day(0), summary: "Mittag", location: "Café Nord")
        let notes = event(3, day: day(0), summary: "Jour fixe", notes: "Agenda: Nordsee")
        let person = event(4, day: day(0), summary: "Gespräch",
                           attendees: [EventAttendee(email: "nord@example.test")])
        for hit in [title, place, notes, person] {
            XCTAssertTrue(CalendarSearch.matches(hit, query: "nord"), "Treffer in \(hit.summary ?? "")")
        }
        XCTAssertFalse(CalendarSearch.matches(event(5, day: day(0), summary: "Süd"), query: "nord"))
    }

    func testSearchIgnoresCaseAndUmlautsAndNeedsAllWords() {
        let ev = event(6, day: day(0), summary: "Überprüfung Größe", location: "Raum 2")
        XCTAssertTrue(CalendarSearch.matches(ev, query: "uberprufung"))
        XCTAssertTrue(CalendarSearch.matches(ev, query: "GRÖSSE"))
        XCTAssertTrue(CalendarSearch.matches(ev, query: "raum überprüfung"))
        XCTAssertFalse(CalendarSearch.matches(ev, query: "raum süd"))
    }

    /// Eine leere Anfrage trifft nichts: die Liste zeigt dann den Zeitraum,
    /// nicht „alle Termine".
    func testEmptySearchMatchesNothingAndKeepsOrder() {
        let events = [event(7, day: day(2)), event(8, day: day(1))]
        XCTAssertFalse(CalendarSearch.matches(events[0], query: "   "))
        XCTAssertTrue(CalendarSearch.results(events, query: "  ").isEmpty)
        let hits = CalendarSearch.results(events, query: "Termin")
        XCTAssertEqual(hits.map(\.id), [8, 7], "Treffer nach Start sortiert")
    }

    func testSearchRowsGroupByStartDay() {
        let rows = AgendaModel.searchRows(
            events: [event(9, day: day(1), summary: "A"), event(10, day: day(1), summary: "B"),
                     event(11, day: day(3), summary: "C")],
            openEvent: 10, math: math)
        XCTAssertEqual(rows, [.day(day(1)), .event(event(9, day: day(1), summary: "A")),
                              .event(event(10, day: day(1), summary: "B")), .band(10),
                              .day(day(3)), .event(event(11, day: day(3), summary: "C"))])
    }

    // MARK: 2 — Nachladen in 30-Tage-Schritten

    func testLoadPlanGrowsInThirtyDayStepsAndStopsAtOneYear() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.setMode(.list)
        let anchorDay = math.startOfDay(base)

        let later = store.listLoadPlan(.later)
        XCTAssertTrue(later.allowed)
        XCTAssertEqual(later.forward, CalendarStore.listDaysForward + 30)
        XCTAssertEqual(later.back, CalendarStore.listDaysBack)
        XCTAssertEqual(later.start, math.addDays(anchorDay, CalendarStore.listDaysForward))
        XCTAssertEqual(later.end, math.addDays(anchorDay, CalendarStore.listDaysForward + 30))

        let earlier = store.listLoadPlan(.earlier)
        XCTAssertTrue(earlier.allowed)
        XCTAssertEqual(earlier.back, CalendarStore.listDaysBack + 30)
        XCTAssertEqual(earlier.start, math.addDays(anchorDay, -(CalendarStore.listDaysBack + 30)))
        XCTAssertEqual(earlier.end, math.addDays(anchorDay, -CalendarStore.listDaysBack))
    }

    func testLoadingMoreKeepsTheSelectionAndGrowsTheWindow() async {
        let stub = RowsStub((0..<400).map { index in
            event(100 + Int64(index), day: day(index - 40), summary: "E\(index)")
        })
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.client = stub
        store.setMode(.list)
        await store.refresh()
        store.selectedEventId = 110
        let before = store.events.count

        await store.loadMoreList(.later)
        XCTAssertEqual(store.listWindowForward, CalendarStore.listDaysForward + 30)
        XCTAssertGreaterThan(store.events.count, before, "neuer Block ist dazu gekommen")
        XCTAssertEqual(store.selectedEventId, 110, "die Auswahl bleibt stehen")

        await store.loadMoreList(.earlier)
        XCTAssertEqual(store.listWindowBack, CalendarStore.listDaysBack + 30)
        XCTAssertEqual(store.selectedEventId, 110)
    }

    func testLoadingStopsAfterOneYearOnEachSide() async {
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.client = RowsStub([])
        store.setMode(.list)
        await store.refresh()
        var steps = 0
        while store.listWindowForward < CalendarStore.listMaxForward {
            let before = store.listWindowForward
            await store.loadMoreList(.later)
            XCTAssertGreaterThan(store.listWindowForward, before, "jeder Schritt kommt an")
            steps += 1
            XCTAssertLessThan(steps, 40, "keine Endlos-Schleife")
        }
        XCTAssertEqual(store.listWindowForward, CalendarStore.listMaxForward)
        XCTAssertFalse(store.listLoadPlan(.later).allowed, "am Rand ist Schluss")
        let before = store.listWindowForward
        await store.loadMoreList(.later)
        XCTAssertEqual(store.listWindowForward, before)
    }

    /// Suche und Nachladen teilen sich das Fenster: ein Treffer, der erst mit
    /// dem nachgeladenen Block kommt, erscheint danach.
    func testSearchSeesTheLoadedWindowOnly() async {
        let stub = RowsStub((0..<200).map { index in
            event(500 + Int64(index), day: day(index - 100), summary: "Woche \(index)")
        })
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.client = stub
        store.setMode(.list)
        await store.refresh()
        store.searchText = "Woche 150"
        XCTAssertTrue(store.searchResults.isEmpty, "liegt außerhalb des Grundfensters")
        while store.listWindowForward < CalendarStore.listMaxForward, store.searchResults.isEmpty {
            await store.loadMoreList(.later)
        }
        XCTAssertEqual(store.searchResults.map(\.id), [650], "mit dem neuen Block gefunden")
    }

    func testSearchSkipsHiddenCalendars() async {
        let stub = RowsStub([event(600, day: day(0), summary: "Geheim", calendarId: 7)])
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        // `hiddenCalendars` liegt in den UserDefaults: Ausgangszustand merken,
        // sonst entscheidet ein früherer Lauf über das Ergebnis (flaky).
        let previous = store.hiddenCalendars
        defer { store.hiddenCalendars = previous }
        store.hiddenCalendars = []
        store.client = stub
        store.setMode(.list)
        await store.refresh()
        store.searchText = "geheim"
        XCTAssertEqual(store.searchResults.count, 1)
        store.hiddenCalendars.insert(7)
        XCTAssertTrue(store.searchResults.isEmpty, "ausgeblendeter Kalender")
    }

    // MARK: 3 — Chip „Antwort offen"

    func testNeedsResponseForUnansweredInvitesOnly() {
        let invite = event(20, day: day(0), organizer: "chef@example.test",
                           attendees: [EventAttendee(email: "cs@example.test")])
        XCTAssertTrue(CalendarPermissions.needsResponse(invite, ownEmails: me))
        XCTAssertTrue(CalendarPermissions.needsResponse(
            event(21, day: day(0), organizer: "chef@example.test",
                  attendees: [EventAttendee(email: "cs@example.test", partstat: "NEEDS-ACTION")],
                  rsvp: "NEEDS-ACTION"), ownEmails: me))
        XCTAssertFalse(CalendarPermissions.needsResponse(
            event(22, day: day(0), organizer: "chef@example.test",
                  attendees: [EventAttendee(email: "cs@example.test")], rsvp: "ACCEPTED"),
            ownEmails: me), "geantwortet")
        XCTAssertFalse(CalendarPermissions.needsResponse(
            event(23, day: day(0), organizer: "cs@example.test",
                  attendees: [EventAttendee(email: "cs@example.test")]), ownEmails: me),
                       "eigener Termin")
        XCTAssertFalse(CalendarPermissions.needsResponse(
            event(24, day: day(0), summary: "Fremd"), ownEmails: me), "kein Teilnehmer")
        XCTAssertFalse(CalendarPermissions.needsResponse(
            event(25, day: day(0), organizer: "chef@example.test",
                  attendees: [EventAttendee(email: "cs@example.test")],
                  status: "CANCELLED"), ownEmails: me),
                       "abgesagt")
    }

    func testStoreExposesNeedsResponseWithOwnAddresses() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.ownEmails = me
        XCTAssertTrue(store.needsResponse(event(26, day: day(0), organizer: "chef@example.test",
                                               attendees: [EventAttendee(email: "CS@Example.test")])))
        store.ownEmails = []
        XCTAssertFalse(store.needsResponse(event(26, day: day(0), organizer: "chef@example.test",
                                                 attendees: [EventAttendee(email: "cs@example.test")])))
    }

    // MARK: 4 — Jahresansicht: Punkte je Kalender

    func testYearDotsStandForCalendarsNotEvents() {
        let days = [day(0), day(1), day(2), day(3)]
        let dots = YearDots.byDay(events: [
            event(30, day: day(0), calendarId: 1),
            event(31, day: day(0), hour: 11, calendarId: 1),
            event(32, day: day(0), hour: 12, calendarId: 2),
            event(33, day: day(1), calendarId: 1),
            event(34, day: day(2), calendarId: 1),
            event(35, day: day(2), hour: 10, calendarId: 2),
            event(36, day: day(2), hour: 11, calendarId: 3),
            event(37, day: day(2), hour: 12, calendarId: 4),
            event(38, day: day(3), calendarId: nil),
        ], days: days, math: math)
        XCTAssertEqual(dots[day(0)], [1, 2], "drei Termine, zwei Kalender")
        XCTAssertEqual(dots[day(1)], [1])
        XCTAssertEqual(dots[day(2)]?.count, YearDots.maximum, "höchstens drei Punkte")
        XCTAssertEqual(dots[day(2)], [1, 2, 3])
        XCTAssertEqual(dots[day(3)], [nil], "Einladungen & lokale sind ein eigener Punkt")
    }

    func testYearDotsMarkEveryDayOfAMultiDayEvent() {
        let days = [day(0), day(1), day(2), day(3)]
        let long = event(41, day: day(1), calendarId: 5, ends: math.at(day(3), hour: 12))
        let dots = YearDots.byDay(events: [long], days: days, math: math)
        XCTAssertEqual(dots[day(1)], [5])
        XCTAssertEqual(dots[day(2)], [5])
        XCTAssertEqual(dots[day(3)], [5], "der Endtag zählt mit, solange der Termin ihn berührt")
        XCTAssertNil(dots[day(0)])
    }

    func testYearDotsIgnoreEventsOutsideTheGrid() {
        let dots = YearDots.byDay(events: [event(42, day: day(-20), calendarId: 1)],
                                  days: [day(0), day(1)], math: math)
        XCTAssertTrue(dots.isEmpty)
    }

    // MARK: 5 — Sprung aus dem Jahr in die Liste

    func testDaySelectionRemembersTheListTarget() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.scrollListToDay(day(5))
        XCTAssertEqual(store.pendingListScrollDay, day(5))
        XCTAssertEqual(store.consumePendingListScroll(), day(5))
        XCTAssertNil(store.pendingListScrollDay, "das Ziel wird nur einmal eingelöst")
    }

    /// Wechselt die Ansicht in die Liste, zentriert sie sich auf den gewählten
    /// Tag — auch wenn er außerhalb des bisherigen Fensters liegt.
    func testEnteringTheListCentersOnTheChosenDay() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.scrollListToDay(day(200))
        store.setMode(.list)
        XCTAssertEqual(store.anchor, day(200))
        XCTAssertEqual(store.consumePendingListScroll(), day(200))
    }

    func testLeavingTheListResetsTheLoadedWindow() async {
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.client = RowsStub([])
        store.setMode(.list)
        await store.loadMoreList(.later)
        XCTAssertEqual(store.listWindowForward, CalendarStore.listDaysForward + 30)
        store.setMode(.week)
        XCTAssertEqual(store.listWindowForward, CalendarStore.listDaysForward)
        XCTAssertEqual(store.listWindowBack, CalendarStore.listDaysBack)
    }

    /// Der `/`-Weg: aus dem Raster heraus wechselt die Suche in die Liste.
    func testSlashOpensTheSearchFromAnotherMode() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.client = RowsStub([])
        store.setMode(.week)
        let slash = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "/", charactersIgnoringModifiers: "/",
                                     isARepeat: false, keyCode: 44)!
        XCTAssertTrue(CalendarKeyboard.handle(slash, store: store, openNew: {}, close: {}))
        XCTAssertEqual(store.mode, .list)
        XCTAssertTrue(store.searchOpen)
        store.closeSearch()
        XCTAssertFalse(store.searchOpen)
        XCTAssertTrue(store.searchText.isEmpty)
    }

    // MARK: Kern-Stub

    private final class RowsStub: CalendarCore, @unchecked Sendable {
        var rows: [CalendarEvent]
        init(_ rows: [CalendarEvent]) { self.rows = rows }
        func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] {
            rows.filter { $0.startsAt < endMs && CalendarEventRules.eventEnd($0) > startMs }
        }
        func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent] { [] }
        func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent { rows.first! }
        func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent { rows.first! }
        func deleteEvent(_ id: Int64, notify: Bool) async throws {}
        func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent { rows.first! }
        func listCalendars(accountId: Int64?) async throws -> [CalendarCollection] { [] }
        func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws {}
        func setCalendarColor(_ id: Int64, color: String?) async throws {}
        func setDefaultCalendar(_ id: Int64) async throws {}
        func calendarSyncNow(accountId: Int64?) async throws {}
    }
}
