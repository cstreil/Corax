import AppKit
import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.9 Stufe C: die Terminkarte im Raster.
/// - `selectedEventId` und `openEventId` getrennt (Entwurf §7.5),
/// - `↑`/`↓` über die sichtbaren Termine,
/// - Anzeigen und Bearbeiten in derselben Fläche, `Esc` schrittweise (§7.4).
@MainActor
final class M29CalendarCardTests: XCTestCase {
    private func math() -> CalendarMath {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return CalendarMath(calendar: calendar, weekStartsOn: .monday)
    }

    private func event(_ id: Int64, startsAt: Int64, minutes: Int = 30, title: String? = nil,
                       allDay: Bool = false, local: Bool = true,
                       attendees: [EventAttendee] = []) -> CalendarEvent {
        CalendarEvent(id: id, accountId: 1, messageId: nil, summary: title ?? "T\(id)", location: nil,
                      organizer: nil, description: nil, attendees: attendees, joinUrl: nil,
                      rsvpStatus: nil, isLocal: local, calendarId: nil, rrule: nil,
                      startsAt: startsAt, endsAt: startsAt + Int64(minutes) * 60_000,
                      allDay: allDay, status: "CONFIRMED", method: nil)
    }

    /// Ein Kern, der genau diese Termine zurückgibt.
    private final class Rows: CalendarCore {
        let rows: [CalendarEvent]
        init(_ rows: [CalendarEvent]) { self.rows = rows }
        func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] { rows }
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

    private func store(_ events: [CalendarEvent]) async -> CalendarStore {
        let store = CalendarStore(toasts: ToastCenter())
        store.client = Rows(events)
        await store.refresh()
        return store
    }

    private func day() -> Int64 {
        math().stamp(math().calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))!)
    }

    private func key(_ code: UInt16, _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    // MARK: Auswahl und Karte

    func testSelectionAndCardAreSeparate() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000),
                                 event(2, startsAt: day + 11 * 3_600_000)])
        store.openCard(1)
        XCTAssertEqual(store.openEventId, 1)
        XCTAssertEqual(store.selectedEventId, 1, "das Öffnen wählt den Termin mit")
        store.closeCard()
        XCTAssertNil(store.openEventId)
        XCTAssertEqual(store.selectedEventId, 1, "die Auswahl bleibt, damit ↑/↓ weiterlaufen")
    }

    func testACardOnlyOpensForAnEventInTheVisibleRange() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.openCard(999)
        XCTAssertNil(store.openEventId)
    }

    func testAnInviteOpensInViewModeEvenWhenEditWasAsked() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000, local: false)])
        store.openCard(1, edit: true)
        XCTAssertEqual(store.openEventId, 1)
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.view, "fremde Termine lassen sich hier nicht bearbeiten")
    }

    // MARK: ↑ / ↓

    func testArrowKeysWalkTheVisibleEventsInStartOrder() async {
        let day = day()
        let store = await store([
            event(3, startsAt: day + 14 * 3_600_000),
            event(1, startsAt: day + 9 * 3_600_000),
            event(2, startsAt: day + 11 * 3_600_000),
            event(4, startsAt: day, allDay: true),
        ])
        XCTAssertEqual(store.navigationOrder().map(\.id), [4, 1, 2, 3],
                       "ganztägig zuerst, dann nach Start")
        store.selectAdjacent(1)
        XCTAssertEqual(store.selectedEventId, 4)
        store.selectAdjacent(1)
        XCTAssertEqual(store.selectedEventId, 1)
        store.selectAdjacent(1)
        XCTAssertEqual(store.selectedEventId, 2)
        store.selectAdjacent(-1)
        XCTAssertEqual(store.selectedEventId, 1)
        store.selectAdjacent(-5)
        XCTAssertEqual(store.selectedEventId, 4, "am Anfang bleibt die Auswahl stehen")
    }

    func testTheOpenCardFollowsTheArrowKeys() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000),
                                 event(2, startsAt: day + 11 * 3_600_000)])
        store.openCard(1)
        _ = CalendarKeyboard.handle(key(125), store: store, openNew: {}, close: {})  // ↓
        XCTAssertEqual(store.openEventId, 2, "die Karte wandert mit")
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.view)
    }

    func testSameStartSortsByTitle() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000, title: "Zebra"),
                                 event(2, startsAt: day + 9 * 3_600_000, title: "Anfang")])
        XCTAssertEqual(store.navigationOrder().map(\.id), [2, 1])
    }

    // MARK: Bearbeiten in derselben Fläche

    /// M2.18c: `↵` klappt den Termin auf und wieder zu, wie in der Mailliste.
    /// Das Bearbeiten liegt auf `⌘E`, dem Stift und dem Doppelklick.
    func testReturnTogglesTheCardAndCommandEOpensTheEditor() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.selectedEventId = 1
        let handle: (NSEvent) -> Bool = { event in
            CalendarKeyboard.handle(event, store: store, openNew: {},
                                    openCard: { store.openCard($0.id) },
                                    editCard: { store.editOpenCard() },
                                    editEvent: { store.openCard($0.id, edit: true) },
                                    closeCard: { store.closeCard() }, close: {})
        }
        // 1. ↵: Karte auf, aber nur zum Ansehen.
        XCTAssertTrue(handle(key(36, "\r")))
        XCTAssertEqual(store.openEventId, 1)
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.view)
        // 2. ↵: Karte wieder zu — die Auswahl bleibt für das nächste ↵.
        XCTAssertTrue(handle(key(36, "\r")))
        XCTAssertNil(store.openEventId)
        XCTAssertEqual(store.selectedEventId, 1)
        // ⌘E: derselbe Termin, jetzt im Formular.
        let commandE = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [.command],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: 0, context: nil, characters: "e",
                                        charactersIgnoringModifiers: "e", isARepeat: false,
                                        keyCode: 14)!
        XCTAssertTrue(handle(commandE))
        XCTAssertEqual(store.openEventId, 1)
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.edit)
        // ⌘E bei offener Anzeige schaltet dieselbe Karte ins Formular.
        store.cancelEdit()
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.view)
        XCTAssertTrue(handle(commandE))
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.edit)
    }

    /// Genau der gemeldete Fall: ein Termin ohne Bearbeitungsrecht. Das zweite
    /// `↵` lief vorher ins Leere, jetzt klappt es die Karte zu.
    func testReturnAlsoClosesACardThatCannotBeEdited() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000, local: false)])
        store.selectedEventId = 1
        let handle: (NSEvent) -> Bool = { event in
            CalendarKeyboard.handle(event, store: store, openNew: {},
                                    openCard: { store.openCard($0.id) },
                                    editCard: { store.editOpenCard() },
                                    closeCard: { store.closeCard() }, close: {})
        }
        XCTAssertTrue(handle(key(36, "\r")))
        XCTAssertEqual(store.openEventId, 1)
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.view)
        XCTAssertTrue(handle(key(36, "\r")))
        XCTAssertNil(store.openEventId, "das zweite ↵ klappt auch einen fremden Termin zu")
    }

    /// Esc bleibt die schrittweise Kette: Bearbeiten → Anzeige → Karte zu.
    func testEscapeGoesBackStepWiseFromTheEditor() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.openCard(1, edit: true)
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.edit)
        store.cancelEdit()
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.view)
        XCTAssertEqual(store.openEventId, 1)
        store.closeCard()
        XCTAssertNil(store.openEventId)
    }

    func testANewDraftLeavesNothingBehindOnEscape() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.beginDraft(CalendarEventDraft(startsAt: day + 12 * 3_600_000,
                                           endsAt: day + 13 * 3_600_000, title: "Neu"))
        XCTAssertTrue(store.cardIsOpen)
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.edit)
        XCTAssertNil(store.openEventId, "der neue Termin hat noch keine Kennung")
        store.cancelEdit()
        XCTAssertFalse(store.cardIsOpen, "der gestrichelte Platzhalter verschwindet wieder")
        XCTAssertNil(store.draft)
    }

    func testSavingANewEventClosesTheCard() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.beginDraft(CalendarEventDraft(startsAt: day + 12 * 3_600_000,
                                           endsAt: day + 13 * 3_600_000))
        store.draftSaved()
        XCTAssertFalse(store.cardIsOpen)
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.view)
    }

    func testSavingAnEditKeepsTheCardOpenInViewMode() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.openCard(1, edit: true)
        store.savedOpenCard()
        XCTAssertEqual(store.openEventId, 1)
        XCTAssertEqual(store.cardMode, CalendarStore.CardMode.view)
    }

    func testCommandReturnAsksTheCardToSave() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.openCard(1, edit: true)
        let before = store.saveRequest
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: [.command],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: 0, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false,
                                     keyCode: 36)!
        var asked = 0
        let handled = CalendarKeyboard.handle(event, store: store, openNew: {},
                                              saveCard: { asked += 1; store.requestSave() }, close: {})
        XCTAssertTrue(handled)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(store.saveRequest, before + 1)
    }

    // MARK: Löschen und Meeting

    func testDeleteAsksBeforeItDeletes() async {
        let day = day()
        let store = await store([event(1, startsAt: day + 9 * 3_600_000)])
        store.openCard(1)
        var asked: Int64?
        _ = CalendarKeyboard.handle(key(51, "\u{7f}"), store: store, openNew: {},
                                    deleteSelected: { asked = $0.id }, close: {})
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(store.openEventId, 1, "erst nach der Bestätigung verschwindet die Karte")
    }

    func testOJoinsTheMeetingOfTheOpenEvent() async {
        let day = day()
        let start = day + 9 * 3_600_000
        let meeting = CalendarEvent(id: 1, accountId: 1, messageId: nil, summary: "T1", location: nil,
                                    organizer: nil, description: nil, attendees: [],
                                    joinUrl: "https://example.com/meet", rsvpStatus: nil,
                                    isLocal: true, calendarId: nil, rrule: nil, startsAt: start,
                                    endsAt: start + 30 * 60_000, allDay: false,
                                    status: "CONFIRMED", method: nil)
        let store = await store([meeting])
        store.openCard(1)
        var joined: String?
        _ = CalendarKeyboard.handle(key(31, "o"), store: store, openNew: {},
                                    joinMeeting: { joined = $0.joinUrl }, close: {})
        XCTAssertEqual(joined, "https://example.com/meet")
    }

    // MARK: Erwartung an die Karte im Monat

    func testTheBandSitsUnderTheWeekOfTheOpenEvent() async {
        // Dieselbe Regel, die `CalendarMonthView.bandWeekIndex` anwendet.
        let math = self.math()
        let anchor = math.stamp(math.calendar.date(from: DateComponents(year: 2026, month: 7, day: 15))!)
        let store = await store([])
        store.anchor = anchor
        let cells = math.monthGridDays(anchor)
        let weeks = (0..<6).map { Array(cells[($0 * 7)..<($0 * 7 + 7)]) }
        let wednesday = math.stamp(math.calendar.date(from: DateComponents(year: 2026, month: 7, day: 15))!)
        let index = weeks.firstIndex { $0.contains(wednesday) }
        XCTAssertNotNil(index)
        XCTAssertEqual(weeks[index!].count, 7)
    }
}
