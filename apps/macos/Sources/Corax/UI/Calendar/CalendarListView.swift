import AppKit
import SwiftUI
import CoraxKit

/// M2.13 §8.4: Terminliste als `NSTableView` — gleiche Bausteine wie die
/// Mailliste (feste Zeilenhöhen, Band als eigene Zeile mit gemessener Höhe,
/// Scrollregel `ListReveal.revealTop`).
///
/// Die Tastatur läuft **nicht** durch die Tabelle, sondern wie im Raster durch
/// den Tastenempfänger des Kalenders (`CalendarKeyboard`): so gibt es nur einen
/// Weg für `↵`, `Esc`, `⌫` und die Auswahl.
struct CalendarListView: View {
    let store: CalendarStore
    var onDelete: (CalendarEvent) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        // `CalendarStore` ist `@Observable`: SwiftUI zeichnet nur neu, wenn der
        // Body die Felder auch liest. Ohne diese Zeile blieb die Tabelle beim
        // alten Stand stehen (Sandbox-Lauf: kein Sprung zu heute, neue Termine
        // fehlten bis zum nächsten Ansichtswechsel).
        let _ = (store.loaded, store.events.count, store.openEventId,
                 store.selectedEventId, store.mode, store.anchor,
                 store.searchOpen, store.searchText, store.pendingListScrollDay)
        VStack(spacing: 0) {
            // M2.17 §1: `/` legt das Suchfeld über die Liste; Esc leert und
            // schließt es wieder.
            if store.searchOpen {
                CalendarSearchBar(store: store)
                Rectangle().fill(theme.line.color).frame(height: 1)
            }
            AgendaTable(store: store, theme: theme, onDelete: onDelete)
        }
        .background(theme.win.color)
    }
}

/// M2.17 §1: das Suchfeld der Terminliste. Es filtert clientseitig (der Kern
/// hat keine Terminsuche) über Titel, Ort, Beschreibung und Teilnehmende.
private struct CalendarSearchBar: View {
    @Bindable var store: CalendarStore
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.ink3.color)
            TextField("Termine durchsuchen", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .focused($focused)
                .onChange(of: store.searchText) { _, _ in store.searchChanged() }
                // Esc im Feld leert und schließt; der Monitor des Bildschirms
                // nimmt dieselbe Taste, falls das Feld sie nicht bekommt.
                .onExitCommand { store.closeSearch() }
                .onSubmit { store.searchChanged() }
            if store.isSearching {
                Text("\(store.searchResults.count) Treffer")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.ink3.color)
            }
            Text("Esc")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.hover.color))
                .foregroundStyle(theme.ink3.color)
                .help("Suche schließen")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .onAppear {
            // M2.17: der Cursor steht sofort im Feld — `/` tippen, lostippen.
            DispatchQueue.main.async { focused = true }
            PerfLog.shared.write("calendar_search_field visible=1")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Termine durchsuchen")
    }
}

// MARK: - Tabelle

private struct AgendaTable: NSViewRepresentable {
    let store: CalendarStore
    let theme: Theme
    let onDelete: (CalendarEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, theme: theme, onDelete: onDelete)
    }

    /// M2.13: die Spalte muss der Fensterbreite folgen; ohne das blieb rechts
    /// ein leerer Streifen (im Sandbox-Foto gesehen).
    final class AgendaScroll: NSScrollView {
        var onLayout: (() -> Void)?
        /// M2.17 §2: wird bei jeder Scrollbewegung gerufen (Nachladen am Rand).
        var onScroll: (() -> Void)?
        override func layout() {
            super.layout()
            onLayout?()
        }
        override func reflectScrolledClipView(_ cView: NSClipView) {
            super.reflectScrolledClipView(cView)
            onScroll?()
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.rowClicked(_:))

        let scroll = AgendaScroll()
        scroll.onLayout = { [weak table] in
            guard let table, let scroll = table.enclosingScrollView else { return }
            let width = scroll.contentSize.width
            if width > 0, abs((table.tableColumns.first?.width ?? 0) - width) > 0.5 {
                table.tableColumns.first?.width = width
            }
        }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        scroll.onScroll = { [weak coordinator = context.coordinator] in
            coordinator?.scrollChanged()
        }
        context.coordinator.reload()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(store: store, theme: theme, onDelete: onDelete)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        private(set) var store: CalendarStore
        private var theme: Theme
        private var onDelete: (CalendarEvent) -> Void
        weak var table: NSTableView?
        weak var scroll: NSScrollView?

        private(set) var rows: [AgendaRow] = []
        private var bandHeights: [Int64: CGFloat] = [:]
        private var lastSignature = ""
        private var lastOpenEvent: Int64?
        private var lastSelected: Int64?
        private var didInitialScroll = false
        /// M2.17 §2: drosselt das Nachladen, damit eine Scrollbewegung nicht
        /// mehrere Abrufe startet.
        private var lastLoadAttempt = Date.distantPast
        /// M2.17 §1: bei jedem neuen Suchtext einmal zum ersten Treffer.
        private var lastSearchText = ""
        /// M2.17 §2: direkt nach einem Neuaufbau nicht sofort nachladen.
        private var suppressEdgeUntil = Date.distantPast
        /// M2.17 §2: zuletzt ausgeführter `End`/`Home`-Sprung.
        private var lastEdgeRequest = 0

        init(store: CalendarStore, theme: Theme, onDelete: @escaping (CalendarEvent) -> Void) {
            self.store = store
            self.theme = theme
            self.onDelete = onDelete
        }

        func update(store: CalendarStore, theme: Theme, onDelete: @escaping (CalendarEvent) -> Void) {
            // Vor dem Neuaufbau merken: `reload` setzt `lastOpenEvent` selbst.
            let openBefore = lastOpenEvent
            let selectionBefore = lastSelected
            self.store = store
            self.onDelete = onDelete
            let themeChanged = theme.id != self.theme.id
            self.theme = theme
            let signature = Self.signature(rows: rows, store: store)
            if signature != lastSignature || themeChanged {
                reload()
            }
            // M2.15b (2.3): Auswahl und Band sichtbar halten. Ohne das sprang
            // `↑`/`↓` durch Termine außerhalb des Fensters, und `↵` öffnete
            // ein Band weiter oben oder unten (Sandbox-Problem des Nutzers).
            if store.openEventId != openBefore {
                if let id = store.openEventId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.revealBand(eventId: id, bandHeight: self.bandHeight(for: id))
                    }
                }
            } else if store.selectedEventId != selectionBefore, let id = store.selectedEventId {
                // M2.18f: die Auswahl wandert durch die Liste; gescrollt wird
                // erst, wenn sie aus dem Fenster läuft (wie in der Mailliste).
                DispatchQueue.main.async { self.revealSelection(eventId: id, reason: "select") }
            }
            lastSelected = store.selectedEventId
            // M2.17 §2: `End`/`Home` springen an den Rand; erst dort lädt der
            // Rand-Nachlader.
            if store.listEdgeRequest != lastEdgeRequest, let step = store.listEdgeTarget {
                lastEdgeRequest = store.listEdgeRequest
                DispatchQueue.main.async { self.scrollToEdge(step) }
            }
            // M2.17 §5: ein Tag aus der Jahresansicht gewinnt gegen „heute".
            if let day = store.consumePendingListScroll() {
                didInitialScroll = true
                DispatchQueue.main.async { self.revealEntry(preferredDay: day) }
            } else if store.mode == .list, store.isSearching {
                // M2.17 §1: bei jedem neuen Suchwort zum ersten Treffer, damit
                // die Liste nicht irgendwo im Fenster stehen bleibt.
                if store.searchText != lastSearchText {
                    lastSearchText = store.searchText
                    DispatchQueue.main.async { self.scrollToFirstEvent() }
                }
                didInitialScroll = true
            } else if store.mode == .list, !didInitialScroll, !rows.isEmpty {
                // M2.18f: die Liste öffnet am **gewählten** Tag (beim Start ist
                // das heute), nicht am Anfang des 30-Tage-Fensters.
                didInitialScroll = true
                PerfLog.shared.write("calendar_list_initial rows=\(rows.count) "
                                     + "anchorDay=\(store.math.dayOfMonth(store.anchor))")
                DispatchQueue.main.async { self.revealEntry() }
            }
        }

        private static func signature(rows: [AgendaRow], store: CalendarStore) -> String {
            let ids = rows.map { row -> String in
                switch row {
                case .day(let day): return "d\(day)"
                case .emptyDay(let day): return "e\(day)"
                case .event(let event):
                    return "v\(event.id):\(event.startsAt):\(event.summary ?? "")"
                case .band(let id): return "b\(id)"
                }
            }.joined(separator: ",")
            return ids + "|open=\(store.openEventId ?? -1)|sel=\(store.selectedEventId ?? -1)"
                + "|load=\(store.loaded)|err=\(store.visibleEvents.count)"
                + "|search=\(store.isSearching ? 1 : 0):\(store.searchText)"
                + "|window=\(store.listWindowBack)+\(store.listWindowForward)"
        }

        func reload() {
            guard let table else { return }
            let open = store.openEventId
            // M2.18f: der erste Aufbau der Liste läuft noch mit dem Fenster der
            // vorigen Ansicht (Woche = 68 Zeilen, Liste = 289). Wächst die Liste
            // danach, verschieben sich alle Zeilenindizes und die Auswahl steht
            // außerhalb des Fensters — dann muss sie erneut gezeigt werden.
            let selectedRowBefore = store.selectedEventId.flatMap { rowIndex(of: $0) }
            // M2.17 §1: die Suche zeigt nur Treffer, an ihrem Starttag.
            rows = store.isSearching
                ? AgendaModel.searchRows(events: store.searchResults, openEvent: open,
                                         math: store.math)
                : AgendaModel.rows(events: store.visibleEvents, days: store.listDays,
                                   openEvent: open, today: store.todayStart)
            lastOpenEvent = open
            lastSignature = Self.signature(rows: rows, store: store)
            table.reloadData()
            suppressEdgeUntil = Date().addingTimeInterval(0.6)
            PerfLog.shared.write("calendar_list_reload rows=\(rows.count) mode=\(store.mode.rawValue) "
                                 + "search=\(store.isSearching ? 1 : 0)")
            // M2.18f: nach einem Aufbau mit anderer Zeilenzahl die Auswahl
            // wieder ins Fenster holen (nur wenn sie wirklich draußen steht —
            // `revealSelection` scrollt sonst nicht).
            if let id = store.selectedEventId, rowIndex(of: id) != selectedRowBefore {
                DispatchQueue.main.async { self.revealSelection(eventId: id, reason: "rebuild", topAlign: true) }
            }
            if store.selectedEventId == nil, !store.isSearching {
                let from = store.math.startOfDay(store.anchor)
                let first = rows.compactMap { row -> CalendarEvent? in
                    if case .event(let event) = row { return event }
                    return nil
                }.first { CalendarEventRules.eventEnd($0) > from }
                if let first {
                    store.selectedEventId = first.id
                    DispatchQueue.main.async { self.revealSelection(eventId: first.id, reason: "first", topAlign: true) }
                }
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rows[row] {
            case .day: return 28
            case .emptyDay: return 30
            case .event: return 46
            case .band(let id): return max(1, bandHeights[id] ?? 120)
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let content: AnyView
            switch rows[row] {
            case .day(let day):
                content = AnyView(AgendaDayHeader(day: day, today: store.todayStart,
                                                  math: store.math, theme: theme))
            case .emptyDay:
                content = AnyView(Text("Keine Termine")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.vertical, 6))
            case .event(let event):
                let day = AgendaModel.day(of: rows[row], in: rows, at: row) ?? event.startsAt
                content = AnyView(AgendaEventRow(event: event, day: day,
                                                 calendars: store.calendars, theme: theme,
                                                 isSelected: event.id == store.selectedEventId,
                                                 isOpen: event.id == store.openEventId,
                                                 needsResponse: store.needsResponse(event)))
            case .band:
                content = AnyView(bandRow())
            }
            let host = (tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? NSHostingView<AnyView>)
                ?? {
                    let view = NSHostingView(rootView: content)
                    view.identifier = .init("cell")
                    return view
                }()
            host.rootView = content
            return host
        }

        private func bandRow() -> some View {
            CalendarEventCard(store: store, layout: .band,
                              onClose: { self.store.closeCard() },
                              onDelete: { self.onDelete($0) })
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard let id = self.store.openEventId else { return }
                    let current = self.bandHeights[id] ?? 0
                    guard abs(height - current) > 0.5, height > 1 else { return }
                    self.bandHeights[id] = height
                    self.table?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
                    self.reloadRowsSafely()
                }
        }

        private func reloadRowsSafely() {
            guard let table else { return }
            let open = store.openEventId
            guard let index = rows.firstIndex(where: {
                if case .band(let id) = $0 { return id == open }
                return false
            }) else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }

        // MARK: Interaction

        @objc func rowClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            guard case .event(let event) = rows[row] else { return }
            store.selectedEventId = event.id
            if store.openEventId == event.id {
                store.closeCard()
            } else {
                store.openCard(event.id)
            }
        }

        // MARK: Reveal (M2.11-Regel)

        /// Scrollt so, dass das Band und eine Zeile darunter sichtbar sind.
        func revealBand(eventId: Int64, bandHeight: CGFloat) {
            guard let table, let scroll else { return }
            guard let eventRow = rows.firstIndex(where: {
                if case .event(let event) = $0 { return event.id == eventId }
                return false
            }) else { return }
            let bandRow = rows.firstIndex(where: {
                if case .band(let id) = $0 { return id == eventId }
                return false
            })
            let eventRect = table.rect(ofRow: eventRow)
            let aboveTop: CGFloat
            if eventRow > 0 { aboveTop = table.rect(ofRow: eventRow - 1).minY } else { aboveTop = eventRect.minY }
            let belowH: CGFloat
            if let bandRow, bandRow + 1 < rows.count {
                belowH = table.rect(ofRow: bandRow + 1).height
            } else if eventRow + 1 < rows.count {
                belowH = table.rect(ofRow: eventRow + 1).height
            } else {
                belowH = 0
            }
            let visible = scroll.contentView.bounds
            guard let top = ListReveal.revealTop(rowTop: eventRect.minY, aboveTop: aboveTop,
                                                 cardBottom: eventRect.maxY + bandHeight,
                                                 belowH: belowH, visibleMinY: visible.minY,
                                                 visibleHeight: visible.height) else {
                PerfLog.shared.write("calendar_list_band id=\(eventId) row=\(eventRow) need=0 "
                                     + "top=\(Int(visible.minY))")
                return
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
            PerfLog.shared.write("calendar_list_band id=\(eventId) row=\(eventRow) need=1 "
                                 + "top=\(Int(scroll.contentView.bounds.minY))")
        }

        /// Die Tagesgruppe über einer Terminzeile (für „Gruppe oben").
        private func dayRowIndex(above index: Int) -> Int? {
            var cursor = index
            while cursor > 0 {
                cursor -= 1
                if case .day = rows[cursor] { return cursor }
            }
            return nil
        }

        private func rowIndex(of eventId: Int64) -> Int? {
            rows.firstIndex(where: {
                if case .event(let event) = $0 { return event.id == eventId }
                return false
            })
        }

        /// M2.18f: beim Öffnen der Liste den **gewählten** Tag zeigen — die
        /// Auswahl, wenn eine im Fenster liegt, sonst die Tagesgruppe.
        func revealEntry(preferredDay: Int64? = nil) {
            if let id = store.selectedEventId, rowIndex(of: id) != nil {
                revealSelection(eventId: id, reason: "entry")
                return
            }
            scrollToDay(store.math.startOfDay(preferredDay ?? store.anchor))
        }

        /// M2.18f: die Auswahl wandert durch die Liste; gescrollt wird erst,
        /// wenn sie aus dem Fenster läuft — wie in der Mailliste. Vorher zog
        /// jeder Schritt die gewählte Zeile an eine feste Stelle, dadurch
        /// wirkte die Auswahl festgeklebt und die Liste rutschte darunter weg.
        func revealSelection(eventId: Int64, reason: String, topAlign: Bool = false,
                             attempt: Int = 0) {
            guard let table, let scroll, let index = rowIndex(of: eventId) else { return }
            let rowRect = table.rect(ofRow: index)
            // Direkt nach `reloadData` sind die Zeilenrechtecke noch leer; die
            // Regel würde dann „ist sichtbar" glauben. Kurz erneut versuchen.
            if rowRect.height < 2, attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    self?.revealSelection(eventId: eventId, reason: reason,
                                          topAlign: topAlign, attempt: attempt + 1)
                }
                return
            }
            // Beim Öffnen/Umbau steht die Tagesgruppe oben (wie „ab heute"),
            // beim Weiterschalten der Auswahl wird nur nachgeführt.
            if topAlign, let dayIndex = dayRowIndex(above: index) {
                let dayRect = table.rect(ofRow: dayIndex)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, dayRect.minY - 2)))
                scroll.reflectScrolledClipView(scroll.contentView)
                PerfLog.shared.write("calendar_list_reveal id=\(eventId) row=\(index) "
                                     + "why=\(reason) need=1 top=\(Int(scroll.contentView.bounds.minY))")
                return
            }
            let visible = scroll.contentView.bounds
            let margin: CGFloat = 6
            var target: CGFloat?
            if rowRect.minY < visible.minY + margin {
                // Oberkante: den Tagkopf darüber mitnehmen, damit die Gruppe
                // lesbar bleibt (wie die Zeile über der Mail bei `ListReveal`).
                target = rowRect.minY - margin
                if index > 0, case .day = rows[index - 1] {
                    target = table.rect(ofRow: index - 1).minY - 2
                }
            } else if rowRect.maxY > visible.maxY - margin {
                target = rowRect.maxY - visible.height + margin
            }
            guard let target else {
                PerfLog.shared.write("calendar_list_reveal id=\(eventId) row=\(index) "
                                     + "why=\(reason) need=0")
                return
            }
            let limit = max(0, table.bounds.height - visible.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, target), limit)))
            scroll.reflectScrolledClipView(scroll.contentView)
            PerfLog.shared.write("calendar_list_reveal id=\(eventId) row=\(index) "
                                 + "why=\(reason) need=1 top=\(Int(scroll.contentView.bounds.minY))")
        }

        /// M2.17 §2: am oberen oder unteren Rand einen 30-Tage-Block nachladen.
        /// Die Auswahl bleibt, weil `loadMoreList` weder Auswahl noch Anker
        /// anfasst.
        func scrollChanged() {
            guard store.mode == .list, !store.loadingMoreList, let scroll else { return }
            guard Date() >= suppressEdgeUntil else { return }
            guard Date().timeIntervalSince(lastLoadAttempt) > 0.4 else { return }
            let visible = scroll.contentView.bounds
            let height = scroll.documentView?.bounds.height ?? 0
            guard height > 0 else { return }
            if visible.minY <= 80, store.listWindowBack < CalendarStore.listMaxBack {
                lastLoadAttempt = Date()
                PerfLog.shared.write("calendar_list_edge edge=top back=\(store.listWindowBack)")
                Task { await store.loadMoreList(.earlier) }
            } else if visible.maxY >= height - 140,
                      store.listWindowForward < CalendarStore.listMaxForward {
                lastLoadAttempt = Date()
                PerfLog.shared.write("calendar_list_edge edge=bottom forward=\(store.listWindowForward)")
                Task { await store.loadMoreList(.later) }
            }
        }

        /// M2.17 §2: Sprung an den oberen bzw. unteren Rand der Liste.
        func scrollToEdge(_ step: CalendarStore.ListStep) {
            guard let scroll else { return }
            let visible = scroll.contentView.bounds
            let height = scroll.documentView?.bounds.height ?? 0
            guard height > visible.height else { return }
            let y = step == .later ? height - visible.height : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            PerfLog.shared.write("calendar_list_edge_scroll edge=\(step.rawValue) "
                                 + "top=\(Int(scroll.contentView.bounds.minY))")
        }

        /// M2.17 §5: die Liste springt auf die Tagesgruppe des gewählten Tags.
        func scrollToDay(_ day: Int64) {
            guard let table, let scroll else {
                PerfLog.shared.write("calendar_list_goto day=\(day) rows=0")
                return
            }
            let index = rows.firstIndex { row in
                if case .day(let d) = row { return d >= day }
                return false
            }
            guard let index else {
                PerfLog.shared.write("calendar_list_goto day=\(day) rows=\(rows.count) found=0")
                return
            }
            let rect = table.rect(ofRow: index)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 8)))
            scroll.reflectScrolledClipView(scroll.contentView)
            PerfLog.shared.write("calendar_list_goto day=\(day) row=\(index) rows=\(rows.count) "
                                 + "top=\(Int(scroll.contentView.bounds.minY))")
        }

        /// M2.17 §1: nach jedem Suchwort steht der erste Treffer oben.
        func scrollToFirstEvent() {
            guard let table, let scroll else { return }
            guard let index = rows.firstIndex(where: {
                if case .event = $0 { return true }
                return false
            }) else {
                PerfLog.shared.write("calendar_list_search_scroll rows=0")
                return
            }
            let rect = table.rect(ofRow: index)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 30)))
            scroll.reflectScrolledClipView(scroll.contentView)
            PerfLog.shared.write("calendar_list_search_scroll row=\(index) rows=\(rows.count) "
                                 + "top=\(Int(scroll.contentView.bounds.minY))")
        }

        func bandHeight(for eventId: Int64) -> CGFloat { bandHeights[eventId] ?? 120 }
    }
}

// MARK: - Zeilen

private struct AgendaDayHeader: View {
    let day: Int64
    let today: Int64
    let math: CalendarMath
    let theme: Theme

    var body: some View {
        let (label, isToday) = AgendaDayHeader.label(day: day, today: today, math: math)
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(isToday ? theme.accent.color : theme.ink3.color)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
        .background(theme.win.color)
    }

    static func label(day: Int64, today: Int64, math: CalendarMath) -> (String, Bool) {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        let date = Date(timeIntervalSince1970: Double(day) / 1000)
        if day == today { return ("HEUTE", true) }
        let yesterday = math.addDays(today, -1)
        let tomorrow = math.addDays(today, 1)
        formatter.dateFormat = "EEEE, d. MMMM"
        let base = formatter.string(from: date)
        if day == yesterday { return ("GESTERN · \(base)", false) }
        if day == tomorrow { return ("MORGEN · \(base)", false) }
        formatter.dateFormat = "EEEE, d. MMMM yyyy"
        return (formatter.string(from: date).uppercased(), false)
    }
}

private struct AgendaEventRow: View {
    let event: CalendarEvent
    let day: Int64
    let calendars: [CalendarCollection]
    let theme: Theme
    let isSelected: Bool
    let isOpen: Bool
    /// M2.17 §3: Einladung ohne Antwort.
    let needsResponse: Bool

    var body: some View {
        let color = CalendarChrome.color(for: event, calendars: calendars, theme: theme)
        let math = CalendarMath(weekStartsOn: .monday)
        let end = CalendarEventRules.eventEnd(event)
        // M2.15b (Audit): „Tag x von y" rechnet über den Kalender, nicht mit
        // festen 24 h (Zeitumstellung) — die Regel steht in CoraxKit und ist
        // dort geprüft.
        let dayLabel = CalendarEventRules.dayCountLabel(event, day: day, math: math)
        let past = end < Int64(Date().timeIntervalSince1970 * 1000)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary ?? "(kein Titel)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if event.allDay {
                        Text("ganztägig")
                    } else if let dayLabel {
                        Text(dayLabel)
                    } else {
                        Text(CalendarChrome.time(event.startsAt) + "–" + CalendarChrome.time(end))
                    }
                    if let location = event.location, !location.isEmpty {
                        Text("·")
                        Text(location).lineLimit(1)
                    }
                    // M2.17 §3: die Einladung wartet auf eine Antwort.
                    if needsResponse {
                        Text("·")
                        Text("Antwort offen")
                            .foregroundStyle(.orange)
                            .help("Einladung angenommen oder abgelehnt?")
                            .accessibilityLabel("Antwort offen")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            // M2.16: Der Upload ist gescheitert; die Karte nennt den Grund.
            if let reason = event.syncError, !reason.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Nicht hochgeladen: \(reason)")
                    .accessibilityLabel("Nicht hochgeladen: \(reason)")
            }
            if event.joinUrl != nil {
                Image(systemName: "video")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.ink3.color)
            }
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if isOpen || isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.sel.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
        }
        .opacity(past ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}
