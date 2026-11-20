import AppKit
import RabeKit
import SwiftUI

/// What the calendar screen opens when the user clicks an event or a slot.
struct EventEditorRequest: Identifiable {
    let id = UUID()
    /// The event being edited, or nil for a new one.
    var event: CalendarEvent?
    var startsAt: Int64
    var endsAt: Int64
    var allDay: Bool = false
    /// Pre-filled text for a new event (palette intent, AI suggestion).
    var title: String?
    var location: String?
    var notes: String?
    /// Pre-filled attendees, e.g. the recipients of an AI-drafted mail.
    var attendees: [Address] = []
}

/// Day and week grid (`TimeGrid.tsx`): day headers, all-day bars, hour gutter,
/// now line, click/drag to create, drag to move and resize.
///
/// The two expensive parts are single views, not one view per line or per
/// event geometry: one `Canvas` draws the grid, the hour labels and the now
/// line, and the lanes come from `CalendarWeekModel` (`RabeKit`) so nothing
/// reads its own geometry per frame.
struct CalendarTimeGridView: View {
    let store: CalendarStore
    @Binding var editor: EventEditorRequest?
    @Binding var detail: CalendarEvent?
    @Environment(\.theme) private var theme

    private var days: [Int64] { store.weekModel?.days ?? store.days }
    private var model: CalendarWeekModel? { store.weekModel }
    private var contentHeight: CGFloat { CGFloat(24 * CalendarGrid.hourPx) }

    /// Live preview while a drag runs; the store only sees the committed drop.
    private struct Preview {
        enum Kind { case create, move, resize }
        var kind: Kind
        var dayIndex: Int
        var event: CalendarEvent?
        var startsAt: Int64
        var endsAt: Int64
    }

    @State private var preview: Preview?
    @State private var allDayOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                    GeometryReader { proxy in
                    let gutter = CGFloat(CalendarGrid.gutterPx)
                    let colWidth = max(1, (proxy.size.width - gutter) / CGFloat(max(days.count, 1)))
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            drawGrid(context: context, size: size, gutter: gutter,
                                     colWidth: colWidth, days: days)
                        }
                        .frame(width: proxy.size.width, height: contentHeight)
                        ForEach(Array(days.enumerated()), id: \.element) { index, day in
                            column(day: day, index: index, width: colWidth)
                                .frame(width: colWidth, height: contentHeight)
                                .offset(x: gutter + CGFloat(index) * colWidth)
                        }
                    }
                    }
                    .frame(height: contentHeight)
                }
                .scrollIndicators(.automatic)
                // Land on the working day instead of 00:00 (`scrollTo` on the
                // first layout pass was ignored; the default anchor is not).
                .defaultScrollAnchor(UnitPoint(x: 0.5,
                                               y: workingHour * CalendarGrid.hourPx / contentHeight))
                .onAppear { PerfLog.shared.write("calendar_grid_shown hour=\(Int(workingHour))") }
        }
    }

    // MARK: Header (day names, all-day bars)

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: CGFloat(CalendarGrid.gutterPx), height: 1)
                ForEach(days, id: \.self) { day in
                    dayHeader(day)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(theme.line.color).frame(width: 0.5)
                        }
                }
            }
            if let spans = model?.allDaySpans, !spans.isEmpty {
                allDayRow(spans)
            }
        }
        .background(theme.win.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line.color).frame(height: 0.5)
        }
    }

    private func dayHeader(_ day: Int64) -> some View {
        let isToday = day == store.todayStart
        return Button {
            if days.count > 1 { store.go(to: day); store.setMode(.day) }
        } label: {
            HStack(spacing: 5) {
                Text(CalendarChrome.weekdayShort(day, single: days.count == 1))
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(isToday ? theme.accent.color : theme.ink3.color)
                Text("\(CalendarChrome.dayNumber(day))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isToday ? theme.accentInk.color : theme.ink.color)
                    .frame(minWidth: 20, minHeight: 20)
                    .background {
                        if isToday { Circle().fill(theme.accent.color) }
                    }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(days.count > 1 ? "Tag anzeigen" : CalendarChrome.longDay(day))
    }

    private func allDayRow(_ spans: [EventSpan]) -> some View {
        let rows = model?.allDayRows ?? 0
        let shown = allDayOpen ? rows : min(rows, 2)
        let hidden = spans.filter { $0.row >= shown }.count
        return HStack(spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                if rows > 2 {
                    Button {
                        allDayOpen.toggle()
                    } label: {
                        Text(allDayOpen ? "weniger" : "+\(hidden)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.ink3.color)
                            .padding(.horizontal, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Ganztägig")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.ink3.color)
                }
            }
            .frame(width: CGFloat(CalendarGrid.gutterPx), alignment: .trailing)
            .padding(.trailing, 6)
            GeometryReader { proxy in
                let colWidth = proxy.size.width / CGFloat(max(days.count, 1))
                ZStack(alignment: .topLeading) {
                    ForEach(spans.filter { $0.row < shown }) { span in
                        allDayBar(span, colWidth: colWidth)
                            .frame(width: CGFloat(span.endCol - span.startCol + 1) * colWidth - 4,
                                   height: CalendarGrid.allDayRowPx - 3)
                            .offset(x: CGFloat(span.startCol) * colWidth + 2,
                                    y: 2 + CGFloat(span.row) * CalendarGrid.allDayRowPx)
                    }
                }
            }
            .frame(height: CGFloat(shown) * CalendarGrid.allDayRowPx + 4)
        }
    }

    private func allDayBar(_ span: EventSpan, colWidth: CGFloat) -> some View {
        let color = CalendarChrome.color(for: span.event, calendars: store.calendars, theme: theme)
        return Button {
            detail = span.event
        } label: {
            Text(span.event.summary ?? "(kein Titel)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: CalendarGrid.allDayRowPx - 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16)))
                .overlay(alignment: .leading) {
                    if !span.clippedStart {
                        Rectangle().fill(color).frame(width: 3)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(span.event.summary ?? "")
    }

    // MARK: Columns

    @ViewBuilder
    private func column(day: Int64, index: Int, width: CGFloat) -> some View {
        let positioned = model?.positioned[day] ?? []
        let isToday = day == store.todayStart
        ZStack(alignment: .topLeading) {
            // Click/drag surface for new events (below the blocks).
            Color.clear
                .contentShape(Rectangle())
                .gesture(createGesture(day: day, index: index, width: width))
            if isToday, let nowTop = nowTop(day) {
                Rectangle()
                    .fill(Color.red.opacity(0.7))
                    .frame(height: 1)
                    .offset(y: nowTop)
                    .allowsHitTesting(false)
            }
            ForEach(positioned) { placed in
                block(placed, day: day, index: index, width: width)
            }
            if let preview, preview.dayIndex == index {
                previewBlock(preview, day: day, width: width)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.line.color.opacity(0.7)).frame(width: 0.5)
        }
    }

    private func block(_ placed: PositionedEvent, day: Int64, index: Int, width: CGFloat) -> some View {
        let event = placed.event
        let color = CalendarChrome.color(for: event, calendars: store.calendars, theme: theme)
        let draggable = CalendarEventRules.isDraggable(event)
        let laneWidth = width / CGFloat(max(placed.lanes, 1))
        return CalendarEventBlockView(event: event, color: color, height: placed.height,
                                      draggable: draggable,
                                      onOpen: { detail = event },
                                      onMove: { translation, startIsOnHandle in
                                          drag(event: event, day: day, index: index, width: width,
                                               translation: translation, resizing: startIsOnHandle)
                                      },
                                      onDrop: { translation, startIsOnHandle in
                                          drop(event: event, day: day, index: index, width: width,
                                               translation: translation, resizing: startIsOnHandle)
                                      },
                                      onCancel: { preview = nil })
            .frame(width: laneWidth - 4, height: placed.height - 2)
            .offset(x: CGFloat(placed.lane) * laneWidth + 2, y: placed.top + 1)
            .popover(isPresented: Binding(
                get: { detail?.id == event.id },
                set: { if !$0, detail?.id == event.id { detail = nil } }
            ), arrowEdge: .trailing) {
                CalendarEventDetailView(store: store, event: event, onEdit: {
                    detail = nil
                    editor = EventEditorRequest(event: event, startsAt: event.startsAt,
                                                endsAt: CalendarEventRules.eventEnd(event),
                                                allDay: event.allDay)
                }, onClose: { detail = nil })
            }
    }

    @ViewBuilder
    private func previewBlock(_ preview: Preview, day: Int64, width: CGFloat) -> some View {
        let top = CalendarMath.msToY(max(preview.startsAt, day), dayStart: day)
        let bottom = CalendarMath.msToY(max(preview.endsAt, preview.startsAt), dayStart: day)
        let isCreate = preview.kind == .create
        let color = preview.event.map {
            CalendarChrome.color(for: $0, calendars: store.calendars, theme: theme)
        } ?? theme.accent.color
        VStack(alignment: .leading, spacing: 1) {
            Text(isCreate ? CalendarChrome.timeRange(preview.startsAt, preview.endsAt)
                          : (preview.event?.summary ?? "(kein Titel)"))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
            if !isCreate {
                Text(CalendarChrome.timeRange(preview.startsAt, preview.endsAt))
                    .font(.system(size: 10.5).monospacedDigit())
                    .opacity(0.8)
            }
        }
        .foregroundStyle(isCreate ? theme.accent.color : theme.ink.color)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(width: width - 4, height: max(bottom - top, 14), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(isCreate ? 0.16 : 0.3)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(color.opacity(0.8), lineWidth: isCreate ? 1 : 0))
        .offset(x: 2, y: top)
        .allowsHitTesting(false)
    }

    // MARK: Gestures

    private func createGesture(day: Int64, index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startY = value.startLocation.y
                let startMs = CalendarMath.yToMs(startY, dayStart: day)
                let nowMs = CalendarMath.yToMs(value.location.y, dayStart: day)
                let a = min(startMs, nowMs), b = max(startMs, nowMs)
                let snappedStart = day + Int64(CalendarMath.snapMinutes(
                    Double(a - day) / 60_000)) * 60_000
                let snappedEnd = day + Int64(CalendarMath.snapMinutes(
                    Double(b - day) / 60_000)) * 60_000
                preview = Preview(kind: .create, dayIndex: index, event: nil,
                                  startsAt: min(snappedStart, day + CalendarGrid.dayMs - 60_000),
                                  endsAt: max(snappedEnd, snappedStart + 15 * 60_000))
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 6
                let startMs = CalendarMath.yToMs(value.startLocation.y, dayStart: day)
                let endMs = CalendarMath.yToMs(value.location.y, dayStart: day)
                preview = nil
                let (start, end) = snapped(startMs: startMs, endMs: endMs, day: day, moved: moved)
                editor = EventEditorRequest(startsAt: start, endsAt: end)
            }
    }

    private func snapped(startMs: Int64, endMs: Int64, day: Int64, moved: Bool) -> (Int64, Int64) {
        let rounded = { (ms: Int64) in
            day + Int64(CalendarMath.snapMinutes(Double(ms - day) / 60_000)) * 60_000
        }
        var start = rounded(min(startMs, endMs))
        var end = rounded(max(startMs, endMs))
        if !moved || end - start < 15 * 60_000 { end = start + 30 * 60_000 }
        if start >= day + CalendarGrid.dayMs { start = day + CalendarGrid.dayMs - 30 * 60_000 }
        if end > day + CalendarGrid.dayMs { end = day + CalendarGrid.dayMs }
        return (start, end)
    }

    private func drag(event: CalendarEvent, day: Int64, index: Int, width: CGFloat,
                      translation: CGSize, resizing: Bool) {
        let start = event.startsAt
        let end = CalendarEventRules.eventEnd(event)
        if resizing {
            let deltaMinutes = CalendarMath.snapMinutes(Double(translation.height)
                                                        / CalendarGrid.hourPx * 60)
            let newEnd = day + Int64(Double(end - day) / 60_000 + deltaMinutes) * 60_000
            preview = Preview(kind: .resize, dayIndex: index, event: event, startsAt: start,
                              endsAt: max(newEnd, start + 15 * 60_000))
        } else {
            let dayDelta = days.count > 1 ? Int((translation.width / width).rounded()) : 0
            let minuteDelta = Int(CalendarMath.snapMinutes(Double(translation.height)
                                                           / CalendarGrid.hourPx * 60))
            let shifted = store.math.shiftEvent(startsAt: start, endsAt: end,
                                                dayDelta: dayDelta, minuteDelta: minuteDelta)
            let targetIndex = min(max(index + dayDelta, 0), days.count - 1)
            preview = Preview(kind: .move, dayIndex: targetIndex, event: event,
                              startsAt: shifted.startsAt, endsAt: shifted.endsAt)
        }
    }

    private func drop(event: CalendarEvent, day: Int64, index: Int, width: CGFloat,
                      translation: CGSize, resizing: Bool) {
        let start = event.startsAt
        let end = CalendarEventRules.eventEnd(event)
        preview = nil
        if resizing {
            let deltaMinutes = CalendarMath.snapMinutes(Double(translation.height)
                                                        / CalendarGrid.hourPx * 60)
            guard deltaMinutes != 0 else { return }
            let newEnd = day + Int64(Double(end - day) / 60_000 + deltaMinutes) * 60_000
            let target = max(newEnd, start + 15 * 60_000)
            Task { await store.move(event, startsAt: start, endsAt: target) }
        } else {
            let dayDelta = days.count > 1 ? Int((translation.width / width).rounded()) : 0
            let minuteDelta = Int(CalendarMath.snapMinutes(Double(translation.height)
                                                           / CalendarGrid.hourPx * 60))
            guard dayDelta != 0 || minuteDelta != 0 else { return }
            let shifted = store.math.shiftEvent(startsAt: start, endsAt: end,
                                                dayDelta: dayDelta, minuteDelta: minuteDelta)
            Task { await store.move(event, startsAt: shifted.startsAt, endsAt: shifted.endsAt) }
        }
    }

    // MARK: Grid drawing

    private func drawGrid(context: GraphicsContext, size: CGSize, gutter: CGFloat,
                          colWidth: CGFloat, days: [Int64]) {
        let hour = CalendarGrid.hourPx
        let lineColor = GraphicsContext.Shading.color(theme.line.color.opacity(0.8))
        let faint = GraphicsContext.Shading.color(theme.line.color.opacity(0.35))
        for h in 0...24 {
            let y = CGFloat(h) * hour
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: h % 6 == 0 ? lineColor : faint, lineWidth: 0.5)
        }
        for i in 1..<max(days.count, 1) {
            let x = gutter + CGFloat(i) * colWidth
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: lineColor, lineWidth: 0.5)
        }
        // Hour labels, skipping the one the now badge covers.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let today = store.todayStart
        let showsToday = days.contains(where: { $0 == today })
        let nowTop = showsToday ? CalendarMath.msToY(now, dayStart: today) : -100
        for h in 1..<24 {
            let y = CGFloat(h) * hour
            if showsToday, abs(y - nowTop) < 12 { continue }
            let label = CalendarChrome.time(today + Int64(h) * 3_600_000)
            let text = Text(label)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundColor(theme.ink3.color)
            context.draw(text, at: CGPoint(x: gutter - 7, y: y), anchor: .trailing)
        }
        if showsToday {
            drawNowLine(context: context, size: size, gutter: gutter, top: nowTop, now: now)
        }
    }

    private func drawNowLine(context: GraphicsContext, size: CGSize, gutter: CGFloat,
                             top: CGFloat, now: Int64) {
        var path = Path()
        path.move(to: CGPoint(x: gutter, y: top))
        path.addLine(to: CGPoint(x: size.width, y: top))
        context.stroke(path, with: .color(.red.opacity(0.75)), lineWidth: 1.5)
        let label = Text(CalendarChrome.time(now))
            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
            .foregroundColor(.white)
        context.draw(label, at: CGPoint(x: gutter - 6, y: top), anchor: .trailing)
    }

    private func nowTop(_ day: Int64) -> CGFloat? {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard day == store.todayStart else { return nil }
        return CGFloat(CalendarMath.msToY(now, dayStart: day))
    }

    /// Land near the working day once: 08:00, or 90 minutes before now.
    private var workingHour: Double {
        let nowHour = Double(Calendar.current.component(.hour, from: Date()))
        return max(min(nowHour - 1.5, 17), 8)
    }
}

/// One event block in the time grid. It reports drags with the information the
/// grid needs to distinguish "move" from "resize" (a press on the bottom edge).
struct CalendarEventBlockView: View {
    let event: CalendarEvent
    let color: Color
    let height: Double
    let draggable: Bool
    let onOpen: () -> Void
    let onMove: (CGSize, Bool) -> Void
    let onDrop: (CGSize, Bool) -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private let handle = 7.0

    var body: some View {
        let cancelled = CalendarEventRules.isCancelled(event)
        let declined = CalendarEventRules.rsvpKind(event) == .declined
        VStack(alignment: .leading, spacing: 0) {
            Text(event.summary ?? "(kein Titel)")
                .font(.system(size: 11, weight: .semibold))
                .strikethrough(cancelled)
                .lineLimit(height > 30 ? 2 : 1)
                .foregroundStyle(theme.ink.color)
            if height > 28, let ends = event.endsAt {
                Text(CalendarChrome.timeRange(event.startsAt, ends))
                    .font(.system(size: 10).monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(theme.ink2.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(event.isLocal ? 0.3 : 0.16)))
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .overlay(alignment: .bottom) {
            if draggable && hovering {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.75))
                    .frame(height: 2.5)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 1)
            }
        }
        .opacity(declined ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    // A press on the bottom handle resizes, everywhere else moves.
                    let resizing = hoverHandle(value.startLocation.y)
                    onMove(value.translation, resizing)
                }
                .onEnded { value in
                    let resizing = hoverHandle(value.startLocation.y)
                    if hypot(value.translation.width, value.translation.height) < 3 {
                        onCancel()
                        onOpen()
                    } else {
                        onDrop(value.translation, resizing)
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.summary ?? "(kein Titel)"), \(CalendarChrome.timeRange(event.startsAt, CalendarEventRules.eventEnd(event)))")
        .accessibilityAddTraits(.isButton)
        .help(draggable ? "Ziehen zum Verschieben, unten ziehen für die Länge" : "")
    }

    private func hoverHandle(_ y: CGFloat) -> Bool {
        draggable && height > 26 && Double(y) > height - handle
    }
}
