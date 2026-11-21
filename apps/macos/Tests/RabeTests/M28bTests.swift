import AppKit
import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.8b — Befunde aus Live-Test 1, Kalender und KI-Sprache.
///
/// Die vier Punkte, die hier einen Test haben:
/// 1. Deutsch als KI-Sprache (`"system"` wird zu `"de"`, wenn das Gerät deutsch ist).
/// 2. Trefferfläche des Zeitrasters (Punkt → Termin, auch bei überlappenden Lanes).
/// 3. Klick oder Doppelklick (eine Klickfolge statt einer Hoffnung).
/// 4. `Return`/`⌫`/`Esc` im Kalender, und jede Postfachwahl verlässt ihn.
@MainActor
final class M28bLanguageTests: XCTestCase {
    func testGermanKeyboardIsStoredAsGerman() {
        XCTAssertEqual(AILanguage.stored(AILanguage.system, preferred: ["de-DE", "en-US"]), "de")
    }

    func testAnotherKnownLanguageIsStoredAsItsCode() {
        XCTAssertEqual(AILanguage.stored(AILanguage.system, preferred: ["en-GB"]), "en")
        XCTAssertEqual(AILanguage.stored(AILanguage.system, preferred: ["zh-Hans-CN"]), "zh")
        XCTAssertEqual(AILanguage.stored(AILanguage.system, preferred: ["vi-VN"]), "vi")
    }

    func testAnUnknownSystemLanguageStaysSystem() {
        // No name in the core: better no instruction than a wrong one.
        XCTAssertEqual(AILanguage.stored(AILanguage.system, preferred: ["ja-JP"]), AILanguage.system)
        XCTAssertEqual(AILanguage.stored(AILanguage.system, preferred: []), AILanguage.system)
    }

    func testAChosenLanguageIsNeverResolved() {
        XCTAssertEqual(AILanguage.stored("de", preferred: ["en-US"]), "de")
        XCTAssertEqual(AILanguage.stored("fr", preferred: ["de-DE"]), "fr")
    }

    func testBaseCodeOfARegionTag() {
        XCTAssertEqual(AILanguage.baseCode(of: "de-DE"), "de")
        XCTAssertEqual(AILanguage.baseCode(of: "zh-Hans-CN"), "zh")
        XCTAssertEqual(AILanguage.baseCode(of: ""), nil)
        XCTAssertEqual(AILanguage.baseCode(of: nil), nil)
    }
}

/// The settings side: picking "System" writes a code the core understands and
/// the picker still shows "System"; a changed macOS language arrives on the next
/// launch.
@MainActor
final class M28bSettingsLanguageTests: XCTestCase {
    private let flagKey = "rabe.languageFollowsSystem"

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "rabe.languageFollowsSystem")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "rabe.languageFollowsSystem")
    }

    private func store(_ core: FakeCore, preferred: [String] = ["de-DE"]) async -> SettingsStore {
        let store = SettingsStore()
        store.client = core
        store.preferredLanguages = { preferred }
        await store.load()
        return store
    }

    func testSystemWithAGermanMacWritesGerman() async {
        let core = FakeCore()
        let store = await store(core)
        store.setLanguage(AILanguage.system)
        await store.waitForPendingWrites()

        let written = await core.lastSettings()
        XCTAssertEqual(written["language"], "de", "der Kern bekommt einen Code, nicht „system“")
        XCTAssertEqual(store.languageChoice, AILanguage.system, "der Picker zeigt weiter „System“")
    }

    func testChoosingGermanKeepsGerman() async {
        let core = FakeCore()
        let store = await store(core, preferred: ["en-US"])
        store.setLanguage("de")
        await store.waitForPendingWrites()

        let written = await core.lastSettings()
        XCTAssertEqual(written["language"], "de")
        XCTAssertEqual(store.languageChoice, "de", "eine eigene Wahl folgt dem Gerät nicht")
        XCTAssertFalse(store.languageFollowsSystem)
    }

    func testALanguageThatFollowsTheSystemIsResolvedAgainAfterLoad() async {
        let core = FakeCore()
        let store = await store(core, preferred: ["de-AT"])
        // An install from before M2.8b: "system" is stored, no flag yet.
        store.set("language", AILanguage.system)
        await store.waitForPendingWrites()
        XCTAssertEqual(store.languageChoice, AILanguage.system)

        store.syncSystemLanguage()
        await store.waitForPendingWrites()

        let written = await core.lastSettings()
        XCTAssertEqual(written["language"], "de")
        XCTAssertEqual(store.languageChoice, AILanguage.system)
    }

    func testAChosenLanguageIsNotOverwrittenOnLoad() async {
        let core = FakeCore()
        let store = await store(core, preferred: ["en-US"])
        store.setLanguage("de")
        await store.waitForPendingWrites()

        store.syncSystemLanguage()
        await store.waitForPendingWrites()

        let written = await core.lastSettings()
        XCTAssertEqual(written["language"], "de", "die eigene Wahl bleibt")
    }
}

// MARK: - Klickfolge

final class M28bClickTests: XCTestCase {
    func testOneClickIsASingleClick() {
        var sequencer = CalendarClickSequencer()
        XCTAssertEqual(sequencer.register(at: 10, token: "1"), .single)
    }

    func testASecondClickInTimeIsADoubleClick() {
        var sequencer = CalendarClickSequencer()
        XCTAssertEqual(sequencer.register(at: 10, token: "1"), .single)
        XCTAssertEqual(sequencer.register(at: 10.2, token: "1"), .double)
    }

    func testASlowSecondClickStartsANewSingleClick() {
        var sequencer = CalendarClickSequencer()
        XCTAssertEqual(sequencer.register(at: 10, token: "1"), .single)
        XCTAssertEqual(sequencer.register(at: 11, token: "1"), .single)
    }

    func testAClickOnAnotherEventNeverPairs() {
        var sequencer = CalendarClickSequencer()
        XCTAssertEqual(sequencer.register(at: 10, token: "1"), .single)
        XCTAssertEqual(sequencer.register(at: 10.1, token: "2"), .single,
                       "zwei Klicks auf verschiedene Termine sind kein Doppelklick")
    }

    func testTheClickAfterADoubleClickCountsAgain() {
        var sequencer = CalendarClickSequencer()
        _ = sequencer.register(at: 10, token: "1")
        XCTAssertEqual(sequencer.register(at: 10.1, token: "1"), .double)
        XCTAssertEqual(sequencer.register(at: 10.5, token: "1"), .single,
                       "nach einem Doppelklick beginnt eine neue Folge")
    }
}

// MARK: - Trefferfläche

/// The grid's geometry: which event a point hits, including overlapping lanes.
final class M28bHitTestTests: XCTestCase {
    private func math() -> CalendarMath {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return CalendarMath(calendar: calendar, weekStartsOn: .monday)
    }

    private func event(_ id: Int64, startsAt: Int64, endsAt: Int64) -> CalendarEvent {
        CalendarEvent(id: id, accountId: 1, messageId: nil, summary: "T\(id)", location: nil,
                      organizer: nil, description: nil, attendees: [], joinUrl: nil,
                      rsvpStatus: nil, isLocal: true, calendarId: nil, rrule: nil,
                      startsAt: startsAt, endsAt: endsAt, allDay: false,
                      status: "CONFIRMED", method: nil)
    }

    /// Monday 09:00 for 30 / 60 minutes, plus two overlapping ones (lanes).
    private func fixture() -> (days: [Int64], positioned: [Int64: [PositionedEvent]], day: Int64) {
        let math = self.math()
        let day = math.stamp(math.calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 6))!)
        let nine = math.at(day, hour: 9)
        let events = [
            event(1, startsAt: nine, endsAt: nine + 30 * 60_000),           // 09:00–09:30
            event(2, startsAt: nine + 2 * 3_600_000, endsAt: nine + 3 * 3_600_000), // 11:00–12:00
            event(3, startsAt: nine + 3 * 3_600_000, endsAt: nine + 3 * 3_600_000 + 30 * 60_000),
            event(4, startsAt: nine + 3 * 3_600_000, endsAt: nine + 3 * 3_600_000 + 30 * 60_000),
        ]
        let model = CalendarWeekModel.build(events: events, days: [day], math: math)
        return ([day], model.positioned, day)
    }

    func testAPointInABlockFindsItsEvent() {
        let (days, positioned, _) = fixture()
        // 09:10 in the 09:00 block, first column (one lane → full width).
        let y = CalendarMath.msToY(9 * 3_600_000 + 10 * 60_000, dayStart: 0)
        let hit = CalendarHitTest.event(atX: CalendarGrid.gutterPx + 20, y: y, days: days,
                                        columnWidth: 140, positioned: positioned)
        XCTAssertEqual(hit?.event.id, 1)
        XCTAssertEqual(hit?.isResizeHandle, false)
    }

    func testTheBottomEdgeIsTheResizeHandle() {
        let (days, positioned, _) = fixture()
        guard let placed = positioned.values.first?.first(where: { $0.event.id == 2 }) else {
            return XCTFail("Termin 2 fehlt")
        }
        let rect = CalendarHitTest.rect(of: placed, columnWidth: 140)
        let hit = CalendarHitTest.event(atX: CalendarGrid.gutterPx + 20,
                                        y: rect.y + rect.height - 2, days: days,
                                        columnWidth: 140, positioned: positioned)
        XCTAssertEqual(hit?.event.id, 2)
        XCTAssertEqual(hit?.isResizeHandle, true)
    }

    func testEmptySpaceFindsNothing() {
        let (days, positioned, _) = fixture()
        // 08:00, above every block.
        let y = CalendarMath.msToY(8 * 3_600_000, dayStart: 0)
        XCTAssertNil(CalendarHitTest.event(atX: CalendarGrid.gutterPx + 20, y: y, days: days,
                                           columnWidth: 140, positioned: positioned))
    }

    func testTheHourGutterIsNoDay() {
        let (days, positioned, _) = fixture()
        XCTAssertNil(CalendarHitTest.event(atX: 10, y: 400, days: days, columnWidth: 140,
                                           positioned: positioned))
        XCTAssertEqual(CalendarHitTest.dayIndex(atX: 10, dayCount: 1, columnWidth: 140), nil)
        XCTAssertEqual(CalendarHitTest.dayIndex(atX: CalendarGrid.gutterPx + 5, dayCount: 1,
                                                columnWidth: 140), 0)
    }

    func testOverlappingLanesResolveToTheBlockUnderThePointer() {
        let (days, positioned, _) = fixture()
        guard let placed = positioned.values.first?.first(where: { $0.event.id == 3 }) else {
            return XCTFail("Termin 3 fehlt")
        }
        let lanes = placed.lanes
        XCTAssertEqual(lanes, 2, "die beiden 12:00-Termine liegen in zwei Spalten")
        let laneWidth = 140 / Double(lanes)
        let y = CalendarMath.msToY(12 * 3_600_000 + 10 * 60_000, dayStart: 0)
        let left = CalendarHitTest.event(atX: CalendarGrid.gutterPx + laneWidth / 2, y: y,
                                         days: days, columnWidth: 140, positioned: positioned)
        let right = CalendarHitTest.event(atX: CalendarGrid.gutterPx + laneWidth + laneWidth / 2,
                                          y: y, days: days, columnWidth: 140, positioned: positioned)
        XCTAssertEqual(Set([left?.event.id, right?.event.id]), [3, 4],
                       "links und rechts treffen verschiedene Termine")
    }

    func testTheSecondDayColumnHitsItsOwnDay() {
        let (days, positioned, day) = fixture()
        let y = CalendarMath.msToY(9 * 3_600_000 + 10 * 60_000, dayStart: 0)
        // Two columns: the same y in the second column is empty.
        let twoDays = [day, day + CalendarGrid.dayMs]
        XCTAssertNil(CalendarHitTest.event(atX: CalendarGrid.gutterPx + 140 + 20, y: y,
                                           days: twoDays, columnWidth: 140,
                                           positioned: positioned))
        XCTAssertEqual(CalendarHitTest.event(atX: CalendarGrid.gutterPx + 20, y: y, days: twoDays,
                                             columnWidth: 140, positioned: positioned)?.event.id, 1)
    }
}

// MARK: - Tasten im Kalender

/// `Return` öffnet den gewählten Termin, `⌫` löscht ihn, `Esc` schließt zuerst
/// eine offene Karte und erst dann den Kalender.
@MainActor
final class M28bCalendarKeyTests: XCTestCase {
    actor OneCalendar: CalendarCore {
        let event: CalendarEvent
        init(event: CalendarEvent) { self.event = event }
        func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] { [event] }
        func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent] { [] }
        func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent { event }
        func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent { event }
        func deleteEvent(_ id: Int64, notify: Bool) async throws {}
        func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent { event }
        func listCalendars(accountId: Int64?) async throws -> [CalendarCollection] { [] }
        func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws {}
        func setCalendarColor(_ id: Int64, color: String?) async throws {}
        func setDefaultCalendar(_ id: Int64) async throws {}
        func calendarSyncNow(accountId: Int64?) async throws {}
    }

    private func store() async -> CalendarStore {
        let math = CalendarMath()
        let start = math.at(math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000)), hour: 9)
        let event = CalendarEvent(id: 42, accountId: 1, messageId: nil, summary: "Test",
                                  location: nil, organizer: nil, description: nil,
                                  attendees: [], joinUrl: nil, rsvpStatus: nil, isLocal: true,
                                  calendarId: nil, rrule: nil, startsAt: start,
                                  endsAt: start + 30 * 60_000, allDay: false,
                                  status: "CONFIRMED", method: nil)
        let store = CalendarStore(toasts: ToastCenter())
        store.client = OneCalendar(event: event)
        await store.refresh()
        return store
    }

    private func key(_ code: UInt16, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private var returnKey: NSEvent { key(36, "\r") }
    private var deleteKey: NSEvent { key(51, "\u{7f}") }
    private var escapeKey: NSEvent { key(53, "\u{1b}") }

    func testReturnOpensTheCardOfTheSelectedEvent() async {
        let store = await store()
        store.selectedEventId = 42
        var opened: Int64?
        var closed = false
        let handled = CalendarKeyboard.handle(returnKey, store: store, openNew: {},
                                              openCard: { opened = $0.id },
                                              close: { closed = true })
        XCTAssertTrue(handled)
        XCTAssertEqual(opened, 42)
        XCTAssertFalse(closed)
    }

    func testReturnWithoutASelectionDoesNothing() async {
        let store = await store()
        var opened = false
        let handled = CalendarKeyboard.handle(returnKey, store: store, openNew: {},
                                              openCard: { _ in opened = true }, close: {})
        XCTAssertTrue(handled, "die Taste gehört dem Kalender, auch ohne Ziel")
        XCTAssertFalse(opened)
    }

    func testDeleteKeyDeletesTheSelectedEvent() async {
        let store = await store()
        store.selectedEventId = 42
        var deleted: Int64?
        _ = CalendarKeyboard.handle(deleteKey, store: store, openNew: {},
                                    deleteSelected: { deleted = $0.id }, close: {})
        XCTAssertEqual(deleted, 42)
    }

    /// M2.18 §4: `Esc` verlässt den Kalender **nicht** mehr. Die Karte schließt
    /// der Monitor des Bildschirms (dort hält ein Feld die Tastatur); ohne Karte
    /// nimmt `Esc` nur die Auswahl weg.
    func testEscapeStaysInTheCalendar() async {
        let store = await store()
        store.selectedEventId = 42
        var closedCalendar = false
        let handled = CalendarKeyboard.handle(escapeKey, store: store, openNew: {},
                                              close: { closedCalendar = true })
        XCTAssertTrue(handled)
        XCTAssertFalse(closedCalendar, "Esc führt nicht mehr zur Mail")
        XCTAssertNil(store.selectedEventId, "Esc hebt die Auswahl auf")
    }

    func testTheSelectionSurvivesOnlyWhileTheEventIsVisible() async {
        let store = await store()
        store.selectedEventId = 42
        XCTAssertEqual(store.selectedEvent?.id, 42)
        store.selectedEventId = 999
        XCTAssertNil(store.selectedEvent, "ein Termin außerhalb des Bereichs ist nicht wählbar")
    }
}

// MARK: - Kalender verlassen

/// Punkt 3: jede Postfach- oder Ansichtswahl verlässt den Kalender.
@MainActor
final class M28bLeaveCalendarTests: XCTestCase {
    private static var sandboxGate: WriteAccess { WriteAccess(identifier: Instance.sandbox, mode: .sandbox) }

    private func store() -> MailboxStore {
        MailboxStore(toasts: ToastCenter(), settings: SettingsStore(),
                     writeAccess: Self.sandboxGate, platform: TestPlatform())
    }

    private func row(_ id: Int64) -> ThreadSummary {
        ThreadSummary(id: id, accountId: 1, accountEmail: "a@b.de", subject: "S\(id)", snippet: "",
                      participants: [], lastMessageAt: 1_700_000_000_000 + id, messageCount: 1,
                      unreadCount: 0, isStarred: false, hasAttachments: false, snoozedUntil: nil,
                      labels: [])
    }

    /// The state the app keeps: the calendar is open, the user picks a mailbox.
    private final class CalendarFlag { var open = true }

    func testPickingAViewLeavesTheCalendar() {
        let box = store()
        let flag = CalendarFlag()
        box.onUserNavigation = { flag.open = false }
        box.applyThreads([row(1)], cursor: nil)
        box.setView(.done)
        XCTAssertFalse(flag.open, "die Ansichtswahl schließt den Kalender")
        XCTAssertEqual(box.view, .done, "und zeigt die gewählte Ansicht")
    }

    func testPickingATabOrAccountLeavesTheCalendar() {
        let box = store()
        var left = 0
        box.onUserNavigation = { left += 1 }
        box.applyThreads([row(1)], cursor: nil)
        box.setAccount(2)
        XCTAssertEqual(left, 1)
        XCTAssertEqual(box.accountId, 2)
    }

    func testRunningASearchLeavesTheCalendar() {
        let box = store()
        var left = 0
        box.onUserNavigation = { left += 1 }
        box.searchText = "rechnung"
        box.runSearch()
        XCTAssertEqual(left, 1)
        XCTAssertEqual(box.searchQuery, "rechnung")
    }

    /// M2.8c: eine Wahl derselben Ansicht ist keine Ausnahme mehr — sie schließt
    /// den Kalender ebenfalls (Inbox → Kalender → Inbox, die drei Fälle stehen in
    /// `M28cTests`). Hier bleibt die Gegenprobe: was die App selbst setzt,
    /// schließt nichts.
    func testProgrammaticResetsDoNotFire() {
        let box = store()
        var left = 0
        box.onUserNavigation = { left += 1 }
        box.setAccount(box.accountId, byUser: false)
        XCTAssertEqual(left, 0, "kein Nutzerwunsch, nichts zu schließen")
    }
}
