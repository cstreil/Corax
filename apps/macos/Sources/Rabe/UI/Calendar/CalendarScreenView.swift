import RabeKit
import SwiftUI

/// Full calendar screen (Tauri `CalendarScreen`): the grid or month layout and
/// the one card an event opens in.
/// Reached with `2` or `m` from the mail list, `1`/`Esc` goes back.
///
/// M2.9 Stufe C: Anzeige und Bearbeiten liegen in der Karte **im** Raster; das
/// Popover und das Editor-Sheet von M2.8b sind weg (§7.3).
struct CalendarScreenView: View {
    private var model: AppModel { AppModel.shared }
    private var store: CalendarStore { model.calendar }
    @Environment(\.theme) private var theme
    @State private var focusRequest = 0
    /// "Löschen" from a context menu or `⌫`: one confirmation for every surface.
    @State private var pendingDelete: CalendarEvent?
    /// Single vs. double click from the hook (`calendar:click`), only so the
    /// walkthrough can reach the same decision the pointer makes.
    @State private var hookClicks = CalendarClickRouter()
    /// Esc while the card is open. Die Felder der Bearbeitung halten die Tastatur,
    /// ein lokaler Monitor ist der verlässliche Weg (M2.8b, §7.4).
    @State private var escapeMonitor: Any?

    var body: some View {
        // M2.9: Kopf und Seitenleiste liegen im Hauptfenster (gemeinsame
        // Werkzeugleiste, gemeinsame Seitenleiste); der Kalender ist nur noch
        // das Raster.
        //
        // Die GeometryReader-Grenze gibt dem Raster eine feste Höhe: ohne sie
        // nimmt der VStack aus Kopfzeile und ScrollView seine Idealhöhe
        // (24 Stunden à 56 pt) an und schiebt die Kopfzeile aus dem Fenster
        // (im Sandbox-Lauf gesehen).
        //
        // `ignoresSafeAreaEdges: []` bei den Hintergründen ist Pflicht: ein
        // `.background` dehnt sich sonst in die Safe Area aus und legt sich
        // über das Fensterband — die Kalender-Werkzeugleiste war dadurch
        // unsichtbar (die Fläche dort war `win` statt `bar`).
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background(theme.win.color, ignoresSafeAreaEdges: [])
                .background { catcher }
        }
        .background(theme.win.color, ignoresSafeAreaEdges: [])
        .task {
            store.settings = model.settings
            store.ownEmails = CalendarPermissions.ownAddresses(model.mailbox.accounts.map(\.email))
            await store.loadCalendars()
            if !store.loaded { await store.refresh() }
        }
        // M2.15b (2.2): Konten kommen asynchron; erst mit den eigenen Adressen
        // lässt sich „mein Termin" von „Einladung" unterscheiden.
        .onChange(of: model.mailbox.accounts.count, initial: true) { _, _ in
            store.ownEmails = CalendarPermissions.ownAddresses(model.mailbox.accounts.map(\.email))
        }
        .onReceive(NotificationCenter.default.publisher(for: .rabeCalendarNewEvent)) { _ in
            openNewEvent()
        }
        // Hook build only: one click on an event, fed in where a pointer click
        // would end up (M2.8b walkthrough without foreground). Lives on the
        // screen so it works in day, week and month alike.
        .onReceive(NotificationCenter.default.publisher(for: .rabeCalendarClick)) { note in
            guard let id = (note.userInfo?["id"] as? NSNumber)?.int64Value,
                  let event = store.visibleEvents.first(where: { $0.id == id }) else { return }
            store.selectedEventId = id
            PerfLog.shared.write("calendar_click id=\(id) mode=\(store.mode.rawValue) source=hook")
            // The same router the pointer uses: one click opens, two edit.
            hookClicks.click(String(id),
                             onOpen: { store.openCard(event.id) },
                             onEdit: { store.openCard(event.id, edit: true) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .rabeCalendarPrefill)) { note in
            let info = note.userInfo ?? [:]
            let startsAt = (info["startsAt"] as? NSNumber)?.int64Value
                ?? Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
            let endsAt = (info["endsAt"] as? NSNumber)?.int64Value ?? startsAt + 3_600_000
            let location = info["location"] as? String ?? ""
            store.beginDraft(CalendarEventDraft(
                startsAt: startsAt, endsAt: endsAt,
                allDay: info["allDay"] as? Bool ?? false,
                title: info["summary"] as? String,
                location: location.isEmpty ? nil : location))
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeEscapeMonitor() }
        .onChange(of: pendingDelete?.id) { _, id in
            PerfLog.shared.write("calendar_confirm event=\(id.map(String.init) ?? "-")")
        }
        .onChange(of: store.cardMode) { _, mode in
            PerfLog.shared.write("calendar_card_mode mode=\(mode.rawValue)")
            if mode == .edit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusRequest += 1 } }
        }
        // M2.12 requirement 7: after every close (Esc, ×, click into the grid)
        // the keyboard belongs to the grid again.
        .onChange(of: store.cardIsOpen) { _, open in
            guard !open else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusRequest += 1 }
            PerfLog.shared.write("calendar_card_focus_return")
        }
        .alert(pendingDelete.map { store.canEdit($0) } == true && !(pendingDelete?.attendees.isEmpty ?? true)
               ? "Diesen Termin absagen?" : "Diesen Termin löschen?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Abbrechen", role: .cancel) { pendingDelete = nil }
            Button("Löschen", role: .destructive) {
                guard let event = pendingDelete else { return }
                pendingDelete = nil
                store.closeCard()
                Task { await store.delete(event) }
                focusRequest += 1
            }
        } message: {
            Text(deleteMessage)
        }
    }

    /// Der Tastenempfänger des Rasters (`\(store.mode)`-unabhängig). In der
    /// Anzeige bleibt die Tastatur beim Raster — die Karte ist **kein** erster
    /// Responder; erst das Bearbeiten gibt sie an das Titelfeld (§7.4).
    private var catcher: CalendarKeyCatcher {
        // Dieselbe Auswertung wie im Monitor, damit es nur einen Weg gibt.
        CalendarKeyCatcher(onKey: { event in keyHandled(event) },
                           focusRequest: focusRequest)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.loaded && store.loading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Termine werden geladen …")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3.color)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Group {
                switch store.mode {
                case .month:
                    CalendarMonthView(store: store, onDelete: { pendingDelete = $0 })
                case .year:
                    // M2.13 §8.3: Klick wählt den Tag, Doppelklick oder ↵ öffnet
                    // ihn, der Monatsname öffnet den Monat.
                    CalendarYearView(store: store,
                                     onOpenDay: { day in
                                         store.selectDay(day)
                                         store.go(to: day)
                                         store.setMode(.day)
                                     },
                                     onOpenMonth: { month in
                                         store.go(to: month)
                                         store.setMode(.month)
                                     })
                case .list:
                    CalendarListView(store: store, onDelete: { pendingDelete = $0 })
                case .day, .week:
                    CalendarTimeGridView(store: store, onDelete: { pendingDelete = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Esc und `↑`/`↓` bei offener Karte. Beim Bearbeiten hält ein Feld die
    /// Tastatur, deshalb läuft die Kette hier statt im Tastenempfänger:
    /// Bearbeiten → Anzeige → geschlossen (§7.4).
    ///
    /// `↑`/`↓` gehören hierher und nicht nur in den `CalendarKeyCatcher`: die
    /// Karte liegt als Overlay über dem Raster und nimmt den Fokus, der
    /// Tastenempfänger bekam die Pfeile dadurch nicht mehr (Sandbox-Lauf).
    private func installKeyMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.title == Instance.title else { return event }
            if event.keyCode == 53 {
                guard store.cardIsOpen else { return event }
                PerfLog.shared.write("calendar_escape source=monitor mode=\(store.cardMode.rawValue)")
                // M2.12: eine Entscheidung für Monitor und Test (`escapeAction`):
                // Bearbeiten → Anzeige, Anzeige → Karte zu. Ohne Karte lässt der
                // Monitor die Taste weiter zum Raster („zurück zur Liste“).
                switch store.escapeAction() {
                case .cancelEdit: store.cancelEdit()
                case .closeCard: store.closeCard()
                case .leaveCalendar: return event
                }
                focusRequest += 1
                return nil
            }
            // Ab hier: keine Karte im Bearbeiten-Modus und kein Textfeld —
            // sonst gehört die Taste dem Feld (Titel, Suche, Datum).
            let responder = event.window?.firstResponder
            if responder is NSText || responder is NSTextView { return event }
            guard store.cardMode == .view else { return event }
            if model.shortcutsOpen || model.paletteOpen || event.window?.attachedSheet != nil {
                return event
            }
            // M2.13: alle Tasten laufen über denselben Handler wie im
            // `CalendarKeyCatcher`. Der Monitor ist der verlässliche Weg: nach
            // einem Ansichtswechsel (Jahr, Liste) hält der ScrollView den Fokus,
            // und der Empfänger bekäme die Einzeltasten nie (Sandbox-Lauf).
            return keyHandled(event) ? nil : event
        }
    }

    /// Ein Aufruf `CalendarKeyboard.handle` mit den Aktionen dieses Bildschirms.
    private func keyHandled(_ event: NSEvent) -> Bool {
        CalendarKeyboard.handle(
            event, store: store,
            openNew: { openNewEvent() },
            openCard: { store.openCard($0.id) },
            editCard: { store.editOpenCard() },
            saveCard: { store.requestSave() },
            deleteSelected: { pendingDelete = $0 },
            joinMeeting: { join($0) },
            close: { model.calendarOpen = false; model.mailbox.focusList() })
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    private func join(_ event: CalendarEvent) {
        guard let url = MeetingLink.url(event.joinUrl) else { return }
        PerfLog.shared.write("calendar_join id=\(event.id)")
        model.platform.open(url)
    }

    private var deleteMessage: String {
        guard let event = pendingDelete else { return "" }
        if store.canEdit(event) && !event.attendees.isEmpty {
            return "\(event.attendees.count) Teilnehmende erhalten eine Absage per E-Mail."
        }
        if !store.canEdit(event) {
            return "Der Termin verschwindet aus dem Kalender. Niemand wird benachrichtigt."
        }
        return "Der Termin wird gelöscht. Das lässt sich rückgängig machen, solange der Hinweis sichtbar ist."
    }

    /// `B` bzw. der Knopf: derselbe Weg wie ein Klick auf freie Fläche — ein
    /// gestrichelter Platzhalter und die Karte im Bearbeiten-Modus.
    private func openNewEvent() {
        // M2.15b: In Jahr und Liste gibt es keinen Platz für den gestrichelten
        // Platzhalter und die Karte — dort tat „Neuer Termin" deshalb nichts.
        // Der Tag des Ankers wird im Tagesraster geöffnet (Architekt: Coder 1
        // hat das im Sandbox-Lauf bemerkt).
        if store.mode == .year || store.mode == .list {
            store.setMode(.day)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let base = store.math.startOfDay(store.anchor)
        let start: Int64
        if store.math.isSameDay(base, now) {
            start = store.math.at(base, hour: store.math.hour(now), minute: 0) + 3_600_000
        } else {
            start = store.math.at(base, hour: 9)
        }
        store.beginDraft(CalendarEventDraft(startsAt: start, endsAt: start + 30 * 60_000))
    }
}
