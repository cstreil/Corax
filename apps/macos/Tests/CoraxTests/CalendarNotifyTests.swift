import XCTest
@testable import Corax
@testable import CoraxKit

/// K4 aus dem Audit M2: Ein Termin mit Teilnehmenden mailt beim Ziehen nicht
/// mehr sofort eine Änderung an alle, sondern fragt einmal (Toast mit „Mailen").
@MainActor
final class CalendarNotifyTests: XCTestCase {
    /// Records what the store sends; `listEvents` feeds `refresh()`.
    actor RecordingCalendar: CalendarCore {
        private(set) var updates: [UpdateEventArgs] = []
        let event: CalendarEvent

        init(event: CalendarEvent) { self.event = event }

        func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] { [event] }
        func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent] { [] }
        func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent { event }
        func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent {
            updates.append(args)
            return event
        }
        func deleteEvent(_ id: Int64, notify: Bool) async throws {}
        func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent { event }
        func listCalendars(accountId: Int64?) async throws -> [CalendarCollection] { [] }
        func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws {}
        func setCalendarColor(_ id: Int64, color: String?) async throws {}
        func setDefaultCalendar(_ id: Int64) async throws {}
        func calendarSyncNow(accountId: Int64?) async throws {}
    }

    private func event(attendees: [EventAttendee]) -> CalendarEvent {
        CalendarEvent(id: 7, accountId: 1, messageId: nil, summary: "Planung", location: nil,
                      organizer: "ich@example.test", description: nil, attendees: attendees,
                      joinUrl: nil, rsvpStatus: nil, isLocal: true, calendarId: nil, rrule: nil,
                      startsAt: 1_800_000_000_000, endsAt: 1_800_003_600_000, allDay: false,
                      status: "CONFIRMED", method: nil)
    }

    func testDraggingAnEventWithAttendeesAsksBeforeMailing() async {
        let calendarEvent = event(attendees: [EventAttendee(email: "ana@example.test"),
                                              EventAttendee(email: "bo@example.test")])
        let core = RecordingCalendar(event: calendarEvent)
        let toasts = ToastCenter()
        let store = CalendarStore(toasts: toasts)
        store.client = core

        await store.move(calendarEvent, startsAt: 1_800_007_200_000, endsAt: 1_800_010_800_000)

        var updates = await core.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.notify, false, "das Ziehen mailt nicht sofort")
        XCTAssertEqual(toasts.current?.actionTitle, "Mailen")
        XCTAssertEqual(toasts.current?.text, "Termin verschoben. Änderung an 2 Teilnehmende mailen?")

        XCTAssertTrue(toasts.runAction())
        try? await Task.sleep(for: .milliseconds(80))
        updates = await core.updates
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.last?.notify, true, "erst der Klick mailt an die Teilnehmenden")
    }

    func testDraggingAnEventWithoutAttendeesMailsNothing() async {
        let calendarEvent = event(attendees: [])
        let core = RecordingCalendar(event: calendarEvent)
        let toasts = ToastCenter()
        let store = CalendarStore(toasts: toasts)
        store.client = core

        await store.move(calendarEvent, startsAt: 1_800_007_200_000, endsAt: 1_800_010_800_000)

        let updates = await core.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.notify, true, "ohne Teilnehmende bleibt es beim bisherigen Aufruf")
        XCTAssertNil(toasts.current?.actionTitle, "ohne Teilnehmende keine Rückfrage")
    }
}
