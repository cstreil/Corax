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

/// M2.9: der Koordinatenraum, in dem die Block-Rechtecke für die Karte liegen.
extension CalendarGrid {
    /// Sichtbarer Bereich (Kopf + Raster), feste Origin.
    static let space = "calendar-card-space"
    /// Scrollender Rasterinhalt: 0:00 liegt auf y = 0 (M2.18i). Die Karte
    /// rechnet den Scroll-Offset selbst dazu, damit sie auch nach dem Scrollen
    /// am Block bleibt.
    static let contentSpace = "calendar-grid-content"
}

/// Wo die Blöcke des Rasters stehen (M2.9 §7.5).
struct EventFramePreference: PreferenceKey {
    static var defaultValue: [Int64: CGRect] { [:] }
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Ganztägige Balken sitzen im **festen** Kopf und liegen damit schon im
/// sichtbaren Raum (M2.18i).
struct EventHeaderFramePreference: PreferenceKey {
    static var defaultValue: [Int64: CGRect] { [:] }
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Platzierung der Terminkarte im Zeitraster (M2.18i) — reine Rechnung, damit
/// der Test sie ohne UI prüfen kann.
enum CalendarCardPlacement {
    static let width: CGFloat = 360
    static let margin: CGFloat = 8

    /// Lage eines Blocks im scrollenden Raster (0:00 = 0), mit denselben Zahlen,
    /// mit denen `block` ihn zeichnet. Sie wird **gerechnet** und nicht per
    /// `GeometryReader` gemessen: `.offset`, das den Block an seine Zeit setzt,
    /// ist eine reine Zeichentransformation — `frame(in:)` sieht sie nicht. Im
    /// Beleg meldete deshalb jeder Block `bminY=0` (Spaltenkopf), und die Karte
    /// stand bei jedem Termin an der 0:00-Linie. Der Treffertest
    /// (`CalendarHitTest.rect`, der die Klicks richtig zuordnet) rechnet die
    /// Spalte lokal; hier kommt der Spaltenversatz dazu (M2.18i).
    static func blockRect(_ placed: PositionedEvent, column: Int, columnWidth: CGFloat) -> CGRect {
        let local = CalendarHitTest.rect(of: placed, columnWidth: Double(columnWidth))
        return CGRect(x: CGFloat(CalendarGrid.gutterPx) + CGFloat(column) * columnWidth + local.x,
                      y: local.y, width: local.width, height: local.height)
    }

    /// Karte **neben** dem Block, oben bündig mit ihm, sonst in den sichtbaren
    /// Bereich geklemmt. `block` liegt im scrollenden Raster (0:00 = 0),
    /// `scrollOffset` ist der aktuelle Scrollstand, `gridTop` die Höhe des
    /// festen Kopfs.
    static func anchor(block: CGRect?, visible: CGSize, gridTop: CGFloat,
                       cardHeight: CGFloat, scrollOffset: CGFloat) -> (x: CGFloat, y: CGFloat) {
        var x: CGFloat
        var top: CGFloat
        if let block {
            let left = block.minX - margin - width
            x = left >= margin ? left : block.maxX + margin
            top = gridTop + block.minY - scrollOffset
        } else {
            x = visible.width - width - margin
            top = gridTop + margin
        }
        x = min(max(margin, x), max(margin, visible.width - width - margin))
        let maxTop = max(gridTop + margin, visible.height - cardHeight - margin)
        top = min(max(gridTop + margin, top), maxTop)
        return (x, top)
    }

    /// Ganztägiger Balken: der sitzt schon im sichtbaren Raum (unter dem Kopf).
    static func anchorBar(bar: CGRect, visible: CGSize,
                          cardHeight: CGFloat) -> (x: CGFloat, y: CGFloat) {
        var x = bar.maxX + margin
        x = min(max(margin, x), max(margin, visible.width - width - margin))
        let maxTop = max(margin, visible.height - cardHeight - margin)
        let top = min(max(margin, bar.maxY + margin), maxTop)
        return (x, top)
    }
}

extension EventEditorRequest {
    /// Aus dem Anlege-Wunsch (Klick, Ziehen, Palette, KI) wird der Entwurf, den
    /// die Karte zeigt.
    var draft: CalendarEventDraft {
        CalendarEventDraft(event: event, startsAt: startsAt, endsAt: endsAt, allDay: allDay,
                           title: title, location: location, notes: notes, attendees: attendees)
    }
}

/// Die Inline-Karte der Tagesansicht rechnet (M2.18j): ein eingeschobener
/// Streifen im Raster, in dem die Karte steht. Alles darunter rückt um genau die
/// **gemessene** Kartenhöhe nach unten, die Stundenleiste links mit — sonst
/// passten die Zeiten nicht mehr zu den Zeilen. Reine Rechnung, damit der Test
/// sie ohne UI prüfen kann.
enum CalendarInlineCard {
    /// Rand über und unter der Karte.
    static let inset: CGFloat = 6
    /// Grundhöhe, bevor die Karte zum ersten Mal gemessen ist — sonst hätte sie
    /// keinen Platz, um sich zu messen.
    static let baseHeight: CGFloat = 160

    struct Gap: Equatable {
        /// Unterkante des Blocks, unter dem die Karte aufklappt (Rastermaß).
        var afterY: CGFloat
        /// Höhe des Streifens: Karte plus Rand oben und unten.
        var height: CGFloat
    }

    static func gap(bottom: CGFloat, cardHeight: CGFloat) -> Gap {
        let card = cardHeight > 0 ? cardHeight : baseHeight
        return Gap(afterY: bottom, height: card + 2 * inset)
    }

    /// Zeit → Anzeige: ab der Blockunterkante rückt alles nach unten.
    static func shown(_ y: CGFloat, gap: Gap?) -> CGFloat {
        guard let gap, y >= gap.afterY else { return y }
        return y + gap.height
    }

    /// Anzeige → Zeit: derselbe Versatz rückwärts, für Klicks ins Raster.
    static func time(_ y: CGFloat, gap: Gap?) -> CGFloat {
        guard let gap, y >= gap.afterY + gap.height else { return y }
        return y - gap.height
    }

    /// Höhe des Rasters samt Einschub.
    static func height(_ content: CGFloat, gap: Gap?) -> CGFloat {
        content + (gap?.height ?? 0)
    }

    /// Scrollziel, damit die Karte ganz sichtbar ist: so weit wie nötig, nicht
    /// weiter, und innerhalb des Rasters.
    static func scrollTarget(gap: Gap, scrollOffset: CGFloat, visible: CGFloat,
                             total: CGFloat) -> CGFloat {
        guard visible > 0 else { return scrollOffset }
        var target = scrollOffset
        let bottom = gap.afterY + gap.height
        if bottom > target + visible - 10 { target = bottom - visible + 10 }
        if gap.afterY < target { target = gap.afterY - 10 }
        return max(0, min(target, max(0, total - visible)))
    }
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
    /// "Löschen …" from a block's context menu: the screen asks before it
    /// deletes (an event with attendees mails them).
    var onDelete: (CalendarEvent) -> Void = { _ in }
    @Environment(\.theme) private var theme

    private var days: [Int64] { store.weekModel?.days ?? store.days }
    private var model: CalendarWeekModel? { store.weekModel }
    private var contentHeight: CGFloat { CGFloat(24 * CalendarGrid.hourPx) }

    // MARK: Inline-Karte in der Tagesansicht (M2.18j)

    /// In der Tagesansicht klappt die Karte **im** Raster auf und schiebt die
    /// späteren Stunden nach unten; die Wochenansicht behält die schwebende
    /// Karte aus M2.18i (dort ist für eine Inline-Karte kein Platz).
    private var inlineDay: Bool { store.mode == .day && days.count == 1 }

    private var inlineGap: CalendarInlineCard.Gap? {
        guard inlineDay, store.cardIsOpen, let anchor = inlineAnchor else { return nil }
        return CalendarInlineCard.gap(bottom: anchor.bottom, cardHeight: inlineCardHeight)
    }

    /// Ober- und Unterkante des Blocks, unter dem aufgeklappt wird: der gewählte
    /// Termin, sonst der Entwurf eines neuen.
    private var inlineAnchor: (top: CGFloat, bottom: CGFloat)? {
        if let id = store.openEventId, let placed = positionedEvent(id) {
            return (CGFloat(placed.top), CGFloat(placed.top + placed.height))
        }
        if let draft = store.draft {
            let day = store.math.startOfDay(draft.startsAt)
            let top = CGFloat(CalendarMath.msToY(max(draft.startsAt, day), dayStart: day))
            let bottom = CGFloat(CalendarMath.msToY(
                max(draft.endsAt, draft.startsAt + 30 * 60_000), dayStart: day))
            return (top, max(top + 16, bottom))
        }
        return nil
    }

    private func shiftedY(_ y: CGFloat) -> CGFloat {
        CalendarInlineCard.shown(y, gap: inlineGap)
    }

    private func timeY(_ y: CGFloat) -> CGFloat {
        CalendarInlineCard.time(y, gap: inlineGap)
    }

    /// Höhe des Rasters samt Einschub.
    private var gridHeight: CGFloat { CalendarInlineCard.height(contentHeight, gap: inlineGap) }

    /// Wie weit eine Zeitposition durch den Einschub nach unten rückt.
    private func shiftFor(top: CGFloat) -> CGFloat { shiftedY(top) - top }

    /// Scrollt die aufgeklappte Karte ganz in den Blick (M2.18j).
    private func showInlineCard(_ gap: CalendarInlineCard.Gap) {
        let target = CalendarInlineCard.scrollTarget(gap: gap, scrollOffset: scrollOffset,
                                                     visible: visibleHeight, total: gridHeight)
        guard abs(target - scrollOffset) > 0.5 else { return }
        scrollPosition.scrollTo(y: target)
        PerfLog.shared.write("calendar_inline_scroll top=\(Int(gap.afterY)) "
                             + "bottom=\(Int(gap.afterY + gap.height)) to=\(Int(target))")
    }

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
    /// Single vs. double click on a block (M2.8b).
    @State private var clicks = CalendarClickRouter()
    /// Last pointer position inside a column, for "Neuer Termin hier".
    @State private var hoverY: [Int: CGFloat] = [:]
    /// Where each block sits **in the visible grid** (M2.9 §7.5): the card is
    /// placed from these rectangles and therefore never scrolls away with the
    /// content and never hangs outside the window.
    @State private var frames: [Int64: CGRect] = [:]
    /// Ganztägige Balken (fester Kopf, sichtbarer Raum).
    @State private var headerFrames: [Int64: CGRect] = [:]
    /// Aktueller Scrollstand des Rasters (M2.18i).
    @State private var scrollOffset: CGFloat = 0
    /// Höhe des sichtbaren Rasters: damit die aufgeklappte Karte ganz in den
    /// Blick gescrollt werden kann (M2.18j).
    @State private var visibleHeight: CGFloat = 0
    /// Gemessene Höhe der Inline-Karte in der Tagesansicht (M2.18j): die
    /// späteren Stunden rücken um genau diesen Wert nach unten.
    @State private var inlineCardHeight: CGFloat = 0
    /// Scrollziel für die Auswahl (M2.18i): gesetzt wird nur der Zielpunkt,
    /// gelesen wird der Stand weiter über `onScrollGeometryChange`.
    @State private var scrollPosition = ScrollPosition()
    /// Höhe von Tageskopf und Ganztagszeile: darunter beginnt das Raster, und
    /// die Karte darf nicht in den Kopf ragen.
    @State private var headerHeight: CGFloat = 0
    /// Gemessene Kartengröße für das Klemmen am unteren Rand.
    @State private var cardSize: CGSize = CGSize(width: 360, height: 200)

    var body: some View {
        VStack(spacing: 0) {
            header
            // M2.12: die Auswahl wandert mit den Pfeiltasten und soll dabei im
            // Blick bleiben. M2.18i: gescrollt wird über die **gerechnete** Lage
            // des Blocks, nicht über `scrollTo(id:)` — dessen Ziel ist die
            // Layout-Position, und die liegt wegen `.offset` für jeden Block am
            // Spaltenkopf. Belegt: ein Klick auf den 21-Uhr-Termin sprang auf 0:00.
            ScrollView(.vertical) {
                GeometryReader { proxy in
                    let gutter = CGFloat(CalendarGrid.gutterPx)
                    let colWidth = max(1, (proxy.size.width - gutter) / CGFloat(max(days.count, 1)))
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            drawGrid(context: context, size: size, gutter: gutter,
                                     colWidth: colWidth, days: days)
                        }
                        .frame(width: proxy.size.width, height: gridHeight)
                        ForEach(Array(days.enumerated()), id: \.element) { index, day in
                            column(day: day, index: index, width: colWidth)
                                .frame(width: colWidth, height: gridHeight)
                                .offset(x: gutter + CGFloat(index) * colWidth)
                        }
                    }
                    .coordinateSpace(name: CalendarGrid.contentSpace)
                }
                .frame(height: gridHeight)
            }
            .scrollIndicators(.automatic)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                if abs(offset - scrollOffset) > 0.5 { scrollOffset = offset }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height
            } action: { _, height in
                if abs(height - visibleHeight) > 0.5 { visibleHeight = height }
            }
            // Land on the working day instead of 00:00 (`scrollTo` on the
            // first layout pass was ignored; the default anchor is not).
            .defaultScrollAnchor(UnitPoint(x: 0.5,
                                           y: workingHour * CalendarGrid.hourPx / max(1, gridHeight)))
            .scrollPosition($scrollPosition)
            .onAppear { PerfLog.shared.write("calendar_grid_shown hour=\(Int(workingHour))") }
            .onChange(of: store.selectedEventId) { _, id in
                guard let id, let placed = positionedEvent(id) else { return }
                let target = max(0, placed.top - 2 * CalendarGrid.hourPx)
                scrollPosition.scrollTo(y: CGFloat(target))
                PerfLog.shared.write("calendar_selected_scroll id=\(id) to=\(Int(target))")
            }
            // M2.18j: die aufgeklappte Inline-Karte soll ganz sichtbar sein.
            .onChange(of: store.cardIsOpen) { _, open in
                guard inlineDay, open, let gap = inlineGap else { return }
                showInlineCard(gap)
            }
            .onChange(of: inlineGap) { _, gap in
                guard let gap else { return }
                showInlineCard(gap)
            }
        }
        // Der Koordinatenraum liegt **außerhalb** des Scroll-Inhalts und dient
        // den Ganztagsbalken im festen Kopf: die sitzen schon im sichtbaren Raum.
        // Die Terminblöcke melden ihre Lage dagegen im Inhalt (0:00 = 0); den
        // Scrollstand zieht die Karte selbst ab (M2.18i).
        .coordinateSpace(name: CalendarGrid.space)
        .onPreferenceChange(EventFramePreference.self) { frames = $0 }
        .onPreferenceChange(EventHeaderFramePreference.self) { headerFrames = $0 }
        // Die schwebende Karte gibt es nur noch in der Woche; in der Tages-
        // ansicht steckt sie im Raster (M2.18j).
        .overlay { if inlineDay { EmptyView() } else { cardOverlay } }
    }

    /// Die Karte neben dem Block: links, wenn dort Platz ist, sonst rechts;
    /// immer in den sichtbaren Bereich geklemmt (§7.2, §7.5).
    @ViewBuilder private var cardOverlay: some View {
        GeometryReader { proxy in
            if store.cardIsOpen {
                let anchor = cardAnchor(in: proxy.size)
                CalendarEventCard(store: store,
                                  layout: .card,
                                  onClose: {
                                      // Eigene Zeile, damit der Beleg-Lauf den
                                      // ×-Weg von Esc und Klick unterscheiden kann.
                                      PerfLog.shared.write("calendar_card_close_button")
                                      store.closeCard()
                                  },
                                  onDelete: onDelete)
                    .id(anchor.id)
                    .frame(width: 360, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        if abs(size.height - cardSize.height) > 0.5 { cardSize = size }
                    }
                    .offset(x: anchor.x, y: anchor.y)
                    .transition(.opacity)
                    // Eine Zeile je Ankerwechsel: der Beleg kann „Karte am
                    // Block" von „Karte im Ersatzpfad" unterscheiden (M2.18i).
                    .onAppear { logAnchor(anchor, visible: proxy.size) }
                    .onChange(of: anchor.id) { _, _ in logAnchor(anchor, visible: proxy.size) }
                    .onChange(of: frames) { _, _ in logAnchor(anchor, visible: proxy.size) }
                    // Nach dem Scrollen steht die Karte erst an ihrem Platz; ohne
                    // diese Zeile zeigte der Beleg den Stand mitten in der Fahrt.
                    .onChange(of: scrollOffset) { _, _ in logAnchor(anchor, visible: proxy.size) }
            }
        }
        .animation(Motion.reduce ? nil : .timingCurve(0.22, 0.8, 0.2, 1, duration: 0.22),
                   value: store.cardIsOpen)
    }

    /// Position der Karte. Der Anker ist der Block des Termins: oben bündig
    /// mit ihm und **neben** ihm, nicht darüber (M2.18i). Fehlt der Block
    /// (Termin außerhalb der Sicht), sitzt die Karte oben rechts.
    private func cardAnchor(in size: CGSize) -> (x: CGFloat, y: CGFloat, id: String) {
        let id = store.openEvent?.id ?? -1
        let placed: (x: CGFloat, y: CGFloat)
        if let block = frames[id] {
            placed = CalendarCardPlacement.anchor(block: block, visible: size, gridTop: headerHeight,
                                                  cardHeight: cardSize.height,
                                                  scrollOffset: scrollOffset)
        } else if let bar = headerFrames[id] {
            placed = CalendarCardPlacement.anchorBar(bar: bar, visible: size,
                                                     cardHeight: cardSize.height)
        } else {
            placed = CalendarCardPlacement.anchor(block: nil, visible: size, gridTop: headerHeight,
                                                  cardHeight: cardSize.height,
                                                  scrollOffset: scrollOffset)
        }
        return (placed.x, placed.y, "\(id)-\(Int(placed.x))-\(Int(placed.y))")
    }

    /// Belegzeile für die Karte: Block gefunden oder Ersatzpfad (M2.18i).
    /// Mit dem gemessenen Block-Rechteck, damit „Karte am Block" von „Karte
    /// am Kopf geklemmt" unterscheidbar ist, ohne ein Foto zu deuten.
    private func logAnchor(_ anchor: (x: CGFloat, y: CGFloat, id: String), visible: CGSize) {
        let id = store.openEvent?.id ?? -1
        let block = frames[id].map { "bminX=\(Int($0.minX)) bminY=\(Int($0.minY)) bmaxY=\(Int($0.maxY))" }
            ?? "bminX=- bminY=- bmaxY=-"
        let line = "calendar_card_anchor id=\(id) "
            + "block=\(frames[id] != nil ? 1 : 0) "
            + "bar=\(headerFrames[id] != nil ? 1 : 0) "
            + "\(block) "
            + "scroll=\(Int(scrollOffset)) header=\(Int(headerHeight)) "
            + "vis=\(Int(visible.width))x\(Int(visible.height)) "
            + "cardH=\(Int(cardSize.height)) x=\(Int(anchor.x)) y=\(Int(anchor.y))"
        guard line != lastAnchorLine else { return }
        lastAnchorLine = line
        PerfLog.shared.write(line)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(height - headerHeight) > 0.5 { headerHeight = height }
        }
    }

    private func dayHeader(_ day: Int64) -> some View {
        let isToday = day == store.todayStart
        return Button {
            guard days.count > 1 else { return }
            // M2.12: der Wechsel in die Tagesansicht schließt eine offene Karte.
            if store.cardIsOpen { store.closeCard() }
            store.go(to: day)
            store.setMode(.day)
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
            click(span.event)
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
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: EventHeaderFramePreference.self,
                                       value: [span.event.id: geometry.frame(in: .named(CalendarGrid.space))])
            }
        )
        .contextMenu {
            EventContextMenu(store: store, event: span.event,
                             onOpen: { store.openCard(span.event.id) },
                             onEdit: { store.openCard(span.event.id, edit: true) },
                             onDelete: { onDelete(span.event) })
        }
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
                // M2.8b: right-click on free space creates an event at the time
                // under the pointer (Tauri has no menu here at all).
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverY[index] = point.y
                    case .ended: hoverY[index] = nil
                    }
                }
                .contextMenu {
                    Button("Neuer Termin hier") { createHere(day: day, index: index) }
                }
            if isToday, let nowTop = nowTop(day) {
                Rectangle()
                    .fill(Color.red.opacity(0.7))
                    .frame(height: 1)
                    .offset(y: shiftedY(nowTop))
                    .allowsHitTesting(false)
            }
            ForEach(positioned) { placed in
                block(placed, day: day, index: index, width: width)
                    .id(placed.event.id)
            }
            if let preview, preview.dayIndex == index {
                previewBlock(preview, day: day, width: width)
            }
            if let draft = store.draft, let draftTop = draftBlockTop(draft, day: day) {
                draftBlock(draft, top: draftTop, width: width)
            }
            // Zuletzt, damit sie über den Blöcken liegt (M2.18j).
            if inlineDay, index == 0, let gap = inlineGap {
                inlineCard(gap, width: width)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.line.color.opacity(0.7)).frame(width: 0.5)
        }
    }

    private func block(_ placed: PositionedEvent, day: Int64, index: Int, width: CGFloat) -> some View {
        let event = placed.event
        let color = CalendarChrome.color(for: event, calendars: store.calendars, theme: theme)
        let draggable = CalendarEventRules.isDraggable(event, editable: store.canEdit(event))
        let laneWidth = width / CGFloat(max(placed.lanes, 1))
        // M2.18j: Blöcke unter dem Einschub rücken mit ihm nach unten.
        let shift = shiftFor(top: CGFloat(placed.top))
        return CalendarEventBlockView(
            store: store, event: event, color: color, height: placed.height, draggable: draggable,
            onOpen: { store.openCard(event.id) },
            onClick: { click(event) },
            onEdit: { store.openCard(event.id, edit: true) },
            onDelete: { onDelete(event) },
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
            .offset(x: CGFloat(placed.lane) * laneWidth + 2,
                    y: CGFloat(placed.top) + 1 + shift)
            // Lage des Blocks im scrollenden Raster (M2.18i). Nicht per
            // `GeometryReader` gemessen: `.offset` ist eine reine Zeichentransformation,
            // `frame(in:)` sieht sie nicht — jeder Block meldete dann den Spaltenkopf
            // (`bminY=0`), und die Karte stand bei jedem Termin an der 0:00-Linie.
            // Deshalb dasselbe Rechteck, das auch gezeichnet wird und das der
            // Treffertest benutzt (`CalendarHitTest.rect`).
            .background(
                Color.clear.preference(key: EventFramePreference.self,
                                        value: [event.id: CalendarCardPlacement.blockRect(
                                            placed, column: index, columnWidth: width)
                                            .offsetBy(dx: 0, dy: shift)])
            )
            // M2.12: Der Auswahlrand im Zeitraster ist wieder heraus. Er
            // zeichnete auf Tagen mit überlappenden Terminen einen leeren
            // Kasten am Spaltenkopf (belegt im Sandbox-Lauf, Ursache dort nicht
            // abschließend geklärt). In der Monatsansicht bleibt er; im Raster
            // zeigt die offene Karte den gewählten Termin. Siehe Bericht M2.12.
    }

    /// Zuletzt geschriebene Ankerzeile: der Scroll meldet viele Zwischenstände,
    /// im Log steht nur, was sich wirklich ändert (M2.18i).
    @State private var lastAnchorLine = ""
    /// Der gewählte Termin mit seiner Lage, für das Scrollziel der Auswahl.
    private func positionedEvent(_ id: Int64) -> PositionedEvent? {
        guard let positioned = model?.positioned else { return nil }
        for list in positioned.values {
            if let hit = list.first(where: { $0.event.id == id }) { return hit }
        }
        return nil
    }

    /// One click of a block: single opens the detail (after the double-click
    /// window), double opens the editor. The store keeps the event selected, so
    /// `Return` and `⌫` have a target.
    private func click(_ event: CalendarEvent) {
        store.selectedEventId = event.id
        // One line per click so the next live test can tell "the click never
        // arrived" from "the card did not open" (the M2.8a lesson).
        PerfLog.shared.write("calendar_click id=\(event.id) mode=\(store.mode.rawValue) source=grid")
        clicks.click(String(event.id),
                     onOpen: { store.openCard(event.id) },
                     onEdit: { store.openCard(event.id, edit: true) })
    }

    /// Ein neuer Termin (Klick auf freie Fläche, Ziehen, Menü, `B`).
    private func openNew(_ request: EventEditorRequest) {
        store.beginDraft(request.draft)
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
        .offset(x: 2, y: top + shiftFor(top: top))
        .allowsHitTesting(false)
    }

    // MARK: Gestrichelter Platzhalter für einen neuen Termin (§7.3)

    private func draftBlockTop(_ draft: CalendarEventDraft, day: Int64) -> CGFloat? {
        guard draft.startsAt < day + CalendarGrid.dayMs, draft.endsAt > day else { return nil }
        let start = max(draft.startsAt, day)
        return CGFloat(CalendarMath.msToY(start, dayStart: day))
    }

    /// Der neue Termin steht schon im Raster, bevor der Kern ihn kennt: ein
    /// gestrichelter Block, damit die Karte daneben einen Bezug hat.
    private func draftBlock(_ draft: CalendarEventDraft, top: CGFloat, width: CGFloat) -> some View {
        let bottom = CalendarMath.msToY(max(draft.endsAt, draft.startsAt), dayStart: store.math.startOfDay(draft.startsAt))
        let height = max(CGFloat(bottom) - top, 16)
        return VStack(alignment: .leading, spacing: 1) {
            Text(draft.title?.isEmpty == false ? draft.title! : "Neuer Termin")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
            if !draft.allDay {
                Text(CalendarChrome.timeRange(draft.startsAt, draft.endsAt))
                    .font(.system(size: 10.5).monospacedDigit())
                    .opacity(0.75)
            }
        }
        .foregroundStyle(theme.accent.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(width: width - 4, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.accent.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(theme.accent.color.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .offset(x: 2, y: top + shiftFor(top: top))
        .allowsHitTesting(false)
    }

    // MARK: Inline-Karte in der Tagesansicht (M2.18j)

    /// Die Karte im Raster: volle Spaltenbreite, im Einschub unter ihrem Block.
    /// Ihre **gemessene** Höhe bestimmt, wie weit die späteren Stunden nach
    /// unten rücken — wie das Band im Monat.
    private func inlineCard(_ gap: CalendarInlineCard.Gap, width: CGFloat) -> some View {
        CalendarEventCard(store: store, layout: .band,
                          onClose: {
                              PerfLog.shared.write("calendar_card_close_button")
                              store.closeCard()
                          },
                          onDelete: onDelete)
            .frame(width: max(0, width - 2 * CalendarInlineCard.inset))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(height - inlineCardHeight) > 0.5 { inlineCardHeight = height }
            }
            .offset(x: CalendarInlineCard.inset,
                    y: gap.afterY + CalendarInlineCard.inset)
            .transition(.opacity)
            .onAppear { logInline(gap) }
            .onChange(of: inlineCardHeight) { _, _ in logInline(gap) }
    }

    /// Belegzeile (M2.18j): der Einschub, die gemessene Karte, ein Termin
    /// darunter mit seiner verschobenen Lage und eine Stundenbeschriftung — so
    /// ist belegbar, dass Karte, Blocks und Stundenleiste denselben Abstand
    /// haben, ohne ein Foto zu deuten.
    private func logInline(_ gap: CalendarInlineCard.Gap) {
        PerfLog.shared.write("calendar_inline after=\(Int(gap.afterY)) "
                             + "cardH=\(Int(inlineCardHeight)) gap=\(Int(gap.height))")
        if let next = nextBlockBelow(gap.afterY) {
            let shown = shiftedY(CGFloat(next.top))
            PerfLog.shared.write("calendar_inline_shift id=\(next.event.id) "
                                 + "model=\(Int(next.top)) shown=\(Int(shown)) "
                                 + "delta=\(Int(shown - CGFloat(next.top)))")
        }
        let hour = CGFloat(Int(gap.afterY / CalendarGrid.hourPx) + 1)
        let model = hour * CalendarGrid.hourPx
        PerfLog.shared.write("calendar_inline_hour hour=\(Int(hour)) model=\(Int(model)) "
                             + "shown=\(Int(shiftedY(model)))")
    }

    /// Der nächste Block unterhalb der Karte (für die Belegzeile).
    private func nextBlockBelow(_ y: CGFloat) -> PositionedEvent? {
        guard let positioned = model?.positioned else { return nil }
        return positioned.values.flatMap { $0 }
            .filter { CGFloat($0.top) >= y }
            .min { $0.top < $1.top }
    }

    // MARK: Gestures

    private func createGesture(day: Int64, index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // M2.18j: unter dem Einschub liegt die Zeit um die Kartenhöhe höher.
                let startY = timeY(value.startLocation.y)
                let startMs = CalendarMath.yToMs(startY, dayStart: day)
                let nowMs = CalendarMath.yToMs(timeY(value.location.y), dayStart: day)
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
                let startMs = CalendarMath.yToMs(timeY(value.startLocation.y), dayStart: day)
                let endMs = CalendarMath.yToMs(timeY(value.location.y), dayStart: day)
                preview = nil
                // M2.12 requirement 6: a click on empty space closes the open
                // card instead of starting a new event right away. Dragging
                // (moved) still creates, as it does without a card.
                if !moved, store.closeCardOnEmptySpace() { return }
                let (start, end) = snapped(startMs: startMs, endMs: endMs, day: day, moved: moved)
                openNew(EventEditorRequest(startsAt: start, endsAt: end))
            }
    }

    /// "Neuer Termin hier" from the empty-space menu: the event starts at the
    /// time under the last pointer position in that column (snapped to 15 min).
    private func createHere(day: Int64, index: Int) {
        let y = Double(timeY(hoverY[index] ?? CGFloat(9 * CalendarGrid.hourPx)))
        let start = CalendarMath.snapMinutes(Double(CalendarMath.yToMs(y, dayStart: day) - day) / 60_000)
        let startMs = day + Int64(start) * 60_000
        openNew(EventEditorRequest(startsAt: startMs, endsAt: startMs + 30 * 60_000))
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
            let y = shiftedY(CGFloat(h) * hour)
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
            context.draw(text, at: CGPoint(x: gutter - 7, y: shiftedY(y)), anchor: .trailing)
        }
        if showsToday {
            drawNowLine(context: context, size: size, gutter: gutter,
                        top: shiftedY(nowTop), now: now)
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
///
/// A press without movement is a click (M2.8b): before, `minimumDistance: 1`
/// meant a click never ended, so nothing opened. The distance check now happens
/// inside the gesture (`CalendarHitTest.dragThreshold`), and the same gesture
/// reports the click, so hover, drag and click all live on one surface.
struct CalendarEventBlockView: View {
    let store: CalendarStore
    let event: CalendarEvent
    let color: Color
    let height: Double
    let draggable: Bool
    let onOpen: () -> Void
    let onClick: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
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
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isDrag(value.translation) else { return }
                    // A press on the bottom handle resizes, everywhere else moves.
                    let resizing = hoverHandle(value.startLocation.y)
                    onMove(value.translation, resizing)
                }
                .onEnded { value in
                    guard isDrag(value.translation) else {
                        onCancel()
                        onClick()
                        return
                    }
                    let resizing = hoverHandle(value.startLocation.y)
                    onDrop(value.translation, resizing)
                }
        )
        .contextMenu {
            EventContextMenu(store: store, event: event,
                             onOpen: onOpen, onEdit: onEdit, onDelete: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.summary ?? "(kein Titel)"), \(CalendarChrome.timeRange(event.startsAt, CalendarEventRules.eventEnd(event)))")
        .accessibilityAddTraits(.isButton)
        .help(draggable ? "Klicken zum Öffnen, doppelt klicken zum Bearbeiten, ziehen zum Verschieben" : "")
    }

    /// Movement below this is a click, not a drag (`CalendarHitTest.dragThreshold`).
    private func isDrag(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) >= CalendarHitTest.dragThreshold
    }

    private func hoverHandle(_ y: CGFloat) -> Bool {
        draggable && height > CalendarHitTest.resizableFrom && Double(y) > height - handle
    }
}
