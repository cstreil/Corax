import AppKit
import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.12 — Kalender alltagstauglich: Freigabe von `connect_calendar`, die
/// Argumentform, die Navigationsreihenfolge (am Rand blättert `↑`/`↓`) und die
/// Esc-Kette Bearbeiten → Anzeige → Karte zu.
@MainActor
final class M212Tests: XCTestCase {
    private func math() -> CalendarMath {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return CalendarMath(calendar: calendar, weekStartsOn: .monday)
    }

    private func event(_ id: Int64, startsAt: Int64, minutes: Int = 30, title: String? = nil,
                       allDay: Bool = false, calendarId: Int64? = nil) -> CalendarEvent {
        CalendarEvent(id: id, accountId: 1, messageId: nil, summary: title ?? "T\(id)", location: nil,
                      organizer: nil, description: nil, attendees: [], joinUrl: nil,
                      rsvpStatus: nil, isLocal: true, calendarId: calendarId, rrule: nil,
                      startsAt: startsAt, endsAt: startsAt + Int64(minutes) * 60_000,
                      allDay: allDay, status: "CONFIRMED", method: nil)
    }

    private func collection(_ id: Int64, lastSyncedAt: Int64?) -> CalendarCollection {
        CalendarCollection(id: id, accountId: 1, url: "https://example.test/\(id)",
                           displayName: "K\(id)", color: nil, readOnly: false, enabled: true,
                           isDefault: id == 1, lastSyncedAt: lastSyncedAt)
    }

    private func day() -> Int64 {
        math().stamp(math().calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))!)
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    /// Ein Kern, der die Termine der angefragten Spanne liefert — so kann auch
    /// das Blättern über den Wochenrand geprüft werden.
    private final class Rows: CalendarCore, @unchecked Sendable {
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

    /// Merkt sich die Argumente von `connect_calendar` und kann scheitern.
    private actor Connector: CalendarCore {
        var seen: ConnectCalendarArgs?
        let failure: CoraxClientError?
        let found: [CalendarCollection]
        init(failure: CoraxClientError? = nil, found: [CalendarCollection] = []) {
            self.failure = failure
            self.found = found
        }
        func lastArgs() -> ConnectCalendarArgs? { seen }
        func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] { [] }
        func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent] { [] }
        func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent {
            throw CoraxClientError.host("not used")
        }
        func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent {
            throw CoraxClientError.host("not used")
        }
        func deleteEvent(_ id: Int64, notify: Bool) async throws {}
        func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent {
            throw CoraxClientError.host("not used")
        }
        func listCalendars(accountId: Int64?) async throws -> [CalendarCollection] { found }
        func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws {}
        func setCalendarColor(_ id: Int64, color: String?) async throws {}
        func setDefaultCalendar(_ id: Int64) async throws {}
        func calendarSyncNow(accountId: Int64?) async throws {}
        func connectCalendar(_ args: ConnectCalendarArgs) async throws -> [CalendarCollection] {
            seen = args
            if let failure { throw failure }
            return found
        }
    }

    private func store(_ events: [CalendarEvent], anchor: Int64? = nil) async -> CalendarStore {
        // Der Anker liegt auf dem ersten Termin, damit die Woche in M2.12-Tests
        // unabhängig vom heutigen Datum dieselbe ist.
        let store = CalendarStore(toasts: ToastCenter(), anchor: anchor ?? events.first?.startsAt ?? day())
        store.client = Rows(events)
        await store.refresh()
        return store
    }

    // MARK: Freigabe und Argumente (Anforderung 1)

    func testConnectCalendarIsReleasedAsWriting() {
        XCTAssertTrue(CommandPolicy.writing.contains("connect_calendar"))
        XCTAssertFalse(CommandPolicy.reading.contains("connect_calendar"))
        XCTAssertEqual(CommandPolicy.decision(for: "connect_calendar", writesAllowed: true), .allowed)
        XCTAssertEqual(CommandPolicy.decision(for: "connect_calendar"), .writesDisabled)
        XCTAssertEqual(CommandPolicy.decision(for: "connect_calendar", sandbox: true), .allowed)
    }

    func testConnectArgumentsReachTheCoreUnchanged() async throws {
        let connector = Connector(found: [collection(1, lastSyncedAt: nil)])
        let store = CalendarStore(toasts: ToastCenter())
        store.client = connector
        let ok = await store.connectCalendar(accountId: 7, server: "https://caldav.icloud.com",
                                             username: "cs@example.test",
                                             password: "abcd-efgh-ijkl-mnop")
        XCTAssertTrue(ok)
        let seen = await connector.lastArgs()
        XCTAssertEqual(seen, ConnectCalendarArgs(accountId: 7, kind: "generic",
                                                 url: "https://caldav.icloud.com",
                                                 username: "cs@example.test",
                                                 password: "abcd-efgh-ijkl-mnop"))
        // Die Erfolgsmeldung nennt die gefundenen Kalender.
        XCTAssertEqual(store.connectNotice?.contains("1 Kalender"), true)
        XCTAssertNil(store.connectError)
    }

    func testTheWirePayloadUsesTheCoreFieldNames() throws {
        let args = ConnectCalendarArgs(accountId: 3, kind: "generic",
                                       url: "https://caldav.example.test",
                                       username: "u@example.test", password: "secret")
        let data = try JSONEncoder().encode(WithArgs(args: args))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inner = try XCTUnwrap(object["args"] as? [String: Any])
        XCTAssertEqual(inner["accountId"] as? Int64, 3)
        XCTAssertEqual(inner["kind"] as? String, "generic")
        XCTAssertEqual(inner["url"] as? String, "https://caldav.example.test")
        XCTAssertEqual(inner["username"] as? String, "u@example.test")
        XCTAssertEqual(inner["password"] as? String, "secret")
        // `nil`-Felder fallen weg, der Kern hat `#[serde(default)]`.
        let minimal = try JSONEncoder().encode(WithArgs(args: ConnectCalendarArgs(accountId: 3)))
        let minimalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: minimal) as? [String: Any])
        let minimalInner = try XCTUnwrap(minimalObject["args"] as? [String: Any])
        XCTAssertNil(minimalInner["url"])
        XCTAssertNil(minimalInner["password"])
    }

    func testAFailedConnectShowsPlainTextAndKeepsNoSuccess() async {
        let connector = Connector(failure: .core(code: "auth", message: "401"))
        let store = CalendarStore(toasts: ToastCenter())
        store.client = connector
        let ok = await store.connectCalendar(accountId: 1, server: "https://127.0.0.1:9",
                                             username: "u@example.test", password: "wrong")
        XCTAssertFalse(ok)
        XCTAssertNil(store.connectNotice)
        // Klartext aus der CalDAV-Meldung, kein roher JSON-Code.
        XCTAssertEqual(store.connectError,
                       "Anmeldung fehlgeschlagen – E-Mail-Adresse und App-Passwort prüfen.")
        store.clearConnectFeedback()
        XCTAssertNil(store.connectError)
    }

    func testConnectErrorTextsCoverTheCommonServerAnswers() {
        XCTAssertEqual(CalendarStore.connectErrorMessage(.core(code: "needs_reauth", message: "")),
                       "Anmeldung fehlgeschlagen – E-Mail-Adresse und App-Passwort prüfen.")
        XCTAssertEqual(CalendarStore.connectErrorMessage(.core(code: "offline", message: "")),
                       "Du bist offline oder der Server ist nicht erreichbar.")
        XCTAssertTrue(CalendarStore.connectErrorMessage(
            .core(code: "caldav", message: "PROPFIND https://x: HTTP 401")).contains("HTTP 401"))
        XCTAssertTrue(CalendarStore.connectErrorMessage(
            .core(code: "caldav", message: "request: error trying to connect: Connection refused"))
            .contains("nicht erreichbar"))
        // Der Kern verschluckt Netzfehler: toter Port, falsche Adresse und
        // „kein CalDAV“ enden alle gleich. Dann darf die App nicht behaupten,
        // der Server habe einen Fehler gemeldet.
        XCTAssertTrue(CalendarStore.connectErrorMessage(
            .core(code: "caldav", message: "caldav error: no current-user-principal found"))
            .contains("kein Kalender gefunden"))
    }

    // MARK: Statuszeile (Anforderung 2)

    func testSyncStatusTellsFreshStaleAndMissingCalendars() {
        let now: Int64 = 1_800_000_000_000
        XCTAssertEqual(CalendarStore.syncStatus(lastSyncedAt: nil, hasCalendars: false, now: now),
                       .noCalendars)
        XCTAssertEqual(CalendarStore.syncStatus(lastSyncedAt: nil, hasCalendars: true, now: now),
                       .neverSynced)
        XCTAssertEqual(CalendarStore.syncStatus(lastSyncedAt: now - 60_000, hasCalendars: true, now: now),
                       .current(now - 60_000))
        // Drei verpasste Fünf-Minuten-Zyklen gelten als veraltet.
        XCTAssertEqual(CalendarStore.syncStatus(lastSyncedAt: now - 16 * 60_000,
                                                hasCalendars: true, now: now),
                       .stale(now - 16 * 60_000))
        XCTAssertEqual(CalendarStore.syncStatus(lastSyncedAt: now - 14 * 60_000,
                                                hasCalendars: true, now: now),
                       .current(now - 14 * 60_000))
    }

    func testTheStoreUsesTheNewestCalendarForItsStatus() async {
        let store = CalendarStore(toasts: ToastCenter())
        let rows = Rows([])
        rows.calendars = [collection(1, lastSyncedAt: 100), collection(2, lastSyncedAt: 900)]
        store.client = rows
        await store.loadCalendars()
        XCTAssertEqual(store.lastSyncAt, 900)
        XCTAssertEqual(store.syncStatus, .stale(900), "900 ms nach 1970 ist Jahrzehnte alt")
    }

    // MARK: Navigation und Rand (Anforderung 5)

    func testNavigationWalksTheOrderAndPagesAtTheEdge() async {
        let day = day()
        // Leere Spanne: es gibt nichts zu wählen, also blättert der Schritt.
        let empty = CalendarStore(toasts: ToastCenter(), anchor: day)
        empty.client = Rows([])
        empty.mode = .week
        await empty.refresh()
        XCTAssertEqual(empty.navigationStep(1), .page(1), "ohne sichtbare Termine wird geblättert")

        let store = CalendarStore(toasts: ToastCenter(), anchor: day)
        store.client = Rows([event(1, startsAt: day + 9 * 3_600_000),
                             event(2, startsAt: day + 11 * 3_600_000)])
        store.mode = .week
        await store.refresh()
        XCTAssertEqual(store.navigationOrder().map(\.id), [1, 2])
        XCTAssertEqual(store.navigationStep(1), .select(1), "ohne Auswahl beginnt es beim ersten")
        store.selectedEventId = 2
        XCTAssertEqual(store.navigationStep(1), .page(1), "am Ende blättert ↓ weiter")
        XCTAssertEqual(store.navigationStep(-1), .select(1))
        store.selectedEventId = 1
        XCTAssertEqual(store.navigationStep(-1), .page(-1), "am Anfang blättert ↑ zurück")
    }

    func testNavigatePagesAndSelectsTheFirstEventOfTheNewWeek() async {
        let math = math()
        let weekStart = math.startOfWeek(day())
        let thisWeek = event(1, startsAt: weekStart + 9 * 3_600_000)
        let nextWeek = event(2, startsAt: math.addDays(weekStart, 7) + 10 * 3_600_000)
        let store = CalendarStore(toasts: ToastCenter(), anchor: weekStart)
        let rows = Rows([thisWeek, nextWeek])
        store.client = rows
        store.mode = .week
        await store.refresh()
        store.selectedEventId = thisWeek.id
        XCTAssertEqual(store.navigationStep(1), .page(1))
        store.navigate(1)
        XCTAssertEqual(store.anchor, math.addDays(weekStart, 7), "die Ansicht ist eine Woche weiter")
        for _ in 0..<40 where store.selectedEventId != nextWeek.id {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store.selectedEventId, nextWeek.id, "der erste Termin der neuen Seite wird gewählt")
    }

    /// M2.13: `←`/`→` wählen keinen Termin mehr (Tabelle M2.14 §6); blättern
    /// tun `⌘←`/`⌘→`.
    func testPlainArrowsNoLongerMoveTheSelectionButCommandArrowsPage() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000),
                                 event(2, startsAt: day + 11 * 3_600_000)])
        store.mode = .week
        store.selectedEventId = 1
        XCTAssertFalse(CalendarKeyboard.handle(key(124), store: store, openNew: {}, close: {}))
        XCTAssertEqual(store.selectedEventId, 1, "→ wählt nicht mehr")
        XCTAssertFalse(CalendarKeyboard.handle(key(123), store: store, openNew: {}, close: {}))
        XCTAssertEqual(store.selectedEventId, 1)

        let weekStart = math().startOfWeek(day)
        store.anchor = weekStart
        XCTAssertTrue(CalendarKeyboard.handle(key(124, "", flags: .command),
                                              store: store, openNew: {}, close: {}))
        XCTAssertEqual(store.anchor, math().addDays(weekStart, 7), "⌘→ blättert eine Woche")
        XCTAssertTrue(CalendarKeyboard.handle(key(123, "", flags: .command),
                                              store: store, openNew: {}, close: {}))
        XCTAssertEqual(store.anchor, weekStart, "⌘← blättert zurück")
    }

    /// M2.13: die Leertaste öffnet die Karte nicht mehr (M2.14 gibt sie dem
    /// Blättern im Thread). `↵` öffnet weiterhin.
    func testSpaceNoLongerOpensTheCardButReturnDoes() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.selectedEventId = 1
        var opened: Int64?
        let handle: (NSEvent) -> Bool = { event in
            CalendarKeyboard.handle(event, store: store, openNew: {},
                                    openCard: { opened = $0.id }, close: {})
        }
        XCTAssertFalse(handle(key(49, " ")), "die Leertaste gehört nicht mehr dem Kalender")
        XCTAssertNil(opened)
        XCTAssertTrue(handle(key(36)))
        XCTAssertEqual(opened, 1, "↵ öffnet die Karte")
    }

    func testCommandDigitsSwitchTheView() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.mode = .week
        for (code, mode) in [(UInt16(18), CalendarStore.Mode.day),
                             (UInt16(19), CalendarStore.Mode.week),
                             (UInt16(20), CalendarStore.Mode.month)] {
            let handled = CalendarKeyboard.handle(key(code, "1", flags: [.command]),
                                                  store: store, openNew: {}, close: {})
            XCTAssertTrue(handled)
            XCTAssertEqual(store.mode, mode)
        }
        // Mit offener Karte bleiben die Zahlen dem Menü überlassen.
        store.openCard(1)
        let handled = CalendarKeyboard.handle(key(18, "1", flags: [.command]),
                                              store: store, openNew: {}, close: {})
        XCTAssertFalse(handled)
    }

    // MARK: Esc-Kette und Klick ins Leere (Anforderung 6)

    func testEscapeWalksFromEditToViewToCalendar() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        XCTAssertEqual(store.escapeAction(), .leaveCalendar, "ohne Karte geht Esc zurück zur Liste")
        store.openCard(1)
        XCTAssertEqual(store.escapeAction(), .closeCard)
        store.editOpenCard()
        XCTAssertEqual(store.escapeAction(), .cancelEdit)
        // Der Monitor führt die Entscheidung aus; der Zustand nach zwei Esc.
        store.cancelEdit()
        XCTAssertEqual(store.escapeAction(), .closeCard)
        store.closeCard()
        XCTAssertEqual(store.escapeAction(), .leaveCalendar)
        XCTAssertFalse(store.cardIsOpen)
    }

    func testAClickOnEmptySpaceClosesTheCardOnlyWhenOneIsOpen() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        XCTAssertFalse(store.closeCardOnEmptySpace(), "ohne Karte entsteht ein neuer Termin")
        store.openCard(1)
        XCTAssertTrue(store.closeCardOnEmptySpace())
        XCTAssertFalse(store.cardIsOpen)
        XCTAssertEqual(store.selectedEventId, 1, "die Auswahl bleibt für ↑/↓")
    }
}
