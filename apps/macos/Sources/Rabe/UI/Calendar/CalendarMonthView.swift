import RabeKit
import SwiftUI

/// Month layout (`MonthView.tsx`): six week rows, all-day and multi-day events
/// as spanning bars, timed events as dot chips, "+N weitere" per day. Bars and
/// chips come from `CalendarMath.layoutMonthWeek`; the cell height only decides
/// how many lines fit, so a resize recomputes the layout once per row.
struct CalendarMonthView: View {
    let store: CalendarStore
    /// "Löschen …" from a context menu; the screen asks before it deletes.
    var onDelete: (CalendarEvent) -> Void = { _ in }
    @Environment(\.theme) private var theme
    /// M2.6: the day whose "+N weitere" card is open.
    @State private var dayList: Int64?
    /// Single vs. double click on a bar or chip (M2.8b).
    @State private var clicks = CalendarClickRouter()

    var body: some View {
        GeometryReader { proxy in
            let math = store.math
            let monthStart = math.startOfMonth(store.anchor)
            let month = math.monthIndex(monthStart)
            let cells = math.monthGridDays(store.anchor)
            let weeks = (0..<6).map { Array(cells[($0 * 7)..<($0 * 7 + 7)]) }
            // M2.9 §7.2: das Band unter der Woche des Termins schiebt die
            // übrigen Wochen zusammen, statt die Ansicht scrollen zu lassen.
            let bandHeight = bandHeight(in: proxy.size.height)
            let rowHeight = max(48, (proxy.size.height - bandHeight) / 6)
            let cap = max(1, Int((rowHeight - CalendarGrid.monthHeadPx - 2) / CalendarGrid.monthLinePx))
            let today = store.todayStart
            let bandWeek = bandWeekIndex(weeks: weeks)
            VStack(spacing: 0) {
                weekdayHeader(cells)
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    VStack(spacing: 0) {
                        weekRow(week, month: month, today: today, cap: cap, rowHeight: rowHeight,
                                index: index, math: math)
                        if index == bandWeek, bandHeight > 0 {
                            band(height: bandHeight)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rabeCalendarDayList)) { note in
            if let day = note.userInfo?["day"] as? Int64 { dayList = day }
        }
    }

    /// Höhe des Bands: 226 pt, aber nie mehr als die Ansicht hergibt (§7.2).
    private func bandHeight(in total: CGFloat) -> CGFloat {
        guard store.cardIsOpen else { return 0 }
        let room = total - 6 * 56
        return max(120, min(226, room))
    }

    /// Die Woche, unter der das Band steht: die des Termins (bzw. des neuen
    /// Entwurfs), sonst die letzte.
    private func bandWeekIndex(weeks: [[Int64]]) -> Int {
        let start = store.openEvent?.startsAt ?? store.draft?.startsAt
        guard let start else { return weeks.count - 1 }
        let day = store.math.startOfDay(start)
        for (index, week) in weeks.enumerated() where week.contains(day) { return index }
        return weeks.count - 1
    }

    /// Das Band: die Karte in zwei Spalten, unten bündig in der Woche (§7.2).
    private func band(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            CalendarEventCard(store: store, layout: .band,
                              onClose: {
                              PerfLog.shared.write("calendar_card_close_button")
                              store.closeCard()
                          },
                              onDelete: onDelete)
                .frame(height: height - 8, alignment: .top)
                .clipped()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(theme.bar.color.opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line.color).frame(height: 0.5)
        }
        .transition(.opacity)
    }

    private func weekdayHeader(_ cells: [Int64]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.prefix(7)), id: \.self) { day in
                let weekend = isWeekend(day)
                Text(CalendarChrome.weekdayShort(day))
                    .font(.system(size: 10.5, weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(theme.ink3.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(weekend ? theme.hover.color : Color.clear)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line.color).frame(height: 0.5)
        }
    }

    private func weekRow(_ week: [Int64], month: Int, today: Int64, cap: Int,
                         rowHeight: CGFloat, index: Int, math: CalendarMath) -> some View {
        let timed = store.visibleEvents
            .filter { !CalendarEventRules.isBar($0, math: math) }
            .sorted { $0.startsAt < $1.startsAt }
        let bars = store.visibleEvents.filter { CalendarEventRules.isBar($0, math: math) }
        let layout = CalendarMath.layoutMonthWeek(
            spans: CalendarMath.packSpans(bars, days: week),
            timed: CalendarEventRules.groupByDay(timed, days: week),
            days: week, cap: cap)
        return GeometryReader { proxy in
            let colWidth = proxy.size.width / 7
            ZStack(alignment: .topLeading) {
                // Background cells: seven real columns. (Before, every cell sat
                // at x = 0 and the day numbers piled up in the first column.)
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.element) { col, day in
                        dayCell(day, col: col, month: month, today: today, width: colWidth)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                ForEach(layout.bars) { span in
                    bar(span, colWidth: colWidth)
                        .offset(x: CGFloat(span.startCol) * colWidth + (span.clippedStart ? 0 : 4),
                                y: CalendarGrid.monthHeadPx + CGFloat(span.row) * CalendarGrid.monthLinePx + 1)
                }
                ForEach(Array(week.enumerated()), id: \.element) { col, day in
                    let column = layout.columns[col]
                    ForEach(Array(column.chips.enumerated()), id: \.element.id) { line, event in
                        chip(event, colWidth: colWidth)
                            .offset(x: CGFloat(col) * colWidth + 2,
                                    y: CalendarGrid.monthHeadPx
                                        + CGFloat(column.firstLine + line) * CalendarGrid.monthLinePx)
                    }
                    if column.hidden > 0 {
                        Button {
                            dayList = day
                        } label: {
                            Text("+\(column.hidden) weitere")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.ink3.color)
                                .padding(.leading, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Alle Termine dieses Tages anzeigen")
                        .popover(isPresented: Binding(get: { dayList == day },
                                                      set: { if !$0 { dayList = nil } }),
                                 arrowEdge: .bottom) {
                            DayListPopover(day: day, events: events(on: day), calendars: store.calendars,
                                           theme: theme,
                                           onOpen: { event in
                                               dayList = nil
                                               store.openCard(event.id)
                                           },
                                           onOpenDay: {
                                               dayList = nil
                                               store.go(to: day)
                                               store.setMode(.day)
                                           },
                                           onClose: { dayList = nil })
                        }
                        .offset(x: CGFloat(col) * colWidth + 2,
                                y: CalendarGrid.monthHeadPx
                                    + CGFloat(column.firstLine + column.chips.count) * CalendarGrid.monthLinePx)
                    }
                }
            }
        }
        .frame(height: rowHeight)
        .overlay(alignment: .top) {
            if index > 0 { Rectangle().fill(theme.line.color).frame(height: 0.5) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line.color).frame(height: 0.5)
        }
    }

    /// Every event of one day (all-day and multi-day included), for the card.
    private func events(on day: Int64) -> [CalendarEvent] {
        let end = day + CalendarGrid.dayMs
        return store.visibleEvents.filter { event in
            event.startsAt < end && CalendarEventRules.eventEnd(event) > day
        }
    }

    private func dayCell(_ day: Int64, col: Int, month: Int, today: Int64, width: CGFloat) -> some View {
        let inMonth = store.math.monthIndex(day) == month
        let weekend = isWeekend(day)
        let isToday = day == today
        return Button {
            // M2.12: eine offene Karte gibt der Tagesansicht Platz.
            if store.cardIsOpen { store.closeCard() }
            store.go(to: day)
            store.setMode(.day)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(CalendarChrome.dayNumber(day))")
                    .font(.system(size: 11.5, weight: isToday ? .semibold : .regular))
                    .foregroundStyle(isToday ? theme.accentInk.color
                                     : (inMonth ? theme.ink2.color : theme.ink3.color))
                    .frame(width: 20, height: 20)
                    .background {
                        if isToday { Circle().fill(theme.accent.color) }
                    }
                    .padding(.leading, 5)
                    .padding(.top, 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(weekend ? theme.hover.color.opacity(0.6)
                                : (inMonth ? Color.clear : theme.hover.color.opacity(0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .overlay(alignment: .leading) {
            if col > 0 { Rectangle().fill(theme.line.color).frame(width: 0.5) }
        }
        .contextMenu {
            Button("Neuer Termin an diesem Tag") {
                let start = store.math.at(day, hour: 9)
                store.beginDraft(CalendarEventDraft(startsAt: start, endsAt: start + 30 * 60_000))
            }
        }
        .help(CalendarChrome.longDay(day))
    }

    /// Width and hit area of one bar (the click area is exactly what is drawn;
    /// a tap area wider than the bar would open events from empty cell space).
    private func barWidth(_ span: EventSpan, colWidth: CGFloat) -> CGFloat {
        (CGFloat(span.endCol - span.startCol + 1) * colWidth)
            - (span.clippedStart ? 0 : 4) - (span.clippedEnd ? 0 : 4)
    }

    private func bar(_ span: EventSpan, colWidth: CGFloat) -> some View {
        let color = CalendarChrome.color(for: span.event, calendars: store.calendars, theme: theme)
        let cancelled = CalendarEventRules.isCancelled(span.event)
        return HStack(spacing: 3) {
                if !span.event.allDay && !span.clippedStart {
                    Text(CalendarChrome.time(span.event.startsAt))
                        .font(.system(size: 9.5).monospacedDigit())
                        .opacity(0.8)
                }
                Text(span.event.summary ?? "(kein Titel)")
                    .font(.system(size: 10.5, weight: .medium))
                    .strikethrough(cancelled)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
            .overlay(alignment: .leading) {
                if !span.clippedStart {
                    Rectangle().fill(color).frame(width: 3)
                }
            }
            .frame(width: barWidth(span, colWidth: colWidth), alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { clicked(span.event) }
            .contextMenu {
                EventContextMenu(store: store, event: span.event,
                                 onOpen: { store.openCard(span.event.id) },
                                 onEdit: { store.openCard(span.event.id, edit: true) },
                                 onDelete: { onDelete(span.event) })
            }
            .overlay {
                if store.openEventId == span.event.id || store.selectedEventId == span.event.id {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(color, lineWidth: store.openEventId == span.event.id ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
            }
            .help(span.event.summary ?? "")
    }

    private func chip(_ event: CalendarEvent, colWidth: CGFloat) -> some View {
        let color = CalendarChrome.color(for: event, calendars: store.calendars, theme: theme)
        let rsvp = CalendarEventRules.rsvpKind(event)
        let hollow = rsvp == .tentative || rsvp == .needs
        let cancelled = CalendarEventRules.isCancelled(event)
        return HStack(spacing: 4) {
                Circle()
                    .strokeBorder(color, lineWidth: hollow ? 1.2 : 0)
                    .background(Circle().fill(hollow ? .clear : color))
                    .frame(width: 5, height: 5)
                Text(CalendarChrome.time(event.startsAt))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(theme.ink3.color)
                Text(event.summary ?? "(kein Titel)")
                    .font(.system(size: 10.5))
                    .strikethrough(cancelled)
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
            .frame(width: colWidth - 4, height: 20, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { clicked(event) }
            .contextMenu {
                EventContextMenu(store: store, event: event,
                                 onOpen: { store.openCard(event.id) },
                                 onEdit: { store.openCard(event.id, edit: true) },
                                 onDelete: { onDelete(event) })
            }
            .overlay {
                if store.openEventId == event.id || store.selectedEventId == event.id {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(color, lineWidth: store.openEventId == event.id ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
            }
            .help(event.summary ?? "")
    }

    /// Ein Klick öffnet das Band unter der Woche, ein Doppelklick das Formular.
    private func clicked(_ event: CalendarEvent) {
        store.selectedEventId = event.id
        PerfLog.shared.write("calendar_click id=\(event.id) mode=month source=month")
        clicks.click(String(event.id),
                     onOpen: { store.openCard(event.id) },
                     onEdit: { store.openCard(event.id, edit: true) })
    }

    private func isWeekend(_ day: Int64) -> Bool {
        let weekday = store.math.weekdayIndex(day)
        return weekday == 1 || weekday == 7
    }
}
