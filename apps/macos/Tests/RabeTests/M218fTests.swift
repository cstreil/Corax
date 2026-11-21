import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.18f: Terminliste und Navigation.
///
/// Der Nutzer sah drei Dinge: die Auswahl klebte am zweiten Eintrag, „Heute"
/// tat in der Liste nichts, und ein Ansichtswechsel sprang auf heute statt auf
/// das gewählte Datum zu bleiben.
@MainActor
final class M218fTests: XCTestCase {

    private let base: Int64 = 1_800_000_000_000
    private var math: CalendarMath { CalendarMath(weekStartsOn: .monday) }

    private func day(_ offset: Int) -> Int64 { math.addDays(math.startOfDay(base), offset) }

    private func event(_ id: Int64, day: Int64, hour: Int = 9, minutes: Int64 = 60,
                       summary: String = "Termin", allDay: Bool = false,
                       ends: Int64? = nil) -> CalendarEvent {
        let start = allDay ? math.startOfDay(day) : math.at(day, hour: hour)
        return CalendarEvent(
            id: id, accountId: 1, messageId: nil, summary: summary, location: nil,
            organizer: nil, description: nil, attendees: [], joinUrl: nil,
            rsvpStatus: nil, isLocal: false, calendarId: 1, rrule: nil,
            startsAt: start, endsAt: ends ?? start + minutes * 60_000,
            allDay: allDay, status: "CONFIRMED", method: nil)
    }

    private func store(anchor: Int64) -> CalendarStore {
        CalendarStore(toasts: ToastCenter(), anchor: anchor)
    }

    // MARK: Ansichtswechsel behält das Datum

    func testSwitchingFromMonthToDayKeepsTheAnchor() {
        let store = store(anchor: day(0))
        store.setMode(.month)
        store.page(1)                     // einen Monat weiter
        let chosen = store.anchor
        XCTAssertNotEqual(chosen, math.startOfDay(base), "der Anker ist wirklich woanders")

        store.setMode(.day)
        XCTAssertEqual(store.anchor, chosen, "Tag übernimmt den gewählten Monatstag")
    }

    func testSwitchingFromYearToDayUsesTheChosenDay() {
        let store = store(anchor: day(0))
        store.setMode(.year)
        store.selectDay(day(40))
        store.setMode(.day)
        XCTAssertEqual(store.math.startOfDay(store.anchor), math.startOfDay(day(40)))
    }

    func testSwitchingFromListToDayUsesTheSelectedEvent() async {
        let store = store(anchor: day(0))
        store.client = RowsStub([event(77, day: day(6))])
        store.setMode(.list)          // die Liste lädt ±30 Tage, die Woche nur 7
        await store.refresh()
        store.selectedEventId = 77

        store.setMode(.day)
        XCTAssertEqual(store.math.startOfDay(store.anchor), math.startOfDay(day(6)))
    }

    // MARK: „Heute" in der Liste

    func testTodayInTheListSelectsTheFirstEventFromToday() async {
        let today = Date().timeIntervalSince1970
        let todayStart = math.startOfDay(Int64(today * 1000))
        let store = store(anchor: todayStart)
        store.client = RowsStub([
            event(1, day: math.addDays(todayStart, -1)),
            event(2, day: todayStart, hour: 8),
            event(3, day: math.addDays(todayStart, 1), hour: 9),
        ])
        store.setMode(.list)
        await store.refresh()
        store.selectedEventId = nil

        store.jumpToToday()
        XCTAssertEqual(store.anchor, store.todayStart)
        XCTAssertEqual(store.selectedEventId, 2, "erster Termin ab heute")
    }

    func testFirstEventFromADayIncludesOneAlreadyRunning() async {
        let store = store(anchor: day(0))
        let running = event(10, day: day(-1), allDay: true, ends: day(2))
        let later = event(11, day: day(0), hour: 14)
        store.client = RowsStub([later, running])
        store.setMode(.list)
        await store.refresh()
        store.selectedEventId = nil

        store.selectFirstEvent(from: day(0))
        XCTAssertEqual(store.selectedEventId, 10, "mehrtägiger Termin läuft noch")
    }

    // MARK: Zeilen-Nachführung

    func testRevealOnlyScrollsAtTheEdge() {
        // Die Regel liegt in `ListReveal`; hier nur die Zusicherung, dass die
        // Liste einen sichtbaren Eintrag nicht mehr an die Oberkante zieht.
        let visibleTop: CGFloat = 300
        let visibleHeight: CGFloat = 600
        // Zeile liegt mitten im Fenster → kein Scroll.
        let inside = ListReveal.revealTop(rowTop: 400, aboveTop: 400, cardBottom: 446,
                                          belowH: 46, visibleMinY: visibleTop,
                                          visibleHeight: visibleHeight)
        XCTAssertNil(inside)
    }

    // MARK: Stub

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
