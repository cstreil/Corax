import Foundation
import Observation
import os

/// Calendar state for the native app (M2.2). Owns the visible range, the events
/// the core returned for it, the calendars and the week model the grids draw.
/// Every write goes through `CalendarCore` (the real client, or a fake in the
/// tests) and is followed by a reload, so the UI never shows an event the core
/// did not keep.
/// Ein Termin, der in der Karte entsteht, bevor ihn der Kern kennt (§7.3).
public struct CalendarEventDraft: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// Der bearbeitete Termin, `nil` bei einem neuen.
    public var event: CalendarEvent?
    public var startsAt: Int64
    public var endsAt: Int64
    public var allDay: Bool
    public var title: String?
    public var location: String?
    public var notes: String?
    public var attendees: [Address]

    public init(event: CalendarEvent? = nil, startsAt: Int64, endsAt: Int64, allDay: Bool = false,
                title: String? = nil, location: String? = nil, notes: String? = nil,
                attendees: [Address] = []) {
        self.event = event
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.title = title
        self.location = location
        self.notes = notes
        self.attendees = attendees
    }
}

@MainActor
@Observable
public final class CalendarStore {
    public enum Mode: String, Sendable, CaseIterable, Identifiable {
        case day, week, month, year, list
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .day: "Tag"
            case .week: "Woche"
            case .month: "Monat"
            case .year: "Jahr"
            case .list: "Liste"
            }
        }
        /// Taste aus `TASTATUR.md` (nur Anzeige, die Tasten liegen im Raster).
        public var shortcut: String {
            switch self {
            case .day: "D"
            case .week: "W"
            case .month: "M"
            case .year: "Y"
            case .list: "L"
            }
        }
        /// M2.13: ⌘1–5 in der Reihenfolge der Werkzeugleiste.
        public var commandNumber: Int {
            switch self {
            case .day: 1
            case .week: 2
            case .month: 3
            case .year: 4
            case .list: 5
            }
        }
        /// Ansichten mit Zeitraster (die anderen zeichnen anders).
        public var isGrid: Bool { self == .day || self == .week }
    }

    public private(set) var calendars: [CalendarCollection] = []
    /// M2.15b (2.2): Adressen des Nutzers (Konto-Adressen, klein). Die App
    /// setzt sie, sobald die Konten geladen sind; ohne sie gilt nur ein leerer
    /// Organisator als eigener Termin.
    public var ownEmails: Set<String> = []
    /// Everything the core returned for the visible range, unfiltered.
    public private(set) var events: [CalendarEvent] = []
    public private(set) var messageEvents: [Int64: [CalendarEvent]] = [:]
    public private(set) var loaded = false
    public private(set) var loading = false
    public private(set) var busy = false

    // MARK: Suche und Nachladen der Terminliste (M2.17)

    /// Suchfeld offen (`/` in der Liste).
    public var searchOpen = false
    /// Was im Suchfeld steht. Leer = normale Liste.
    public var searchText = ""
    /// Wie weit die Liste über das Grundfenster hinaus geladen ist. Die Suche
    /// und das Nachladen teilen sich dieses Fenster.
    public private(set) var listWindowBack = CalendarStore.listDaysBack
    public private(set) var listWindowForward = CalendarStore.listDaysForward
    public private(set) var loadingMoreList = false
    /// Tag aus der Jahresansicht, zu dem die Liste springen soll (M2.17 §5).
    public private(set) var pendingListScrollDay: Int64?

    // MARK: CalDAV connect and sync status (M2.12)

    /// „Konto verbinden“ läuft gerade (`connect_calendar`).
    public private(set) var connecting = false
    /// Klartext des letzten Verbindungsversuchs, `nil` solange keiner scheiterte.
    public private(set) var connectError: String?
    /// Erfolgsmeldung des letzten Verbindungsversuchs.
    public private(set) var connectNotice: String?
    /// Ein „Jetzt synchronisieren“ lief ohne sichtbaren Fortschritt.
    public private(set) var lastSyncUnconfirmed = false

    /// How a sync cycle looks from the app's side. The core does not expose
    /// `caldav_config.last_error` (M2.12 report), so the app can only tell
    /// "synced recently", "synced long ago" and "never" — not *why* a cycle
    /// fails. The wording in the settings window says so.
    public enum SyncStatus: Equatable, Sendable {
        case noCalendars
        case neverSynced
        case current(Int64)
        case stale(Int64)
    }

    /// A pull runs every five minutes (`caldav/task.rs`, `POLL_SECS`); three
    /// missed cycles mean something is wrong.
    public static let staleSyncAfterSeconds: Int64 = 15 * 60

    public static func syncStatus(lastSyncedAt: Int64?, hasCalendars: Bool,
                                  now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> SyncStatus {
        guard hasCalendars else { return .noCalendars }
        guard let lastSyncedAt else { return .neverSynced }
        let age = (now - lastSyncedAt) / 1000
        return age > staleSyncAfterSeconds ? .stale(lastSyncedAt) : .current(lastSyncedAt)
    }

    /// Der jüngste erfolgreiche Abgleich über alle Kalender.
    public var lastSyncAt: Int64? { calendars.compactMap(\.lastSyncedAt).max() }

    public var syncStatus: SyncStatus {
        Self.syncStatus(lastSyncedAt: lastSyncAt, hasCalendars: !calendars.isEmpty)
    }

    /// Layout of the day/week grids for the current range (nil in month view).
    public private(set) var weekModel: CalendarWeekModel?
    /// Duration of the last grid build in milliseconds (same number as the
    /// `week_switch` signpost interval; the perf hook reads it).
    public private(set) var lastLayoutMilliseconds: Double = 0
    /// Duration of the last `list_events` round trip in milliseconds.
    public private(set) var lastFetchMilliseconds: Double = 0

    /// The event a click last picked (M2.8b): `Return` opens it, `⌫` deletes
    /// it, like the mail list's row cursor.
    public var selectedEventId: Int64?

    // MARK: Karte am Ort (M2.9 Stufe C)
    /// Wie die Karte eines Termins gerade aussieht.
    public enum CardMode: String, Sendable { case view, edit }

    /// Die Karte, die im Raster aufgeht. Getrennt von `selectedEventId`: die
    /// Auswahl bleibt bestehen, wenn die Karte zu ist (`↑`/`↓` arbeiten weiter).
    public private(set) var openEventId: Int64?
    public private(set) var cardMode: CardMode = .view
    /// Ein neuer Termin, der noch nicht gespeichert ist: der gestrichelte
    /// Platzhalter im Raster und die Karte im Bearbeiten-Modus (§7.3).
    public private(set) var draft: CalendarEventDraft?
    /// Zähler für `⌘↵` aus dem Raster: die Karte in der Bearbeitung sichert.
    public private(set) var saveRequest = 0
    /// M2.18o: welcher `⌘↵`-Aufruf schon verarbeitet ist. Die Karte kann in
    /// mehreren Ansichten im Baum hängen; ohne diesen Riegel sicherte jede
    /// Kopie, und dieselbe Änderung ging doppelt an den Kern.
    private var handledSaveRequest = 0

    public var cardIsOpen: Bool { openEventId != nil || draft != nil }

    /// Der Termin der offenen Karte, solange er im sichtbaren Zeitraum liegt.
    public var openEvent: CalendarEvent? {
        guard let openEventId else { return nil }
        return visibleEvents.first { $0.id == openEventId }
    }

    /// Die Karte aufgehen lassen (Klick, `↵`, `O`). `id` darf eine Anzeige-
    /// Kennung oder die Kern-Kennung sein (Hooks und Menüs kennen letztere).
    public func openCard(_ id: Int64, edit: Bool = false) {
        guard let event = occurrence(forEventId: id) else { return }
        selectedEventId = event.id
        draft = nil
        openEventId = event.id
        // M2.18g: `⌘E`, Stift und Doppelklick landen hier. Ein abgewiesenes
        // Bearbeiten fiel bisher still auf die Anzeige zurück — ohne Zeile im
        // Log war nicht zu sehen, ob `⌘E` überhaupt ankam oder ob die Regel
        // den Termin gesperrt hat. Derselbe Grund wie in `editOpenCard`.
        var editable = true
        if edit, let reason = editBlockReason(event) {
            editable = false
            PerfLog.shared.write("calendar_card_edit_blocked id=\(event.id) reason=\(reason)")
        }
        cardMode = edit && editable ? .edit : .view
        PerfLog.shared.write("calendar_card_open id=\(event.id) mode=\(cardMode.rawValue)")
    }

    /// Die Wiederholung zu einer Kennung: erst die Anzeige-Kennung, dann die
    /// Kern-Kennung (M2.18 §5 — jede Wiederholung einer Serie hat ihre eigene).
    public func occurrence(forEventId id: Int64) -> CalendarEvent? {
        if let exact = visibleEvents.first(where: { $0.id == id }) { return exact }
        return visibleEvents.first { $0.eventId == id }
    }

    public func closeCard() {
        guard cardIsOpen else { return }
        PerfLog.shared.write("calendar_card_close")
        openEventId = nil
        draft = nil
        cardMode = .view
    }

    /// M2.12: a click on empty grid space closes the card instead of starting a
    /// new event. Returns true when it consumed the click; the grid's create
    /// gesture continues only on false.
    public func closeCardOnEmptySpace() -> Bool {
        guard cardIsOpen else { return false }
        closeCard()
        PerfLog.shared.write("calendar_empty_click_closed")
        return true
    }

    /// M2.12 requirement 6: what `Esc` means right now. A pure decision so the
    /// screen's monitor and the tests agree on the chain
    /// Bearbeiten → Anzeige → Karte zu → Kalender zu.
    public enum EscapeAction: Equatable, Sendable {
        case cancelEdit
        case closeCard
        case leaveCalendar
    }

    public func escapeAction() -> EscapeAction {
        guard cardIsOpen else { return .leaveCalendar }
        return cardMode == .edit ? .cancelEdit : .closeCard
    }

    /// M2.18 §4: `Esc` ohne Karte nimmt die Auswahl weg — und führt **nicht**
    /// zurück zur Mail. Der Weg zurück ist `⌥⌘1`, der Knopf oder die
    /// Seitenleiste; `Esc` bleibt im Kalender.
    public func clearSelection() {
        guard selectedEventId != nil else { return }
        PerfLog.shared.write("calendar_selection_cleared")
        selectedEventId = nil
    }

    /// `↵` in der Anzeige bzw. der Stift: dieselbe Karte wird zum Formular.
    public func editOpenCard() {
        guard let event = openEvent else { return }
        if let reason = editBlockReason(event) {
            // M2.18 §2: Der Grund steht im Log — sonst rätselt man wieder, warum
            // ein Stift fehlt oder nicht wirkt.
            PerfLog.shared.write("calendar_card_edit_blocked id=\(event.id) reason=\(reason)")
            return
        }
        cardMode = .edit
        PerfLog.shared.write("calendar_card_edit id=\(event.id)")
    }

    /// Warum dieser Termin nicht bearbeitet werden darf (nil = darf).
    public func editBlockReason(_ event: CalendarEvent) -> String? {
        CalendarPermissions.blockReason(event, calendars: calendars, ownEmails: ownEmails)
    }

    /// Esc im Bearbeiten: bei einem neuen Termin verschwindet der Platzhalter,
    /// bei einem bestehenden kehrt die Anzeige zurück (Änderungen sind nicht
    /// gespeichert, weil erst `⌘↵` schreibt).
    public func cancelEdit() {
        guard cardMode == .edit else { return }
        if draft != nil {
            draft = nil
            openEventId = nil
        }
        cardMode = .view
        PerfLog.shared.write("calendar_card_cancel")
    }

    /// Ein neuer Termin: Platzhalter im Raster, Karte im Bearbeiten-Modus.
    public func beginDraft(_ draft: CalendarEventDraft) {
        self.draft = draft
        openEventId = nil
        cardMode = .edit
        selectedEventId = nil
        PerfLog.shared.write("calendar_card_draft start=\(draft.startsAt) allDay=\(draft.allDay ? 1 : 0)")
    }

    /// Nach dem Sichern einer Bearbeitung: dieselbe Karte zeigt den neuen Stand.
    public func savedOpenCard() {
        draft = nil
        cardMode = .view
        PerfLog.shared.write("calendar_card_saved")
    }

    /// Der neue Termin wurde gespeichert: Karte zu, Liste neu.
    public func draftSaved() {
        draft = nil
        openEventId = nil
        cardMode = .view
    }

    public func requestSave() { saveRequest += 1 }

    /// M2.18o: Ein `⌘↵` gehört genau einer Karte. Der erste Aufruf nach dem
    /// Zähler verarbeitet den Auftrag, weitere Kopien derselben Karte bekommen
    /// `false` — sonst sicherte dieselbe Änderung mehrfach (auch die
    /// Teilnehmer-Mail ginge doppelt raus).
    public func takeSaveRequest() -> Bool {
        guard saveRequest > handledSaveRequest else { return false }
        handledSaveRequest = saveRequest
        return true
    }

    /// `↑`/`↓`: der vorige bzw. nächste Termin im sichtbaren Zeitraum, nach
    /// Start sortiert (ganztägige zuerst, gleicher Start nach Titel). Eine
    /// offene Karte wandert mit.
    public func selectAdjacent(_ delta: Int) {
        let ordered = navigationOrder()
        guard !ordered.isEmpty else { return }
        let current = selectedEventId.flatMap { id in ordered.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), ordered.count - 1)
        } else {
            next = delta >= 0 ? 0 : ordered.count - 1
        }
        let id = ordered[next].id
        selectedEventId = id
        if cardIsOpen, draft == nil { openCard(id) }
        PerfLog.shared.write("calendar_select id=\(id) index=\(next) n=\(ordered.count)")
    }

    /// Die Reihenfolge für `↑`/`↓` (auch die Tests prüfen sie).
    ///
    /// M2.15b (2.3): In der Terminliste entscheidet die **Anzeige** die
    /// Reihenfolge (Tagesgruppen, ganztägig zuerst, mehrtägige Termine nur an
    /// der ersten Stelle). Vorher lief die Auswahl durch alle geladenen
    /// Termine — sie sprang an der Liste vorbei.
    public func navigationOrder() -> [CalendarEvent] {
        if isSearching { return searchResults }
        if mode == .list {
            let ordered = AgendaModel.orderedEvents(events: visibleEvents, days: listDays)
            if !ordered.isEmpty { return ordered }
        }
        return visibleEvents.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            if a.startsAt != b.startsAt { return a.startsAt < b.startsAt }
            return (a.summary ?? "").localizedStandardCompare(b.summary ?? "") == .orderedAscending
        }
    }

    /// M2.12: was ein Schritt von `↑`/`↓`/`←`/`→` tut. Am Rand der sichtbaren
    /// Spanne blättert die Ansicht eine Seite weiter statt stehenzubleiben.
    public enum NavigationStep: Equatable, Sendable {
        case select(Int64)
        case page(Int)
    }

    /// Reine Funktion für die Tests: ohne Auswahl führt `+1` zum ersten und
    /// `-1` zum letzten Termin; über den Rand hinaus wird geblättert.
    public func navigationStep(_ delta: Int) -> NavigationStep {
        let ordered = navigationOrder()
        guard !ordered.isEmpty else { return .page(delta >= 0 ? 1 : -1) }
        guard let current = selectedEventId.flatMap({ id in ordered.firstIndex { $0.id == id } }) else {
            return .select(ordered[delta >= 0 ? 0 : ordered.count - 1].id)
        }
        let next = current + delta
        guard ordered.indices.contains(next) else { return .page(delta >= 0 ? 1 : -1) }
        return .select(ordered[next].id)
    }

    /// `↑`/`↓` bzw. `←`/`→` (M2.12): Auswahl wandert, am Rand wird geblättert;
    /// die erste bzw. letzte Auswahl der neuen Seite wird nach dem Laden gesetzt.
    public func navigate(_ delta: Int) {
        switch navigationStep(delta) {
        case .select(let id):
            selectedEventId = id
            if cardIsOpen, draft == nil { openCard(id) }
            PerfLog.shared.write("calendar_navigate id=\(id)")
        case .page(let direction):
            pendingSelection = direction > 0 ? .first : .last
            page(direction)
            PerfLog.shared.write("calendar_navigate page=\(direction)")
        }
    }

    private enum PendingSelection { case first, last }
    private var pendingSelection: PendingSelection?

    /// The selected event while it is still in the visible range.
    public var selectedEvent: CalendarEvent? {
        guard let selectedEventId else { return nil }
        return visibleEvents.first { $0.id == selectedEventId }
    }

    /// M2.15b (2.2): Darf dieser Termin bearbeitet werden? Die Regel steht in
    /// `CalendarPermissions` (testbar ohne UI).
    public func canEdit(_ event: CalendarEvent) -> Bool {
        CalendarPermissions.canEdit(event, calendars: calendars, ownEmails: ownEmails)
    }

    /// M2.15b (2.2): Darf der Nutzer zu- oder absagen?
    public func canRSVP(_ event: CalendarEvent) -> Bool {
        CalendarPermissions.canRSVP(event, ownEmails: ownEmails)
    }

    /// Local midnight of the focused day.
    public var anchor: Int64
    public var mode: Mode = .week
    /// M2.9: die Seitenleiste ist jetzt die gemeinsame des Hauptfensters. Der
    /// Kalender liest und schaltet dieselbe; ohne Shell (Tests) bleibt das
    /// lokale Feld.
    public weak var shell: SidebarState?
    private var localSidebarVisible = true
    public var sidebarVisible: Bool {
        get { shell?.isVisible ?? localSidebarVisible }
        set {
            if let shell {
                if shell.isVisible != newValue { shell.toggle() }
            } else {
                localSidebarVisible = newValue
            }
        }
    }
    /// Calendars the user switched off (kept across launches).
    public var hiddenCalendars: Set<Int64> {
        didSet { UserDefaults.standard.set(hiddenCalendars.map(String.init), forKey: Self.hiddenKey) }
    }
    /// The "Einladungen & lokal" row: events without a CalDAV collection.
    public var hiddenLocal: Bool {
        didSet { UserDefaults.standard.set(hiddenLocal, forKey: Self.hiddenLocalKey) }
    }

    public var client: (any CalendarCore)?
    public weak var settings: SettingsStore?
    public let toasts: ToastCenter

    private static let hiddenKey = "rabe.calendarHidden"
    private static let hiddenLocalKey = "rabe.calendarHiddenLocal"
    private static let signposter = OSSignposter(subsystem: AppIdentity.bundleID, category: "calendar")

    public init(toasts: ToastCenter, anchor: Int64? = nil) {
        self.toasts = toasts
        self.anchor = anchor ?? Int64(Date().timeIntervalSince1970 * 1000)
        let stored = UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []
        hiddenCalendars = Set(stored.compactMap(Int64.init))
        hiddenLocal = UserDefaults.standard.bool(forKey: Self.hiddenLocalKey)
    }

    // MARK: Derived state

    public var weekStartsOn: CalendarWeekStart { CalendarWeekStart(setting: settings?.calendarWeekStart ?? "monday") }
    public var math: CalendarMath { CalendarMath(weekStartsOn: weekStartsOn) }
    public var meetingReminderMinutes: Int { settings?.meetingNotifyLeadMinutes ?? 10 }
    public var todayStart: Int64 { math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000)) }

    /// Day starts of the visible range (`TimeGrid`/`MonthView` in Tauri).
    public var days: [Int64] {
        switch mode {
        case .day: [math.startOfDay(anchor)]
        case .week: math.weekDays(anchor)
        case .month: math.monthGridDays(anchor)
        case .year: yearDays
        case .list: listDays
        }
    }

    /// M2.13: alle Tage des Jahres, in dem der Anker liegt (Schaltjahr inklusive).
    public var yearDays: [Int64] {
        let year = math.calendar.component(.year, from: math.date(anchor))
        return YearGrid.days(year: year, calendar: math.calendar)
    }

    /// M2.13: das Fenster der Terminliste — 30 Tage zurück als Kontext, 30 voraus.
    /// M2.17 §2: Das Fenster wächst beim Scrollen an den Rändern in
    /// 30-Tage-Schritten (`listWindowBack`/`listWindowForward`), höchstens bis
    /// ein Jahr je Seite.
    public var listDays: [Int64] {
        let base = math.addDays(math.startOfDay(anchor), -listWindowBack)
        return (0..<(listWindowBack + listWindowForward)).map { math.addDays(base, $0) }
    }

    public static let listDaysBack = 30
    public static let listDaysForward = 31
    /// M2.17 §2: Schrittweite und Grenze des Nachladens (±12 Monate).
    public static let listLoadStep = 30
    public static let listMaxBack = 365
    public static let listMaxForward = 365

    /// M2.13: gewählter Tag in der Jahresansicht (0 = heute).
    public var selectedDay: Int64 = 0
    public var selectedDayOrToday: Int64 { selectedDay == 0 ? todayStart : selectedDay }

    /// M2.18h: das Datum, auf dem die aktuelle Ansicht steht — der ausgewählte
    /// Termin, sonst ein noch sichtbarer `selectedDay`, sonst der Anker.
    ///
    /// Vorher nahm die Jahresansicht bei leerem `selectedDay` schlicht „heute"
    /// und sprang damit beim Öffnen auf heute, auch wenn die Woche beim
    /// 15. Dezember stand. Ein `selectedDay` von einer früheren Seite zählt
    /// nicht, sonst markierte die Jahresansicht einen Tag, an dem niemand mehr
    /// ist.
    public var chosenDay: Int64 {
        if let event = selectedEvent { return math.startOfDay(event.startsAt) }
        if selectedDay != 0, days.contains(math.startOfDay(selectedDay)) {
            return math.startOfDay(selectedDay)
        }
        return math.startOfDay(anchor)
    }

    /// Setzt die Auswahl der Jahresansicht, ohne Daten nachzuladen.
    public func selectDay(_ day: Int64) {
        selectedDay = math.startOfDay(day)
    }

    /// Ein Schritt von 7 Tagen in der Jahresansicht (`↑`/`↓`).
    /// M2.17 §5: der gewählte Tag ist auch das Ziel der Terminliste.
    public func moveSelectedDay(byDays days: Int) {
        selectedDay = math.addDays(selectedDayOrToday, days)
        pendingListScrollDay = selectedDay
        PerfLog.shared.write("calendar_year_day day=\(selectedDay)")
    }

    /// Half-open epoch range the core is asked for.
    public var range: (start: Int64, end: Int64) {
        let days = days
        guard let first = days.first, let last = days.last else {
            let day = math.startOfDay(anchor)
            return (day, day + CalendarGrid.dayMs)
        }
        return (first, last + CalendarGrid.dayMs)
    }

    /// Events the user can see: hidden calendars and the "invites & local" row
    /// are filtered out.
    public var visibleEvents: [CalendarEvent] {
        events.filter { event in
            if let id = event.calendarId { return !hiddenCalendars.contains(id) }
            return !hiddenLocal
        }
    }

    public var enabledCalendars: [CalendarCollection] { calendars.filter(\.enabled) }

    /// Calendars grouped by account for the sidebar, with the account label.
    public func calendarGroups(accounts: [Account]) -> [(account: Account?, calendars: [CalendarCollection])] {
        var order: [Int64] = []
        var byAccount: [Int64: [CalendarCollection]] = [:]
        for calendar in enabledCalendars {
            if byAccount[calendar.accountId] == nil { order.append(calendar.accountId) }
            byAccount[calendar.accountId, default: []].append(calendar)
        }
        return order.map { id in (accounts.first { $0.id == id }, byAccount[id] ?? []) }
    }

    // MARK: Suche in der Terminliste (M2.17 §1)

    /// Sucht die Liste gerade? Nur dann filtern die Zeilen.
    public var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Treffer im geladenen Fenster, in Anzeigereihenfolge.
    public var searchResults: [CalendarEvent] {
        CalendarSearch.results(visibleEvents, query: searchText)
    }

    /// Die Zeilen der Trefferliste (Tagesgruppen, Band unter dem offenen Termin).
    public var searchRows: [AgendaRow] {
        AgendaModel.searchRows(events: searchResults, openEvent: openEventId, math: math)
    }

    public func openSearch() {
        searchOpen = true
        PerfLog.shared.write("calendar_search open=1 mode=\(mode.rawValue) "
                             + "window=\(listWindowBack)+\(listWindowForward)")
    }

    /// `Esc`: Feld leeren, Feld schließen, normale Liste zurück.
    public func closeSearch() {
        let had = searchOpen || !searchText.isEmpty
        searchOpen = false
        searchText = ""
        if had { PerfLog.shared.write("calendar_search open=0 query=\"\" hits=0") }
    }

    /// Wird bei jeder Änderung im Feld aufgerufen (Beleg und Trefferzahl).
    public func searchChanged() {
        PerfLog.shared.write("calendar_search query=\"\(searchText)\" "
                             + "hits=\(isSearching ? searchResults.count : 0) "
                             + "window=\(listWindowBack)+\(listWindowForward)")
    }

    // MARK: Nachladen der Liste (M2.17 §2)

    public enum ListStep: String, Sendable { case earlier, later }

    /// Was ein Schritt an den Rand nachladen würde — reine Entscheidung, damit
    /// Grenze und Ausschnitt ohne UI prüfbar sind.
    public struct ListLoadPlan: Equatable, Sendable {
        public let allowed: Bool
        public let start: Int64
        public let end: Int64
        public let back: Int
        public let forward: Int
    }

    public func listLoadPlan(_ step: ListStep, by days: Int = CalendarStore.listLoadStep) -> ListLoadPlan {
        let anchorDay = math.startOfDay(anchor)
        switch step {
        case .earlier:
            let back = min(listWindowBack + days, CalendarStore.listMaxBack)
            guard back > listWindowBack else {
                return ListLoadPlan(allowed: false, start: 0, end: 0,
                                    back: listWindowBack, forward: listWindowForward)
            }
            return ListLoadPlan(allowed: true,
                                start: math.addDays(anchorDay, -back),
                                end: math.addDays(anchorDay, -listWindowBack),
                                back: back, forward: listWindowForward)
        case .later:
            let forward = min(listWindowForward + days, CalendarStore.listMaxForward)
            guard forward > listWindowForward else {
                return ListLoadPlan(allowed: false, start: 0, end: 0,
                                    back: listWindowBack, forward: listWindowForward)
            }
            return ListLoadPlan(allowed: true,
                                start: math.addDays(anchorDay, listWindowForward),
                                end: math.addDays(anchorDay, forward),
                                back: listWindowBack, forward: forward)
        }
    }

    /// Hängt einen 30-Tage-Block an den Anfang oder das Ende der Liste. Die
    /// Auswahl bleibt stehen (kein `pendingSelection`).
    public func loadMoreList(_ step: ListStep) async {
        guard mode == .list, let client, !loading, !loadingMoreList else { return }
        let plan = listLoadPlan(step)
        guard plan.allowed else {
            PerfLog.shared.write("calendar_list_load direction=\(step.rawValue) allowed=0 "
                                 + "back=\(listWindowBack) forward=\(listWindowForward)")
            return
        }
        loadingMoreList = true
        defer { loadingMoreList = false }
        do {
            let rows = try await client.listEvents(startMs: plan.start, endMs: plan.end)
            let known = Set(events.map(\.id))
            events.append(contentsOf: Self.labelled(rows).filter { !known.contains($0.id) })
            events.sort { $0.startsAt < $1.startsAt }
            listWindowBack = plan.back
            listWindowForward = plan.forward
            rebuildWeekModel()
            PerfLog.shared.write("calendar_list_load direction=\(step.rawValue) fetched=\(rows.count) "
                                 + "total=\(events.count) back=\(listWindowBack) "
                                 + "forward=\(listWindowForward) "
                                 + "selected=\(selectedEventId.map(String.init) ?? "-")")
        } catch {
            toasts.error(error)
            PerfLog.shared.write("calendar_list_load direction=\(step.rawValue) failed")
        }
    }

    // MARK: Sprung aus der Jahresansicht (M2.17 §5)

    /// Merkt sich den Tag, zu dem die Liste springen soll. Ein Klick in der
    /// Jahresansicht wählt den Tag und merkt ihn vor; die Liste löst ihn beim
    /// nächsten Aufbau ein.
    public func scrollListToDay(_ day: Int64) {
        pendingListScrollDay = math.startOfDay(day)
        // M2.18f: der gewählte Tag wählt auch den ersten Termin dort aus.
        pendingListSelectDay = pendingListScrollDay
        PerfLog.shared.write("calendar_list_target day=\(pendingListScrollDay ?? 0)")
    }

    /// M2.17 §2: `End`/`Home` in der Liste springen an den Rand; erst dort
    /// lädt der Rand-Nachlader den nächsten 30-Tage-Block.
    public private(set) var listEdgeRequest = 0
    public private(set) var listEdgeTarget: ListStep?

    public func requestListEdge(_ step: ListStep) {
        listEdgeTarget = step
        listEdgeRequest += 1
        PerfLog.shared.write("calendar_list_edgescroll edge=\(step.rawValue)")
    }

    public func consumePendingListScroll() -> Int64? {
        let day = pendingListScrollDay
        pendingListScrollDay = nil
        return day
    }

    /// M2.18f: der erste Termin ab diesem Tag wird ausgewählt („Heute" in der
    /// Liste und der Sprung aus der Jahresansicht). Ausgewertet nach dem
    /// nächsten Laden in `applyPendingListSelection`.
    public private(set) var pendingListSelectDay: Int64?

    /// Wählt den ersten Termin, der an diesem Tag noch läuft oder danach
    /// beginnt — dieselbe Reihenfolge wie `↑`/`↓`.
    public func selectFirstEvent(from day: Int64) {
        pendingListSelectDay = math.startOfDay(day)
        applyPendingListSelection()
    }

    private func applyPendingListSelection() {
        guard let day = pendingListSelectDay else { return }
        pendingListSelectDay = nil
        let ordered = navigationOrder()
        guard let first = ordered.first(where: { CalendarEventRules.eventEnd($0) > day }) else {
            PerfLog.shared.write("calendar_list_select day=\(day) none")
            return
        }
        selectedEventId = first.id
        if cardIsOpen, draft == nil { openCard(first.id) }
        PerfLog.shared.write("calendar_list_select day=\(day) id=\(first.id) start=\(first.startsAt)")
    }

    /// „Antwort offen“ (M2.17 §3): gilt für Einladungen, bei denen der Nutzer
    /// Teilnehmer ist und noch nicht geantwortet hat.
    public func needsResponse(_ event: CalendarEvent) -> Bool {
        CalendarPermissions.needsResponse(event, ownEmails: ownEmails)
    }

    // MARK: Loading

    public func loadCalendars() async {
        guard let client else { return }
        do { calendars = try await client.listCalendars(accountId: nil) } catch { toasts.error(error) }
    }

    /// M2.18 §5: Der Kern liefert alle Wiederholungen einer Serie mit derselben
    /// Kennung. Für Anzeige und Auswahl bekommt jede ihre eigene (negativ,
    /// aus Kern-Kennung und Beginn gerechnet).
    static func labelled(_ rows: [CalendarEvent]) -> [CalendarEvent] {
        rows.map { $0.taggedAsSeriesOccurrence() }
    }

    /// Fetches the visible range and rebuilds the grid model.
    public func refresh() async {
        guard let client, !loading else { return }
        loading = true
        defer { loading = false }
        let range = self.range
        do {
            let fetchStarted = Date()
            let rows = try await client.listEvents(startMs: range.start, endMs: range.end)
            lastFetchMilliseconds = Date().timeIntervalSince(fetchStarted) * 1000
            events = Self.labelled(rows)
            loaded = true
            // M2.13 §8.5: der Messpunkt für „Jahr in einem Zug laden“.
            if mode == .year {
                PerfLog.shared.write("calendar_year_load ms=\(String(format: "%.1f", lastFetchMilliseconds)) "
                                     + "events=\(rows.count) days=\(days.count)")
            }
        } catch {
            toasts.error(error)
            return
        }
        rebuildWeekModel()
        applyPendingSelection()
        applyPendingListSelection()
    }

    /// Nach dem Blättern am Rand (M2.12): der erste bzw. letzte Termin der neuen
    /// Seite wird gewählt, eine offene Karte wandert mit.
    private func applyPendingSelection() {
        guard let pending = pendingSelection else { return }
        pendingSelection = nil
        let ordered = navigationOrder()
        let target = pending == .first ? ordered.first : ordered.last
        guard let id = target?.id else { selectedEventId = nil; return }
        selectedEventId = id
        if cardIsOpen, draft == nil { openCard(id) }
        PerfLog.shared.write("calendar_navigate_after_page id=\(id) mode=\(mode.rawValue)")
    }

    /// Recomputes the day/week layout. The signpost interval is the measurement
    /// for the "week switch under 50 ms" requirement; `PerfLog` keeps the number
    /// in the same log file as the host's timings.
    public func rebuildWeekModel() {
        guard mode != .month else { weekModel = nil; return }
        let days = self.days
        let events = self.visibleEvents
        let math = self.math
        let state = Self.signposter.beginInterval("week_switch")
        let started = Date()
        let model = CalendarWeekModel.build(events: events, days: days, math: math)
        Self.signposter.endInterval("week_switch", state)
        weekModel = model
        let ms = Date().timeIntervalSince(started) * 1000
        lastLayoutMilliseconds = ms
        PerfLog.shared.write("calendar_layout ms=\(String(format: "%.2f", ms)) days=\(days.count) events=\(events.count)")
    }

    /// Called by the settings window once the settings object is loaded.
    public func weekStartChanged() {
        guard mode != .month else { return }
        refreshAfterNavigation()
    }

    // MARK: Navigation (Tauri: `-` / `=` / `t` / `d` / `w` / `m`)

    public func go(to day: Int64) {
        anchor = math.startOfDay(day)
        refreshAfterNavigation()
    }

    public func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        // M2.17 §1: die Suche gehört zur Liste; wer die Ansicht verlässt,
        // schließt sie (das Feld wäre im Raster nicht mehr erreichbar).
        if mode != .list {
            searchOpen = false
            searchText = ""
        } else if let target = pendingListScrollDay {
            // M2.17 §5: die Liste zentriert sich auf den gewählten Tag, damit
            // der Sprung auch bei einem Tag außerhalb des Fensters ankommt.
            anchor = math.startOfDay(target)
        }
        // M2.17 §2: das nachgeladene Fenster gilt nur für die Liste.
        if self.mode == .list && mode != .list {
            listWindowBack = CalendarStore.listDaysBack
            listWindowForward = CalendarStore.listDaysForward
        }
        let previous = self.mode
        // M2.18f: das **gewählte** Datum wandert mit. Im Jahr ist das der
        // gewählte Tag, in der Liste der ausgewählte Termin; sonst bleibt der
        // Anker stehen. Vorher sprang der Wechsel nach Jahr/Liste auf heute.
        switch previous {
        case .year:
            anchor = math.startOfDay(selectedDayOrToday)
        case .list:
            if let event = selectedEvent { anchor = math.startOfDay(event.startsAt) }
        default:
            break
        }
        // M2.18h: Die Jahresansicht öffnet auf dem **gewählten** Datum, nicht
        // auf heute. `yearDays` hängt am Anker, und der Kreis hängt an
        // `selectedDay` — beide werden hier gesetzt, damit Jahr und Markierung
        // zusammenpassen (vorher: Jahr des Ankers, Kreis auf heute oder gar
        // keiner, wenn heute in einem anderen Jahr lag).
        if mode == .year {
            let day = chosenDay
            anchor = day
            selectedDay = day
            let year = math.calendar.component(.year, from: math.date(day))
            PerfLog.shared.write("calendar_year_open year=\(year) day=\(day)")
        }
        self.mode = mode
        // M2.18f: beim Wechsel **in** die Liste wird der erste Termin ab dem
        // gewählten Tag ausgewählt — sonst zeigte sie die alte Auswahl aus einer
        // anderen Ansicht und scrollte dorthin statt zum Datum.
        if mode == .list { pendingListSelectDay = math.startOfDay(anchor) }
        PerfLog.shared.write("calendar_mode from=\(previous.rawValue) to=\(mode.rawValue) "
                             + "anchorDay=\(math.dayOfMonth(anchor)) selDay=\(math.dayOfMonth(selectedDayOrToday))")
        refreshAfterNavigation()
    }

    /// One page back/forward: a day, a week or a month.
    public func page(_ delta: Int) {
        switch mode {
        case .day: anchor = math.addDays(anchor, delta)
        case .week: anchor = math.addDays(anchor, delta * 7)
        case .month: anchor = math.addMonths(math.startOfMonth(anchor), delta)
        case .year: anchor = math.addMonths(anchor, delta * 12)
        case .list: anchor = math.addDays(anchor, delta * 30)
        }
        if mode == .year || mode == .list { selectedDay = anchor }
        refreshAfterNavigation()
    }

    public func jumpToToday() {
        let today = math.startOfDay(Int64(Date().timeIntervalSince1970 * 1000))
        anchor = today
        selectedDay = today
        // M2.18f: in der Liste muss „Heute" auch etwas auswählen, sonst
        // passiert sichtbar nichts (der Anker allein scrollt nicht). Sind die
        // Termine noch nicht geladen, greift der Merker nach dem Laden.
        if mode == .list { selectFirstEvent(from: today) }
        PerfLog.shared.write("calendar_today mode=\(mode.rawValue) day=\(today)")
        refreshAfterNavigation()
    }

    /// The heading of `CalendarScreen.tsx` ("Juli 2026", "29. Juni – 5. Juli 2026").
    public func heading() -> String {
        let days = self.days
        func format(_ ms: Int64, _ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Format.locale
            formatter.timeZone = .current
            formatter.dateFormat = pattern
            return formatter.string(from: math.date(ms))
        }
        switch mode {
        case .day:
            return format(anchor, "EEEE, d. MMMM yyyy")
        case .month:
            return format(math.startOfMonth(anchor), "LLLL yyyy")
        case .year:
            return format(anchor, "yyyy")
        case .list:
            if math.startOfDay(anchor) == todayStart { return "Ab heute" }
            return "Ab " + format(anchor, "d. MMM yyyy")
        case .week:
            guard let first = days.first, let last = days.last else { return "" }
            if math.monthIndex(first) == math.monthIndex(last) {
                return format(first, "LLLL yyyy")
            }
            let sameYear = math.calendar.component(.year, from: math.date(first))
                == math.calendar.component(.year, from: math.date(last))
            return "\(format(first, sameYear ? "MMM" : "MMM yyyy")) – \(format(last, "MMM yyyy"))"
        }
    }

    private func refreshAfterNavigation() {
        weekModel = nil
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    // MARK: Writes

    @discardableResult
    public func create(_ args: CreateEventArgs) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let event = try await client.createEvent(args)
            await refresh()
            let invites = event.attendees.count
            toasts.show(invites > 0
                        ? "Termin erstellt, Einladung an \(invites) Teilnehmende wird gesendet"
                        : "Termin zum Kalender hinzugefügt")
            await syncQuietly(force: true)
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func update(_ args: UpdateEventArgs) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let event = try await client.updateEvent(args)
            await refresh()
            let invited = args.notify && !event.attendees.isEmpty
            toasts.show(invited ? "Termin aktualisiert, Änderung an Teilnehmende gemailt"
                                : "Termin aktualisiert")
            await syncQuietly(force: true)
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// M2.18 §6: Sichern einer **Wiederholung**. Der Kern kennt (noch) keinen
    /// Geltungsbereich; die App zeigt deshalb nur „Alle Termine der Serie".
    /// Dabei bleibt das Datum der Serie stehen: der Master übernimmt die
    /// Uhrzeit und die Dauer dieses Termins (`SeriesShift`).
    ///
    /// Dafür braucht die App den Beginn des Masters. Der Kern liefert
    /// Wiederholungen mit der Master-Kennung, aber ohne Master-Zeiten; die
    /// erste Wiederholung ab dem Serienbeginn ist der Master. Einmal je Sichern
    /// abgefragt, nicht im Hintergrund.
    @discardableResult
    public func updateSeriesOccurrence(_ event: CalendarEvent, args: UpdateEventArgs) async -> Bool {
        guard event.isSeriesOccurrence else { return await update(args) }
        var shifted = args
        // Bisheriger Beginn dieser Wiederholung: der Eintrag selbst.
        let occurrenceStart = event.startsAt
        if let masterStart = await seriesStart(eventId: event.eventId, beforeOrAt: occurrenceStart) {
            let times = SeriesShift.master(start: masterStart,
                                           chosenStart: args.startsAt, chosenEnd: args.endsAt,
                                           math: math)
            shifted.startsAt = times.start
            shifted.endsAt = times.end
            PerfLog.shared.write("calendar_series_edit event=\(event.eventId) "
                                 + "master=\(masterStart) chosen=\(args.startsAt) "
                                 + "shifted=\(times.start) scope=all")
        } else {
            PerfLog.shared.write("calendar_series_edit event=\(event.eventId) master=unknown")
        }
        return await update(shifted)
    }

    /// Beginn der Serie (der Master), nicht später als `limit`. Fragt die
    /// Wiederholungen ab Serienbeginn ab; die früheste ist der Master.
    private func seriesStart(eventId: Int64, beforeOrAt limit: Int64) async -> Int64? {
        guard let client else { return nil }
        guard let rows = try? await client.listEvents(startMs: 0, endMs: limit + 1) else { return nil }
        return rows.filter { $0.id == eventId }.map(\.startsAt).min()
    }

    /// Drag move/resize: the event's fields with new times.
    ///
    /// K4 aus dem Audit M2: with attendees the core mails an update to everybody
    /// on `notify: true`. A drag is easy to trigger, so the event moves quietly
    /// first and the mail is a separate, explicit click.
    @discardableResult
    public func move(_ event: CalendarEvent, startsAt: Int64, endsAt: Int64) async -> Bool {
        let attendees = event.attendees.count
        let args = UpdateEventArgs(event, startsAt: startsAt, endsAt: endsAt, notify: attendees == 0)
        let moved = event.isSeriesOccurrence
            ? await updateSeriesOccurrence(event, args: args)
            : await update(args)
        guard moved, attendees > 0 else { return moved }
        let mailArgs = UpdateEventArgs(event, startsAt: startsAt, endsAt: endsAt, notify: true)
        let text = attendees == 1
            ? "Termin verschoben. Änderung an 1 Teilnehmenden mailen?"
            : "Termin verschoben. Änderung an \(attendees) Teilnehmende mailen?"
        toasts.show(text, actionTitle: "Mailen", duration: 8) { [weak self] in
            guard let self else { return }
            Task {
                if event.isSeriesOccurrence {
                    await self.updateSeriesOccurrence(event, args: mailArgs)
                } else {
                    await self.update(mailArgs)
                }
            }
        }
        PerfLog.shared.write("event_notify_ask n=\(attendees)")
        return moved
    }

    /// Deletes an event after the UI confirmed it. For an event we created
    /// without attendees the toast offers undo; the core has no event trash, so
    /// the undo re-creates it (with a new id) instead of restoring rows.
    public func delete(_ event: CalendarEvent) async {
        guard let client, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.deleteEvent(event.eventId, notify: true)
            // Alle Wiederholungen dieser Serie verschwinden mit (M2.18 §5).
            events.removeAll { $0.eventId == event.eventId }
            rebuildWeekModel()
            let invited = canEdit(event) && !event.attendees.isEmpty
            let text: String
            if event.isSeriesOccurrence {
                text = invited
                    ? "Serie abgesagt, Absage an \(event.attendees.count) Teilnehmende gemailt"
                    : "Alle Termine der Serie gelöscht"
            } else {
                text = invited
                    ? "Termin abgesagt, Absage an \(event.attendees.count) Teilnehmende gemailt"
                    : "Termin gelöscht"
            }
            if !event.isSeriesOccurrence, canEdit(event), event.attendees.isEmpty {
                toasts.show(text, actionTitle: Strings.undo) { [weak self] in
                    guard let self else { return }
                    Task { await self.recreate(event) }
                }
            } else {
                toasts.show(text)
            }
            await syncQuietly(force: true)
        } catch {
            toasts.error(error)
        }
    }

    /// Undo of a deletion: a fresh local event with the same fields. Nobody is
    /// emailed again (the original had no attendees).
    private func recreate(_ event: CalendarEvent) async {
        guard let client else { return }
        let args = CreateEventArgs(
            accountId: event.accountId, calendarId: event.calendarId, summary: event.summary ?? "",
            description: event.description, location: event.location, joinUrl: event.joinUrl,
            startsAt: event.startsAt, endsAt: CalendarEventRules.eventEnd(event),
            allDay: event.allDay, attendees: [])
        do {
            _ = try await client.createEvent(args)
            await refresh()
            toasts.show("Termin wiederhergestellt")
        } catch {
            toasts.error(error)
        }
    }

    // MARK: Invites in the thread (requirement 4)

    public func loadMessageEvents(_ messageId: Int64) async {
        guard let client, messageEvents[messageId] == nil else { return }
        do { messageEvents[messageId] = try await client.eventsForMessage(messageId) } catch {
            messageEvents[messageId] = []
            toasts.error(error)
        }
    }

    @discardableResult
    public func rsvp(_ event: CalendarEvent, response: RsvpResponse) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let updated = try await client.rsvpEvent(event.eventId, response: response)
            if let messageId = event.messageId, let rows = messageEvents[messageId] {
                messageEvents[messageId] = rows.map { $0.id == updated.id ? updated : $0 }
            }
            if event.isSeriesOccurrence {
                await refresh()
            } else {
                events = events.map { $0.id == updated.id ? updated : $0 }
                rebuildWeekModel()
            }
            let text: String = switch response {
            case .accepted: "Zugesagt, Antwort an die einladende Person gesendet"
            case .tentative: "Mit Vorbehalt zugesagt, Antwort an die einladende Person gesendet"
            case .declined: "Abgesagt, Antwort an die einladende Person gesendet"
            }
            toasts.show(text)
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    // MARK: Calendar settings (requirement 5)

    @discardableResult
    public func setCalendarEnabled(_ id: Int64, enabled: Bool) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.setCalendarEnabled(id, enabled: enabled)
            await loadCalendars()
            await refresh()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func setCalendarColor(_ id: Int64, color: String?) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.setCalendarColor(id, color: color)
            await loadCalendars()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func setDefaultCalendar(_ id: Int64) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.setDefaultCalendar(id)
            await loadCalendars()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func syncNow() async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        lastSyncUnconfirmed = false
        let before = lastSyncAt
        do {
            try await client.calendarSyncNow(accountId: nil)
            await loadCalendars()
            guard !calendars.isEmpty else {
                toasts.show("Kein Kalender verbunden.")
                return true
            }
            let confirmed = await waitForSync(after: before)
            lastSyncUnconfirmed = !confirmed
            toasts.show(confirmed
                        ? "Abgleich abgeschlossen"
                        : "Abgleich angefordert – noch nicht bestätigt. Bleibt der Zeitstempel alt: "
                            + "Server und App-Passwort prüfen (Konto verbinden).")
            await refresh()
            return confirmed
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// `calendar_sync_now` nudges the core's task and returns at once, so the
    /// only evidence of a real cycle is a moved `last_synced_at`. Six seconds
    /// are enough for a local server; the real instance's CalDAV server may be
    /// slower, which is why the wording says "nicht bestätigt" and not "failed".
    private func waitForSync(after before: Int64?) async -> Bool {
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(500))
            await loadCalendars()
            if let now = lastSyncAt, now > (before ?? -1) { return true }
        }
        return false
    }

    // MARK: Leiser Abgleich (M2.18 §7)

    /// Letzter leiser Abgleich (Öffnen, Fensteraktivierung).
    public private(set) var lastQuietSyncAt: Date?

    /// `calendar_sync_now`, ohne Toast und ohne auf die Bestätigung zu warten:
    /// beim Öffnen des Kalenders, wenn das Fenster aktiv wird (höchstens einmal
    /// pro Minute) und nach jedem eigenen Sichern.
    ///
    /// `refresh` im Anschluss holt, was der Kern inzwischen geschrieben hat; ein
    /// paar hundert Millisekunden Vorlauf geben dem Kerntask die Chance, den
    /// Abgleich zu beginnen.
    public func syncQuietly(force: Bool = false) async {
        guard let client, !connecting else { return }
        let now = Date()
        if !force, let last = lastQuietSyncAt, now.timeIntervalSince(last) < 60 { return }
        lastQuietSyncAt = now
        let before = lastSyncAt
        do {
            try await client.calendarSyncNow(accountId: nil)
            // Der Kerntask gleicht im Hintergrund ab; drei kurze Blicke auf den
            // Zeitstempel reichen für iCloud, ohne die Oberfläche zu blockieren.
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(700))
                await loadCalendars()
                if let after = lastSyncAt, after != before { break }
            }
            await refresh()
            PerfLog.shared.write("calendar_sync_quiet ok calendars=\(calendars.count) "
                                 + "forced=\(force ? 1 : 0) "
                                 + "moved=\(lastSyncAt != before ? 1 : 0)")
        } catch {
            // Kein Toast: der Nutzer hat den Abgleich nicht angefordert.
            PerfLog.shared.write("calendar_sync_quiet failed")
        }
    }

    // MARK: Connecting a CalDAV account (M2.12)

    /// `connect_calendar` with a server URL and an app password. The core runs
    /// discovery, stores the password in the keychain and returns the found
    /// collections; the app keeps no copy of the password.
    @discardableResult
    /// M2.15b (Audit): CalDAV nur über `https`; `http` bleibt dem lokalen Mock
    /// vorbehalten. Sonst ginge das App-Passwort unverschlüsselt über das Netz.
    public static func connectionProblem(_ server: String) -> String? {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Bitte eine Server-Adresse angeben." }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return "Bitte eine vollständige Adresse angeben, z. B. https://caldav.icloud.com."
        }
        if scheme == "https" { return nil }
        if scheme == "http" {
            let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
            return local ? nil
                : "Unverschlüsselt nur für localhost. Für iCloud bitte https:// verwenden."
        }
        return "Nur https:// wird unterstützt."
    }

    public func connectCalendar(accountId: Int64, server: String, username: String,
                                password: String) async -> Bool {
        guard let client else {
            connectError = "Der Kern läuft noch nicht."
            return false
        }
        if let problem = Self.connectionProblem(server) {
            connectError = problem
            PerfLog.shared.write("calendar_connect rejected reason=not_https")
            return false
        }
        guard !connecting else { return false }
        connecting = true
        connectError = nil
        connectNotice = nil
        defer { connecting = false }
        let started = Date()
        do {
            let found = try await client.connectCalendar(ConnectCalendarArgs(
                accountId: accountId, kind: "generic", url: server,
                username: username, password: password))
            await loadCalendars()
            await refresh()
            connectNotice = found.isEmpty
                ? "Verbunden, aber der Server meldet keine Kalender."
                : "Verbunden – \(found.count) Kalender gefunden. Der erste Abgleich läuft."
            PerfLog.shared.write("calendar_connect ok calendars=\(found.count) "
                                 + "ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            toasts.show(connectNotice ?? "")
            return true
        } catch {
            let mapped = CoraxClientError.from(error)
            connectError = Self.connectErrorMessage(mapped)
            PerfLog.shared.write("calendar_connect failed code=\(mapped.code) "
                                 + "ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return false
        }
    }

    /// Klartext für die Einstellungen: die generische Fehlertabelle kennt
    /// CalDAV nicht, und „NeedsReauth“ (HTTP 401) ist der häufigste Fall.
    static func connectErrorMessage(_ error: CoraxClientError) -> String {
        guard case let .core(code, message) = error else { return Strings.errorText(error) }
        switch code {
        case "auth", "needs_reauth":
            return "Anmeldung fehlgeschlagen – E-Mail-Adresse und App-Passwort prüfen."
        case "caldav":
            let detail = message.lowercased()
            if detail.contains("401") {
                return "Der Server hat die Anmeldung abgelehnt (HTTP 401). "
                    + "Prüfe E-Mail-Adresse und App-Passwort."
            }
            if detail.contains("connect") || detail.contains("refused") {
                return "Server nicht erreichbar. Prüfe die Adresse und deine Verbindung."
            }
            // Der Kern verschluckt Netzfehler in der Erkennung: ein toter Port,
            // eine falsche Adresse und ein Server ohne CalDAV enden alle in
            // „no current-user-principal found“. Also nicht „der Server meldet
            // einen Fehler“ behaupten, sondern das sagen, was zutrifft.
            if detail.contains("no current-user-principal") {
                return "Unter dieser Adresse wurde kein Kalender gefunden. "
                    + "Prüfe die Adresse (für iCloud https://caldav.icloud.com) "
                    + "und ob sie erreichbar ist."
            }
            return "Der Kalenderserver meldet einen Fehler: \(message)"
        case "offline":
            return "Du bist offline oder der Server ist nicht erreichbar."
        case "network":
            return "Der Server ist nicht erreichbar. Prüfe die Adresse und deine Verbindung."
        case "keyring":
            return "Das Passwort konnte nicht im Schlüsselbund gespeichert werden."
        default:
            return Strings.errorText(error)
        }
    }

    /// Beim Tippen in den Feldern: die alte Meldung soll nicht stehen bleiben.
    public func clearConnectFeedback() {
        connectError = nil
        connectNotice = nil
    }

    // MARK: Hiding

    public func toggleCalendar(_ id: Int64) {
        if hiddenCalendars.contains(id) { hiddenCalendars.remove(id) } else { hiddenCalendars.insert(id) }
        rebuildWeekModel()
    }

    public func toggleLocal() {
        hiddenLocal.toggle()
        rebuildWeekModel()
    }
}
