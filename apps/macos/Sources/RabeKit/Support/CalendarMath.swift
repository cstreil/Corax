import Foundation

// Ports of `src/lib/calendarGrid.ts` and `src/components/calendar/eventUtils.ts`
// (M2.2, requirement 6). Everything here is pure: no UI, no core, no time zone
// other than the `Calendar` handed in — the tests pin Europe/Berlin.
//
// Times are epoch milliseconds (Int64), exactly as the core stores them, so the
// ports can be compared line by line with the TypeScript originals.

public enum CalendarWeekStart: String, Codable, Sendable, CaseIterable {
    case sunday, monday

    /// `settings.calendarWeekStart`
    public init(setting: String) { self = CalendarWeekStart(rawValue: setting) ?? .monday }
}

/// Pixel and duration constants of the grids (`calendarGrid.ts`).
public enum CalendarGrid {
    public static let dayMs: Int64 = 86_400_000
    /// Height of one hour in the week grid.
    public static let hourPx: Double = 56
    /// Width of the hour-label gutter left of the day columns.
    public static let gutterPx: Double = 56
    /// Default length of an event without an end time.
    public static let defaultEventMs: Int64 = 30 * 60_000
    public static let minimumBlockPx: Double = 18
    /// All-day row height in the week grid and the month cells.
    public static let allDayRowPx: Double = 22
    public static let monthHeadPx: Double = 28
    public static let monthLinePx: Double = 20
}

/// Local-time arithmetic. One value per view/config; the tests use a fixed zone.
public struct CalendarMath: Sendable {
    public var calendar: Calendar
    public var weekStartsOn: CalendarWeekStart

    public init(calendar: Calendar = .autoupdatingCurrent, weekStartsOn: CalendarWeekStart = .monday) {
        self.calendar = calendar
        self.weekStartsOn = weekStartsOn
    }

    public func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    public func stamp(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: Day / week / month

    /// Local midnight.
    public func startOfDay(_ ms: Int64) -> Int64 { stamp(calendar.startOfDay(for: date(ms))) }

    /// Week start at local 00:00, defaulting to the configured first day.
    public func startOfWeek(_ ms: Int64, weekStartsOn: CalendarWeekStart? = nil) -> Int64 {
        let day = calendar.startOfDay(for: date(ms))
        // Gregorian weekday: 1 = Sunday … 7 = Saturday.
        let weekday = calendar.component(.weekday, from: day)
        let first = (weekStartsOn ?? self.weekStartsOn) == .sunday ? 1 : 2
        let shift = (weekday - first + 7) % 7
        guard let shifted = calendar.date(byAdding: .day, value: -shift, to: day) else { return stamp(day) }
        return stamp(shifted)
    }

    /// 00:00 on the first of the month containing `ms`.
    public func startOfMonth(_ ms: Int64) -> Int64 {
        let parts = calendar.dateComponents([.year, .month], from: date(ms))
        guard let first = calendar.date(from: parts) else { return startOfDay(ms) }
        return stamp(first)
    }

    /// `ms` moved by whole calendar days (DST-safe: wall clock stays).
    public func addDays(_ ms: Int64, _ n: Int) -> Int64 {
        guard let shifted = calendar.date(byAdding: .day, value: n, to: date(ms)) else { return ms }
        return stamp(shifted)
    }

    /// Same day-of-month `delta` months away, clamped (Jan 31 +1mo → Feb 28/29).
    public func addMonths(_ ms: Int64, _ delta: Int) -> Int64 {
        let day = calendar.component(.day, from: date(ms))
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date(ms))),
              let moved = calendar.date(byAdding: .month, value: delta, to: first) else { return ms }
        let days = calendar.range(of: .day, in: .month, for: moved)?.count ?? 28
        var parts = calendar.dateComponents([.year, .month], from: moved)
        parts.day = min(day, days)
        guard let result = calendar.date(from: parts) else { return ms }
        return stamp(result)
    }

    /// The 42 day-start timestamps (6 weeks) covering `ms`'s month.
    public func monthGridDays(_ ms: Int64, weekStartsOn: CalendarWeekStart? = nil) -> [Int64] {
        let first = startOfMonth(ms)
        let gridStart = startOfWeek(first, weekStartsOn: weekStartsOn)
        var days: [Int64] = []
        days.reserveCapacity(42)
        for i in 0..<42 { days.append(addDays(gridStart, i)) }
        return days
    }

    /// The seven day starts of the week containing `ms`.
    public func weekDays(_ ms: Int64) -> [Int64] {
        let start = startOfWeek(ms)
        return (0..<7).map { addDays(start, $0) }
    }

    /// Gregorian weekday index, 1 = Sunday.
    public func weekdayIndex(_ ms: Int64) -> Int { calendar.component(.weekday, from: date(ms)) }

    public func hour(_ ms: Int64) -> Int { calendar.component(.hour, from: date(ms)) }
    public func minute(_ ms: Int64) -> Int { calendar.component(.minute, from: date(ms)) }
    public func dayOfMonth(_ ms: Int64) -> Int { calendar.component(.day, from: date(ms)) }
    public func monthIndex(_ ms: Int64) -> Int { calendar.component(.month, from: date(ms)) - 1 }

    public func isSameDay(_ a: Int64, _ b: Int64) -> Bool {
        calendar.isDate(date(a), inSameDayAs: date(b))
    }

    /// Start of the day at a wall-clock time, e.g. 09:00 on `day`.
    public func at(_ day: Int64, hour: Int, minute: Int = 0) -> Int64 {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date(day)).map(stamp) ?? day
    }

    /// `ms` moved by whole days and/or minutes, preserving wall-clock times
    /// across DST transitions (start and end shift independently).
    public func shiftEvent(startsAt: Int64, endsAt: Int64, dayDelta: Int, minuteDelta: Int) -> (startsAt: Int64, endsAt: Int64) {
        func shift(_ ms: Int64) -> Int64 {
            var d = date(ms)
            if dayDelta != 0 { d = calendar.date(byAdding: .day, value: dayDelta, to: d) ?? d }
            if minuteDelta != 0 { d = calendar.date(byAdding: .minute, value: minuteDelta, to: d) ?? d }
            return stamp(d)
        }
        return (shift(startsAt), shift(endsAt))
    }

    // MARK: Grid math

    /// Round minutes to the nearest `step` (default 15-minute grid).
    public static func snapMinutes(_ minutes: Double, step: Double = 15) -> Double {
        (minutes / step).rounded() * step
    }

    /// Grid-content y (px from 00:00) → ms epoch within `dayStart`'s day.
    public static func yToMs(_ y: Double, dayStart: Int64, hourPx: Double = CalendarGrid.hourPx) -> Int64 {
        let minutes = min(max((y / hourPx) * 60, 0), 24 * 60)
        return dayStart + Int64(minutes) * 60_000
    }

    /// ms epoch → grid-content y (px from 00:00 of `dayStart`).
    public static func msToY(_ ms: Int64, dayStart: Int64, hourPx: Double = CalendarGrid.hourPx) -> Double {
        Double(ms - dayStart) / 3_600_000 * hourPx
    }
}

// MARK: - Event rules (`eventUtils.ts`)

public enum CalendarEventRules {
    public static func eventEnd(_ event: CalendarEvent) -> Int64 {
        event.endsAt ?? event.startsAt + CalendarGrid.defaultEventMs
    }

    public static func isCancelled(_ event: CalendarEvent) -> Bool {
        event.status?.uppercased() == "CANCELLED" || event.method?.uppercased() == "CANCEL"
    }

    /// Local events we organize can be dragged/resized; invites are read-only.
    public static func isDraggable(_ event: CalendarEvent) -> Bool {
        event.isLocal && !isCancelled(event) && !event.allDay
    }

    public enum RsvpKind: String, Sendable { case accepted, tentative, declined, needs }

    /// Our response to an invite; nil for events we organize.
    public static func rsvpKind(_ event: CalendarEvent) -> RsvpKind? {
        if event.isLocal { return nil }
        switch event.rsvpStatus?.uppercased() {
        case "ACCEPTED": return .accepted
        case "TENTATIVE": return .tentative
        case "DECLINED": return .declined
        default: return .needs
        }
    }

    /// Bucket events into each day they overlap (multi-day events land in every
    /// day they touch). Days with no events map to [].
    public static func groupByDay(_ events: [CalendarEvent], days: [Int64]) -> [Int64: [CalendarEvent]] {
        var map: [Int64: [CalendarEvent]] = [:]
        for day in days { map[day] = [] }
        for event in events {
            let end = eventEnd(event)
            for day in days where event.startsAt < day + CalendarGrid.dayMs && end > day {
                map[day, default: []].append(event)
            }
        }
        return map
    }

    /// Drop cancelled events that overlap a live one: a rescheduled or replaced
    /// meeting shouldn't squeeze its replacement into half a column.
    public static func withoutShadowedCancels(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let live = events.filter { !isCancelled($0) }
        return events.filter { event in
            !isCancelled(event) || !live.contains { l in
                l.startsAt < eventEnd(event) && eventEnd(l) > event.startsAt
            }
        }
    }

    /// A day-crossing or all-day event is drawn as a spanning bar (month view).
    public static func isBar(_ event: CalendarEvent, math: CalendarMath) -> Bool {
        event.allDay || !math.isSameDay(event.startsAt, eventEnd(event) - 1)
    }

    /// Short recurrence label from an RRULE's FREQ (nil without a rule).
    public static func recurrenceLabel(_ rrule: String?) -> String? {
        guard let rrule, !rrule.isEmpty else { return nil }
        guard let range = rrule.range(of: "FREQ=([A-Z]+)", options: [.regularExpression, .caseInsensitive]),
              let freq = rrule[range].split(separator: "=").last?.uppercased() else {
            return "Wiederkehrender Termin"
        }
        switch freq {
        case "DAILY": return "Wiederholt sich täglich"
        case "WEEKLY": return "Wiederholt sich wöchentlich"
        case "MONTHLY": return "Wiederholt sich monatlich"
        case "YEARLY": return "Wiederholt sich jährlich"
        default: return "Wiederkehrender Termin"
        }
    }
}

// MARK: - Day-column layout (`layoutDay`)

public struct PositionedEvent: Identifiable, Sendable {
    public let event: CalendarEvent
    public let top: Double
    public let height: Double
    public let lane: Int
    public let lanes: Int

    public var id: String { "\(event.id):\(event.startsAt)" }
}

public extension CalendarMath {
    /// Assign overlapping events to side-by-side lanes within one day column.
    static func layoutDay(_ events: [CalendarEvent], dayStart: Int64,
                          hourPx: Double = CalendarGrid.hourPx) -> [PositionedEvent] {
        struct Entry {
            let event: CalendarEvent
            let start: Int64
            let end: Int64
            let lane: Int
        }
        let dayEnd = dayStart + CalendarGrid.dayMs
        struct Timed {
            let event: CalendarEvent
            let start: Int64
            let end: Int64
        }
        var timed: [Timed] = []
        timed.reserveCapacity(events.count)
        for event in events where !event.allDay {
            let start: Int64 = max(event.startsAt, dayStart)
            let clipped: Int64 = min(CalendarEventRules.eventEnd(event), dayEnd)
            let shortest: Int64 = start + 15 * 60_000
            timed.append(Timed(event: event, start: start, end: max(clipped, shortest)))
        }
        timed.sort { a, b in a.start == b.start ? a.end > b.end : a.start < b.start }

        var laneEnds: [Int64] = []
        var placed: [Entry] = []
        placed.reserveCapacity(timed.count)
        for item in timed {
            var lane = laneEnds.firstIndex { $0 <= item.start }
            if lane == nil {
                lane = laneEnds.count
                laneEnds.append(0)
            }
            laneEnds[lane!] = item.end
            placed.append(Entry(event: item.event, start: item.start, end: item.end, lane: lane!))
        }
        return placed.map { entry in
            // Width divisor = max lanes among events this one overlaps.
            let lanes = placed
                .filter { $0.start < entry.end && $0.end > entry.start }
                .reduce(1) { max($0, $1.lane + 1) }
            let minutes = { (ms: Int64) in Double(ms - dayStart) / 60_000 }
            return PositionedEvent(
                event: entry.event,
                top: minutes(entry.start) / 60 * hourPx,
                height: max(Double(entry.end - entry.start) / 3_600_000 * hourPx,
                            CalendarGrid.minimumBlockPx),
                lane: entry.lane,
                lanes: lanes)
        }
    }
}

// MARK: - Spanning bars (`packSpans`)

public struct EventSpan: Identifiable, Sendable {
    public let event: CalendarEvent
    /// First and last visible day column (inclusive, 0-based).
    public let startCol: Int
    public let endCol: Int
    /// Stacking row, 0 = top.
    public let row: Int
    public let clippedStart: Bool
    public let clippedEnd: Bool

    public var id: String { "\(event.id):\(event.startsAt)" }
}

public extension CalendarMath {
    /// Lay events out as horizontal bars over `days` (consecutive day starts).
    static func packSpans(_ events: [CalendarEvent], days: [Int64]) -> [EventSpan] {
        guard let first = days.first, let last = days.last else { return [] }
        let rangeStart = first
        let rangeEnd = last + CalendarGrid.dayMs
        func colOf(_ ms: Int64) -> Int {
            // Day boundaries can be 23/25h apart across DST, so search, don't divide.
            var col = 0
            while col + 1 < days.count && days[col + 1] <= ms { col += 1 }
            return col
        }
        struct Pending {
            let event: CalendarEvent
            let startCol: Int
            let endCol: Int
            let clippedStart: Bool
            let clippedEnd: Bool
        }
        let items = events
            .map { event -> (CalendarEvent, Int64, Int64) in
                (event, event.startsAt, max(CalendarEventRules.eventEnd(event), event.startsAt + 1))
            }
            .filter { $0.1 < rangeEnd && $0.2 > rangeStart }
            .map { event, start, end in
                Pending(event: event,
                        startCol: colOf(max(start, rangeStart)),
                        // `end` is exclusive: an all-day event ending at midnight
                        // stays in the prior day.
                        endCol: colOf(min(end, rangeEnd) - 1),
                        clippedStart: start < rangeStart,
                        clippedEnd: end > rangeEnd)
            }
            .sorted { a, b in
                let aLen = a.endCol - a.startCol, bLen = b.endCol - b.startCol
                if aLen != bLen { return aLen > bLen }
                if a.startCol != b.startCol { return a.startCol < b.startCol }
                return a.event.startsAt < b.event.startsAt
            }

        var rows: [[Bool]] = []
        return items.map { item -> EventSpan in
            var row = 0
            while true {
                if rows.count <= row { rows.append(Array(repeating: false, count: days.count)) }
                let free = (item.startCol...item.endCol).allSatisfy { !rows[row][$0] }
                if free { break }
                row += 1
            }
            for col in item.startCol...item.endCol { rows[row][col] = true }
            return EventSpan(event: item.event, startCol: item.startCol, endCol: item.endCol,
                             row: row, clippedStart: item.clippedStart, clippedEnd: item.clippedEnd)
        }
    }
}

// MARK: - Month week layout (`layoutWeek` in MonthView.tsx)

public struct MonthColumnLayout: Sendable {
    public let chips: [CalendarEvent]
    public let firstLine: Int
    public let hidden: Int
}

public struct MonthWeekLayout: Sendable {
    public let bars: [EventSpan]
    public let columns: [MonthColumnLayout]
}

public extension CalendarMath {
    /// Fit one week row into `cap` lines per day. A bar hidden in any of its days
    /// is hidden everywhere (a bar is one element), which can push more days into
    /// overflow — iterate until stable.
    static func layoutMonthWeek(spans: [EventSpan], timed: [Int64: [CalendarEvent]],
                                days: [Int64], cap: Int) -> MonthWeekLayout {
        func covers(_ span: EventSpan, _ col: Int) -> Bool { span.startCol <= col && col <= span.endCol }
        let timedAt = days.map { timed[$0] ?? [] }
        var limit = days.indices.map { col -> Int in
            let barLines = spans.reduce(0) { covers($1, col) ? max($0, $1.row + 1) : $0 }
            return barLines + timedAt[col].count <= cap ? cap : cap - 1
        }
        var hidden: Set<String> = []
        while true {
            hidden = Set(spans.filter { span in
                (span.startCol...span.endCol).contains { span.row >= limit[$0] }
            }.map(\.id))
            var changed = false
            for span in spans where hidden.contains(span.id) {
                for col in span.startCol...span.endCol where limit[col] == cap {
                    limit[col] = cap - 1
                    changed = true
                }
            }
            if !changed { break }
        }
        let bars = spans.filter { !hidden.contains($0.id) }
        let columns = days.indices.map { col -> MonthColumnLayout in
            let here = spans.filter { covers($0, col) }.count
            let firstLine = bars.reduce(0) { covers($1, col) ? max($0, $1.row + 1) : $0 }
            let chips = Array(timedAt[col].prefix(max(0, limit[col] - firstLine)))
            let shown = bars.filter { covers($0, col) }.count + chips.count
            return MonthColumnLayout(chips: chips, firstLine: firstLine,
                                     hidden: here + timedAt[col].count - shown)
        }
        return MonthWeekLayout(bars: bars, columns: columns)
    }
}

// MARK: - Week/day model (one build per visible range)

/// Everything the day and week grids draw, computed once per range change:
/// all-day bars, the timed events bucketed per day, and their lanes. The views
/// read this instead of measuring or re-laying out per event.
public struct CalendarWeekModel: Sendable {
    public let days: [Int64]
    public let allDaySpans: [EventSpan]
    /// Rows of all-day bars before the "+N" toggle collapses them.
    public let allDayRows: Int
    public let positioned: [Int64: [PositionedEvent]]

    public static func build(events: [CalendarEvent], days: [Int64], math: CalendarMath,
                             hourPx: Double = CalendarGrid.hourPx) -> CalendarWeekModel {
        let allDay = events.filter { $0.allDay }
        let timed = events.filter { !$0.allDay }
        let spans = CalendarMath.packSpans(allDay, days: days)
        let byDay = CalendarEventRules.groupByDay(timed, days: days)
        var positioned: [Int64: [PositionedEvent]] = [:]
        positioned.reserveCapacity(days.count)
        for day in days {
            positioned[day] = CalendarMath.layoutDay(
                CalendarEventRules.withoutShadowedCancels(byDay[day] ?? []), dayStart: day, hourPx: hourPx)
        }
        let rows = spans.reduce(0) { max($0, $1.row + 1) }
        return CalendarWeekModel(days: days, allDaySpans: spans, allDayRows: rows, positioned: positioned)
    }
}

// MARK: - Pointer geometry (M2.8b)

/// Where one event block sits in the grid, in content coordinates (origin: top
/// left of the scrolled grid, y runs from 00:00 of its day).
public struct CalendarBlockRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= x && pointX < x + width && pointY >= y && pointY < y + height
    }
}

/// One event under a point.
public struct CalendarHit: Sendable, Equatable {
    public let event: CalendarEvent
    public let rect: CalendarBlockRect
    /// The point sits in the block's bottom band, where a drag resizes instead
    /// of moving.
    public let isResizeHandle: Bool
}

/// Pure hit test of the day/week grid: content point → event.
///
/// The grids draw `PositionedEvent`s with a fixed geometry (`lane * laneWidth +
/// 2`, `laneWidth - 4` wide, `top + 1`, `height - 2` tall); this is the same
/// arithmetic, so a click that lands on a block resolves to the event the eye
/// sees — including overlapping lanes, where the block drawn last (the rightmost
/// lane here) wins.
public enum CalendarHitTest {
    public static let blockInset = 2.0
    public static let blockGap = 2.0
    /// Height of the resize band at a block's bottom edge (the view uses 7).
    public static let resizeHandle = 7.0
    /// Blocks shorter than this cannot be resized (same rule as the view).
    public static let resizableFrom = 26.0
    /// Movement (pt) below this is a click, above it a drag.
    public static let dragThreshold = 3.0

    /// Day index of a content point, or nil in the hour gutter / outside.
    public static func dayIndex(atX x: Double, dayCount: Int, gutter: Double = CalendarGrid.gutterPx,
                                columnWidth: Double) -> Int? {
        guard columnWidth > 0, dayCount > 0, x >= gutter else { return nil }
        let index = Int((x - gutter) / columnWidth)
        return index >= 0 && index < dayCount ? index : nil
    }

    /// The block rect of one positioned event inside its column.
    public static func rect(of placed: PositionedEvent, columnWidth: Double) -> CalendarBlockRect {
        let laneWidth = columnWidth / Double(max(placed.lanes, 1))
        return CalendarBlockRect(
            x: Double(placed.lane) * laneWidth + blockInset,
            y: placed.top + 1,
            width: laneWidth - blockGap - blockInset,
            height: placed.height - blockGap)
    }

    /// The event under a content point, or nil for empty space (which creates a
    /// new event at that time).
    public static func event(atX x: Double, y: Double, days: [Int64],
                             gutter: Double = CalendarGrid.gutterPx, columnWidth: Double,
                             positioned: [Int64: [PositionedEvent]],
                             draggable: (CalendarEvent) -> Bool = CalendarEventRules.isDraggable)
        -> CalendarHit? {
        guard let index = dayIndex(atX: x, dayCount: days.count, gutter: gutter,
                                   columnWidth: columnWidth) else { return nil }
        let localX = x - gutter - Double(index) * columnWidth
        for placed in (positioned[days[index]] ?? []).reversed() {
            let rect = rect(of: placed, columnWidth: columnWidth)
            guard rect.contains(x: localX, y: y) else { continue }
            let handle = draggable(placed.event) && placed.height > resizableFrom
                && y > rect.y + rect.height - resizeHandle
            return CalendarHit(event: placed.event, rect: rect, isResizeHandle: handle)
        }
        return nil
    }
}

/// Single or double click, resolved from the time between two clicks. Pure so
/// the two behaviours (`Kalender: Klick öffnet, Doppelklick bearbeitet`) have a
/// test instead of a hope.
public struct CalendarClickSequencer: Sendable {
    public enum Kind: Sendable, Equatable { case single, double }

    public var interval: TimeInterval
    private var last: TimeInterval?
    private var lastToken: String?

    public init(interval: TimeInterval = 0.45) {
        self.interval = interval
    }

    /// Feeds one click at `time` (seconds, monotonic) and says what it was.
    ///
    /// `token` names what was clicked: two clicks on different events are never
    /// a double click. A double click consumes the pair, so the click after it
    /// counts again.
    public mutating func register(at time: TimeInterval, token: String = "") -> Kind {
        guard let last, lastToken == token, time >= last, time - last <= interval else {
            self.last = time
            lastToken = token
            return .single
        }
        self.last = nil
        lastToken = nil
        return .double
    }
}
