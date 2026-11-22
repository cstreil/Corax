import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.18h: Jahresansicht.
///
/// Der Nutzer sah zwei Dinge: die Jahresansicht hatte keine Funktion (kein
/// gewählter Tag, Klick tat nichts) und sie sprang beim Aufruf auf heute statt
/// auf dem gewählten Datum zu bleiben.
@MainActor
final class M218hTests: XCTestCase {

    /// Feste Basis: 15. Januar 2027 (Ortszeit 09:00) — bewusst nicht heute,
    /// damit „bleibt auf dem gewählten Datum" von „springt auf heute"
    /// unterscheidbar ist.
    private let base: Int64 = 1_800_000_000_000
    private var math: CalendarMath { CalendarMath(weekStartsOn: .monday) }

    private func day(_ offset: Int) -> Int64 { math.addDays(math.startOfDay(base), offset) }
    private func year(of ms: Int64) -> Int { math.calendar.component(.year, from: math.date(ms)) }

    private func event(_ id: Int64, day: Int64, hour: Int = 9) -> CalendarEvent {
        let start = math.at(day, hour: hour)
        return CalendarEvent(
            id: id, accountId: 1, messageId: nil, summary: "Termin", location: nil,
            organizer: nil, description: nil, attendees: [], joinUrl: nil,
            rsvpStatus: nil, isLocal: false, calendarId: 1, rrule: nil,
            startsAt: start, endsAt: start + 3_600_000,
            allDay: false, status: "CONFIRMED", method: nil)
    }

    // MARK: Eintritt behält das gewählte Datum

    /// Aus der Woche heraus: der Tag des Ankers, nicht heute.
    func testEnteringTheYearFromTheWeekKeepsTheDay() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.mode = .week
        store.setMode(.year)

        XCTAssertEqual(store.mode, .year)
        XCTAssertEqual(store.selectedDay, math.startOfDay(day(0)),
                       "die Jahresansicht übernimmt den gewählten Tag")
        XCTAssertEqual(store.selectedDayOrToday, math.startOfDay(day(0)),
                       "und nicht heute")
        XCTAssertEqual(year(of: store.anchor), 2027)
        XCTAssertTrue(store.yearDays.contains(math.startOfDay(day(0))),
                      "der markierte Tag liegt im gezeigten Jahr")
    }

    /// Aus dem Monat heraus: der angeklickte Tag des Monats.
    func testEnteringTheYearFromTheMonthKeepsTheChosenDay() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.setMode(.month)
        store.selectDay(day(10))
        store.setMode(.year)

        XCTAssertEqual(store.selectedDay, math.startOfDay(day(10)))
        XCTAssertEqual(store.anchor, math.startOfDay(day(10)),
                       "der Anker (und damit das Jahr) folgt dem gewählten Tag")
    }

    /// Aus der Liste heraus: der ausgewählte Termin.
    func testEnteringTheYearFromTheListUsesTheSelectedEvent() async {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.client = RowsStub([event(77, day: day(6))])
        store.mode = .list
        await store.refresh()
        store.selectedEventId = 77

        store.setMode(.year)
        XCTAssertEqual(store.selectedDay, math.startOfDay(day(6)))
    }

    /// Ein `selectedDay` von einer früheren Seite darf nicht gewinnen — sonst
    /// markiert die Jahresansicht einen Tag, an dem niemand mehr steht.
    func testAStaleSelectedDayDoesNotWin() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.mode = .week
        store.selectDay(day(0))
        store.page(4)                       // vier Wochen weiter, Anker bei Tag 28
        let anchorDay = store.anchor

        store.setMode(.year)
        XCTAssertEqual(store.selectedDay, math.startOfDay(anchorDay))
    }

    /// Blättern im Jahr nimmt Monat und Tag mit.
    func testPagingTheYearKeepsMonthAndDay() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.setMode(.year)
        store.page(1)

        XCTAssertEqual(year(of: store.anchor), 2028)
        XCTAssertEqual(store.selectedDay, math.addDays(day(0), 365),
                       "15. Januar 2028 — Tag und Monat bleiben")
        XCTAssertTrue(store.yearDays.contains(store.selectedDay))
    }

    // MARK: Klick und Tastatur öffnen den Tag

    /// Derselbe Weg wie das Tageszahlenfeld im Monat: `selectDay`, `go`,
    /// Tagesansicht. Die Jahresansicht ruft dafür `onOpenDay` des Bildschirms.
    func testOpeningADayFromTheYearLandsInTheDayView() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.setMode(.year)
        let target = day(45)                // 1. März 2027

        store.selectDay(target)
        store.go(to: target)
        store.setMode(.day)

        XCTAssertEqual(store.mode, .day)
        XCTAssertEqual(store.anchor, math.startOfDay(target))
        XCTAssertEqual(store.selectedDay, math.startOfDay(target),
                       "der Rückweg in die Jahresansicht landet wieder dort")
    }

    /// Pfeiltasten bewegen die Markierung, `↵` geht auf.
    func testArrowKeysMoveTheMark() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.setMode(.year)
        let start = store.selectedDay

        store.moveSelectedDay(byDays: 1)
        XCTAssertEqual(store.selectedDay, math.addDays(start, 1))
        XCTAssertTrue(store.yearDays.contains(store.selectedDay))

        store.moveSelectedDay(byDays: 7)
        XCTAssertEqual(store.selectedDay, math.addDays(start, 8))
    }

    /// Gegenprobe zum Sprung: `↵` in der Jahresansicht geht auf den
    /// **markierten** Tag, nicht auf heute.
    func testEnterOpensTheMarkedDay() {
        let store = CalendarStore(toasts: ToastCenter(), anchor: day(0))
        store.setMode(.year)
        store.moveSelectedDay(byDays: 2)
        let marked = store.selectedDay

        store.go(to: store.selectedDayOrToday)
        store.setMode(.day)
        XCTAssertEqual(store.anchor, marked)
        XCTAssertEqual(store.mode, .day)
    }

    // MARK: Prüfstand

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
