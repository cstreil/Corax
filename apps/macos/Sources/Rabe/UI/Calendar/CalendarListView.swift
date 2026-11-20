import AppKit
import SwiftUI
import RabeKit

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
                 store.selectedEventId, store.mode, store.anchor)
        AgendaTable(store: store, theme: theme, onDelete: onDelete)
            .background(theme.win.color)
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
        override func layout() {
            super.layout()
            onLayout?()
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
                DispatchQueue.main.async { self.scrollToRow(of: id) }
            }
            lastSelected = store.selectedEventId
            // M2.13 §8.4: die Liste öffnet bei heute, nicht am Anfang des
            // geladenen Fensters (30 Tage Kontext liegen darüber).
            if store.mode == .list, !didInitialScroll, !rows.isEmpty {
                didInitialScroll = true
                PerfLog.shared.write("calendar_list_initial rows=\(rows.count) "
                                     + "today=\(store.math.dayOfMonth(store.todayStart))")
                DispatchQueue.main.async { self.scrollToToday() }
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
        }

        func reload() {
            guard let table else { return }
            let open = store.openEventId
            rows = AgendaModel.rows(events: store.visibleEvents, days: store.listDays,
                                    openEvent: open, today: store.todayStart)
            lastOpenEvent = open
            lastSignature = Self.signature(rows: rows, store: store)
            table.reloadData()
            PerfLog.shared.write("calendar_list_reload rows=\(rows.count) mode=\(store.mode.rawValue)")
            if store.selectedEventId == nil {
                let first = rows.compactMap { row -> CalendarEvent? in
                    if case .event(let event) = row { return event }
                    return nil
                }.first { CalendarEventRules.eventEnd($0) > store.todayStart }
                if let first {
                    store.selectedEventId = first.id
                    DispatchQueue.main.async { self.scrollToRow(of: first.id) }
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
                                                 isOpen: event.id == store.openEventId))
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

        /// Springt auf die Gruppe von heute.
        func scrollToToday() {
            guard let table, let scroll else { return }
            let today = store.todayStart
            if let index = rows.firstIndex(where: { row in
                if case .day(let day) = row { return day >= today }
                return false
            }) {
                // `scrollRowToVisible` blieb wirkungslos (Sandbox-Lauf: minY
                // blieb oben), deshalb direkt in die Clip-Ansicht scrollen.
                let rowRect = table.rect(ofRow: index)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rowRect.minY - 62)))
                scroll.reflectScrolledClipView(scroll.contentView)
                PerfLog.shared.write("calendar_list_scroll index=\(index) rows=\(rows.count) "
                                     + "visible=\(Int(scroll.contentView.bounds.minY))")
            } else {
                PerfLog.shared.write("calendar_list_scroll none rows=\(rows.count)")
            }
        }

        func scrollToRow(of eventId: Int64) {
            guard let table else { return }
            guard let index = rows.firstIndex(where: {
                if case .event(let event) = $0 { return event.id == eventId }
                return false
            }) else { return }
            let rowRect = table.rect(ofRow: index)
            if let scroll {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rowRect.minY - 60)))
                scroll.reflectScrolledClipView(scroll.contentView)
                // M2.15b (2.3): Beleg, dass die Auswahl die Liste mitnimmt.
                PerfLog.shared.write("calendar_list_scroll_to id=\(eventId) row=\(index) "
                                     + "top=\(Int(scroll.contentView.bounds.minY))")
            }
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

    var body: some View {
        let color = CalendarChrome.color(for: event, calendars: calendars, theme: theme)
        let math = CalendarMath(weekStartsOn: .monday)
        let end = CalendarEventRules.eventEnd(event)
        // M2.15b (Audit): „Tag x von y" rechnet über den Kalender, nicht mit
        // festen 24 h (Zeitumstellung) — die Regel steht in RabeKit und ist
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
