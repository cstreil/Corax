import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.18g: `⌘E`, der Stift und der Doppelklick öffnen die Karte über
/// `CalendarStore.openCard(id, edit: true)`. Dort fiel ein abgewiesenes
/// Bearbeiten still auf die Anzeige zurück — weder Zeile im Log noch Grund.
/// Jetzt steht derselbe Grund im Log wie in `editOpenCard`.
@MainActor
final class M218gTests: XCTestCase {

    private let base: Int64 = 1_800_000_000_000
    private let ownPrincipal = "https://p01-caldav.example/123456/principal/"
    private let me: Set<String> = ["cs@example.test"]

    private func calendar(readOnly: Bool = false) -> CalendarCollection {
        CalendarCollection(id: 1, accountId: 1, url: "https://p01.example/cal/1/",
                           displayName: "Kalender", color: nil, readOnly: readOnly,
                           enabled: true, isDefault: true, lastSyncedAt: nil,
                           principalUrl: ownPrincipal)
    }

    private func event(_ id: Int64, organizer: String?, local: Bool = false,
                       status: String = "CONFIRMED") -> CalendarEvent {
        CalendarEvent(id: id, accountId: 1, messageId: nil, summary: "Termin",
                      location: nil, organizer: organizer, description: nil,
                      attendees: [], joinUrl: nil, rsvpStatus: nil, isLocal: local,
                      calendarId: 1, rrule: nil, startsAt: base + 3_600_000,
                      endsAt: base + 7_200_000, allDay: false, status: status,
                      method: nil)
    }

    private func store(_ rows: [CalendarEvent],
                       _ calendars: [CalendarCollection]) async -> CalendarStore {
        let store = CalendarStore(toasts: ToastCenter(), anchor: base)
        store.client = RowsStub(rows, calendars)
        store.ownEmails = me
        store.mode = .day
        await store.loadCalendars()
        await store.refresh()
        return store
    }

    /// Ein fremder Organisator: `⌘E` bleibt in der Anzeige — und sagt warum.
    func testCommandEOnAForeignEventFallsToViewAndLogsTheReason() async {
        let dir = NSTemporaryDirectory() + "m218g-log-\(UUID().uuidString)"
        PerfLog.shared.configure(dataDirectory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let store = await store([event(42, organizer: "boss@example.test")], [calendar()])
        store.openCard(42, edit: true)

        XCTAssertEqual(store.cardMode, .view, "gesperrtes Bearbeiten fällt auf die Anzeige zurück")
        let opened = store.openEventId
        XCTAssertNotNil(opened, "die Karte ist trotzdem offen")

        let log = (try? String(contentsOfFile: dir + "/logs/corax.log",
                               encoding: .utf8)) ?? ""
        XCTAssertTrue(
            log.contains("calendar_card_edit_blocked id=\(opened!) "
                         + "reason=only the organizer can edit this event"), log)
        XCTAssertTrue(log.contains("calendar_card_open id=\(opened!) mode=view"), log)
    }

    /// Ein lesender Kalender ist der zweite Abweisungsgrund — eigene Worte.
    func testCommandEInAReadOnlyCalendarLogsTheCalendarReason() async {
        let dir = NSTemporaryDirectory() + "m218g-log-\(UUID().uuidString)"
        PerfLog.shared.configure(dataDirectory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let store = await store([event(43, organizer: nil)], [calendar(readOnly: true)])
        store.openCard(43, edit: true)

        XCTAssertEqual(store.cardMode, .view)
        let log = (try? String(contentsOfFile: dir + "/logs/corax.log",
                               encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("calendar_card_edit_blocked id=43 reason=calendar is read-only"),
                      log)
    }

    /// Gegenprobe: ein eigener Termin im beschreibbaren Kalender öffnet den
    /// Editor, ohne Abweisungszeile.
    func testAnOwnEventStillOpensInEdit() async {
        let store = await store([event(44, organizer: nil)], [calendar()])
        store.openCard(44, edit: true)
        XCTAssertEqual(store.cardMode, .edit)
        XCTAssertEqual(store.openEventId, store.visibleEvents.first?.id)
    }

    /// Und ohne `edit:` bleibt alles wie bisher: `openCard(id)` ist die Anzeige,
    /// auch bei einem gesperrten Termin.
    func testAPlainOpenStaysInViewWithoutABlockedLine() async {
        let store = await store([event(45, organizer: "boss@example.test")], [calendar()])
        store.openCard(45)
        XCTAssertEqual(store.cardMode, .view)
    }

    // MARK: Prüfstand

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
}
