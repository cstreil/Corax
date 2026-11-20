import XCTest
@testable import Rabe
@testable import RabeKit

/// Ports of `src/components/calendar/eventUtils.test.ts` (complete) and
/// `src/lib/calendarGrid.test.ts` (the layout and date math), M2.2 requirement 6,
/// plus the briefing's DST case (29.03.2026, Europe/Berlin).
///
/// A fixed zone keeps the expectations identical to the TypeScript originals:
/// 2026-07-10 is a Friday, July 1 2026 a Wednesday.
final class CalendarMathTests: XCTestCase {
    private func math(_ weekStartsOn: CalendarWeekStart = .monday) -> CalendarMath {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return CalendarMath(calendar: calendar, weekStartsOn: weekStartsOn)
    }

    /// Local wall-clock time in the same zone the math uses.
    private func at(_ math: CalendarMath, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Int64 {
        var parts = DateComponents()
        parts.year = y; parts.month = mo; parts.day = d; parts.hour = h; parts.minute = mi
        return math.stamp(math.calendar.date(from: parts)!)
    }

    private var fri: Int64 { at(math(), 2026, 7, 10) }

    private func event(_ math: CalendarMath,
                       _ id: Int64 = 1,
                       starts: Int64,
                       ends: Int64?,
                       allDay: Bool = false,
                       isLocal: Bool = true,
                       rsvp: String? = nil,
                       status: String? = "CONFIRMED",
                       method: String? = "REQUEST") -> CalendarEvent {
        _ = math
        return CalendarEvent(
            id: id, accountId: 1, messageId: nil, summary: "e", location: nil, organizer: nil,
            description: nil, attendees: [], joinUrl: nil, rsvpStatus: rsvp, isLocal: isLocal,
            calendarId: nil, rrule: nil, startsAt: starts, endsAt: ends, allDay: allDay,
            status: status, method: method)
    }

    // MARK: snapMinutes / yToMs / msToY (`calendarGrid.test.ts`)

    func testSnapMinutesRoundsToTheNearestQuarter() {
        XCTAssertEqual(CalendarMath.snapMinutes(0), 0)
        XCTAssertEqual(CalendarMath.snapMinutes(7), 0)
        XCTAssertEqual(CalendarMath.snapMinutes(8), 15)
        XCTAssertEqual(CalendarMath.snapMinutes(22), 15)
        XCTAssertEqual(CalendarMath.snapMinutes(23), 30)
        XCTAssertEqual(CalendarMath.snapMinutes(52), 45)
        XCTAssertEqual(CalendarMath.snapMinutes(53), 60)
        XCTAssertEqual(CalendarMath.snapMinutes(40, step: 30), 30)
        XCTAssertEqual(CalendarMath.snapMinutes(46, step: 30), 60)
    }

    func testPixelsMapToTimeAndBack() {
        let nineThirty = fri + 34_200_000          // 9.5 h
        let y = CalendarMath.msToY(nineThirty, dayStart: fri)
        XCTAssertEqual(y, 9.5 * CalendarGrid.hourPx, accuracy: 0.0001)
        XCTAssertEqual(CalendarMath.yToMs(y, dayStart: fri), nineThirty)
        XCTAssertEqual(CalendarMath.yToMs(-50, dayStart: fri), fri)
        XCTAssertEqual(CalendarMath.yToMs(25 * CalendarGrid.hourPx, dayStart: fri),
                       fri + CalendarGrid.dayMs)
    }

    // MARK: Day / week / month

    func testStartOfDayFloorsToLocalMidnight() {
        let m = math()
        XCTAssertEqual(m.startOfDay(at(m, 2026, 7, 10, 14, 37)), fri)
    }

    func testStartOfWeekDefaultsToMonday() {
        let m = math()
        XCTAssertEqual(m.startOfWeek(fri), at(m, 2026, 7, 6))
        XCTAssertEqual(m.startOfWeek(at(m, 2026, 7, 6, 5)), at(m, 2026, 7, 6))
        XCTAssertEqual(m.startOfWeek(at(m, 2026, 7, 12, 23)), at(m, 2026, 7, 6))
    }

    func testStartOfWeekCanStartOnSunday() {
        let m = math(.sunday)
        XCTAssertEqual(m.startOfWeek(fri), at(m, 2026, 7, 5))
        XCTAssertEqual(m.startOfWeek(at(m, 2026, 7, 5, 5)), at(m, 2026, 7, 5))
        XCTAssertEqual(m.startOfWeek(at(m, 2026, 7, 11, 23)), at(m, 2026, 7, 5))
    }

    func testStartOfMonth() {
        let m = math()
        XCTAssertEqual(m.startOfMonth(at(m, 2026, 7, 31, 12)), at(m, 2026, 7, 1))
        XCTAssertEqual(m.startOfMonth(at(m, 2026, 7, 1)), at(m, 2026, 7, 1))
    }

    func testAddMonthsKeepsOrClampsTheDay() {
        let m = math()
        XCTAssertEqual(m.addMonths(at(m, 2026, 7, 10), 1), at(m, 2026, 8, 10))
        XCTAssertEqual(m.addMonths(at(m, 2026, 7, 10), -1), at(m, 2026, 6, 10))
        // Jan 31 +1mo → Feb 28 (2026) / Feb 29 (2024, leap year).
        XCTAssertEqual(m.addMonths(at(m, 2026, 1, 31), 1), at(m, 2026, 2, 28))
        XCTAssertEqual(m.addMonths(at(m, 2024, 1, 31), 1), at(m, 2024, 2, 29))
        XCTAssertEqual(m.addMonths(at(m, 2026, 3, 31), -1), at(m, 2026, 2, 28))
        // Year boundaries.
        XCTAssertEqual(m.addMonths(at(m, 2026, 12, 15), 1), at(m, 2027, 1, 15))
        XCTAssertEqual(m.addMonths(at(m, 2026, 1, 15), -1), at(m, 2025, 12, 15))
    }

    func testMonthGridIsSixWeeksStartingOnTheConfiguredDay() {
        let monday = math()
        let cells = monday.monthGridDays(at(monday, 2026, 7, 10))
        XCTAssertEqual(cells.count, 42)
        XCTAssertEqual(cells[0], at(monday, 2026, 6, 29))       // Mon Jun 29
        XCTAssertEqual(monday.weekdayIndex(cells[0]), 2)        // Gregorian 2 = Monday

        let sunday = math(.sunday)
        let sunCells = sunday.monthGridDays(at(sunday, 2026, 7, 10))
        XCTAssertEqual(sunCells.count, 42)
        XCTAssertEqual(sunCells[0], at(sunday, 2026, 6, 28))     // Sun Jun 28
        XCTAssertEqual(sunday.weekdayIndex(sunCells[0]), 1)
    }

    func testMonthGridCoversEachDayOnceAndStaysConsecutive() {
        let m = math()
        let cells = m.monthGridDays(at(m, 2026, 7, 10))
        XCTAssertEqual(cells.filter { m.monthIndex($0) == 6 }.count, 31)
        XCTAssertEqual(cells.filter { m.monthIndex($0) == 6 }.first, at(m, 2026, 7, 1))
        XCTAssertEqual(cells.filter { m.monthIndex($0) == 6 }.last, at(m, 2026, 7, 31))

        // March 2026 contains the DST switch: cells are still one day apart.
        let march = m.monthGridDays(at(m, 2026, 3, 15))
        for i in 1..<march.count {
            XCTAssertEqual(march[i], m.addDays(march[i - 1], 1), "cell \(i)")
        }
        // June 1 2026 is a Monday: the grid starts on the 1st.
        XCTAssertEqual(m.monthGridDays(at(m, 2026, 6, 10))[0], at(m, 2026, 6, 1))
    }

    // MARK: shiftEvent, incl. the DST requirement (29.03.2026 Europe/Berlin)

    func testShiftEventKeepsWallClockTimes() {
        let m = math()
        let start = at(m, 2026, 7, 10, 9), end = at(m, 2026, 7, 10, 10, 30)
        let moved = m.shiftEvent(startsAt: start, endsAt: end, dayDelta: 3, minuteDelta: 0)
        XCTAssertEqual(m.dayOfMonth(moved.startsAt), 13)
        XCTAssertEqual(m.hour(moved.startsAt), 9)
        XCTAssertEqual(m.hour(moved.endsAt), 10)
        XCTAssertEqual(m.minute(moved.endsAt), 30)

        let byMinutes = m.shiftEvent(startsAt: at(m, 2026, 7, 10, 9), endsAt: at(m, 2026, 7, 10, 9, 45),
                                     dayDelta: 0, minuteDelta: 75)
        XCTAssertEqual(byMinutes.startsAt, at(m, 2026, 7, 10, 10, 15))
        XCTAssertEqual(byMinutes.endsAt, at(m, 2026, 7, 10, 11, 0))

        let combined = m.shiftEvent(startsAt: at(m, 2026, 7, 10, 14), endsAt: at(m, 2026, 7, 10, 15),
                                    dayDelta: -2, minuteDelta: -30)
        XCTAssertEqual(combined.startsAt, at(m, 2026, 7, 8, 13, 30))
        XCTAssertEqual(combined.endsAt, at(m, 2026, 7, 8, 14, 30))
    }

    func testShiftEventAcrossSpringDstKeepsNineOClock() {
        let m = math()   // Europe/Berlin: DST starts Sunday 2026-03-29
        let start = at(m, 2026, 3, 27, 9), end = at(m, 2026, 3, 27, 9, 30)
        let moved = m.shiftEvent(startsAt: start, endsAt: end, dayDelta: 7, minuteDelta: 0)
        XCTAssertEqual(m.hour(moved.startsAt), 9)
        XCTAssertEqual(m.minute(moved.startsAt), 0)
        XCTAssertEqual(m.dayOfMonth(moved.startsAt), 3)
        XCTAssertEqual(m.monthIndex(moved.startsAt), 3)        // April
        XCTAssertEqual(m.hour(moved.endsAt), 9)
        XCTAssertEqual(m.minute(moved.endsAt), 30)
    }

    /// 2026-03-29 is 23 hours long in Europe/Berlin (02:00 → 03:00). The
    /// requirement is about what is *shown*: wall-clock times stay what the
    /// invite says, and an all-day event stays on its date.
    func testDstSwitchDayShowsWallClockTimesAndKeepsAllDayEventsPut() {
        let m = math()
        let switchDay = at(m, 2026, 3, 29)
        XCTAssertEqual(m.addDays(switchDay, 1) - switchDay, 23 * 3_600_000)
        XCTAssertEqual(m.addDays(m.addDays(switchDay, 1), 1) - m.addDays(switchDay, 1),
                       24 * 3_600_000)
        XCTAssertEqual(m.hour(switchDay), 0)
        XCTAssertEqual(m.dayOfMonth(switchDay), 29)

        // The wall clock of a 09:00 event is still 09:00 after the switch.
        let nine = m.at(switchDay, hour: 9)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "HH:mm"
        XCTAssertEqual(formatter.string(from: m.date(nine)), "09:00")

        // An all-day event on the switch day occupies that day only.
        let allDay = event(m, starts: switchDay, ends: m.addDays(switchDay, 1), allDay: true)
        let days = [m.addDays(switchDay, -1), switchDay, m.addDays(switchDay, 1)]
        let spans = CalendarMath.packSpans([allDay], days: days)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.startCol, 1)
        XCTAssertEqual(spans.first?.endCol, 1)
        XCTAssertFalse(spans.first?.clippedStart ?? true)
        XCTAssertFalse(spans.first?.clippedEnd ?? true)

        // A timed event is drawn by elapsed time from midnight, exactly like
        // `layoutDay` in `calendarGrid.ts` — on the 23-hour day that puts the
        // 09:00 block one row above the 09:00 label, inherited from Tauri.
        let timed = event(m, starts: nine, ends: m.at(switchDay, hour: 10))
        let placed = CalendarMath.layoutDay([timed], dayStart: switchDay)
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed.first?.top ?? -1, 8 * CalendarGrid.hourPx, accuracy: 0.0001)
        XCTAssertEqual(placed.first?.height ?? -1, CalendarGrid.hourPx, accuracy: 0.0001)
    }

    // MARK: Event rules (`eventUtils.test.ts`)

    func testRsvpKind() {
        let m = math()
        let base = at(m, 2026, 7, 10, 9)
        XCTAssertNil(CalendarEventRules.rsvpKind(
            event(m, starts: base, ends: base + 3_600_000, isLocal: true, rsvp: "ACCEPTED")))
        XCTAssertEqual(CalendarEventRules.rsvpKind(
            event(m, starts: base, ends: base + 3_600_000, isLocal: false, rsvp: "accepted")), .accepted)
        XCTAssertEqual(CalendarEventRules.rsvpKind(
            event(m, starts: base, ends: base + 3_600_000, isLocal: false, rsvp: "TENTATIVE")), .tentative)
        XCTAssertEqual(CalendarEventRules.rsvpKind(
            event(m, starts: base, ends: base + 3_600_000, isLocal: false, rsvp: "DECLINED")), .declined)
        XCTAssertEqual(CalendarEventRules.rsvpKind(
            event(m, starts: base, ends: base + 3_600_000, isLocal: false, rsvp: nil)), .needs)
    }

    func testDraggableIsTimedLiveAndLocal() {
        let m = math()
        let base = at(m, 2026, 7, 10, 9)
        XCTAssertTrue(CalendarEventRules.isDraggable(event(m, starts: base, ends: base + 3_600_000)))
        XCTAssertFalse(CalendarEventRules.isDraggable(
            event(m, starts: base, ends: base + 3_600_000, isLocal: false)))
        XCTAssertFalse(CalendarEventRules.isDraggable(
            event(m, starts: base, ends: base + 3_600_000, allDay: true)))
        XCTAssertFalse(CalendarEventRules.isDraggable(
            event(m, starts: base, ends: base + 3_600_000, status: "CANCELLED")))
    }

    func testGroupByDayPutsAMultiDayEventInEveryDayItTouches() {
        let m = math()
        let day = at(m, 2026, 7, 10)
        let days = [day, day + CalendarGrid.dayMs, day + 2 * CalendarGrid.dayMs]
        let long = event(m, starts: day + 20 * 3_600_000,
                         ends: day + CalendarGrid.dayMs + 3_600_000)
        let map = CalendarEventRules.groupByDay([long], days: days)
        XCTAssertEqual(map[day]?.count, 1)
        XCTAssertEqual(map[day + CalendarGrid.dayMs]?.count, 1)
        XCTAssertEqual(map[day + 2 * CalendarGrid.dayMs]?.count, 0)
    }

    func testShadowedCancelsAreDropped() {
        let m = math()
        let day = at(m, 2026, 7, 10, 9)
        let live = event(m, 1, starts: day, ends: day + 3_600_000)
        let replaced = event(m, 2, starts: day, ends: day + 3_600_000, status: "CANCELLED")
        let alone = event(m, 3, starts: day + 6 * 3_600_000, ends: day + 7 * 3_600_000,
                          status: "CANCELLED")
        let kept = CalendarEventRules.withoutShadowedCancels([live, replaced, alone])
        XCTAssertEqual(kept.map(\.id), [1, 3])
    }

    func testRecurrenceLabel() {
        XCTAssertNil(CalendarEventRules.recurrenceLabel(nil))
        XCTAssertEqual(CalendarEventRules.recurrenceLabel("FREQ=WEEKLY;BYDAY=MO"), "Wiederholt sich wöchentlich")
        XCTAssertEqual(CalendarEventRules.recurrenceLabel("freq=daily"), "Wiederholt sich täglich")
        XCTAssertEqual(CalendarEventRules.recurrenceLabel("FREQ=HOURLY"), "Wiederkehrender Termin")
    }

    // MARK: layoutDay (`calendarGrid.test.ts`)

    func testLoneEventIsPositionedByItsTimes() throws {
        let m = math()
        let placed = CalendarMath.layoutDay(
            [event(m, starts: fri + 9 * 3_600_000, ends: fri + 10 * 3_600_000)], dayStart: fri)
        XCTAssertEqual(placed.count, 1)
        let first = try XCTUnwrap(placed.first)
        XCTAssertEqual(first.top, 9 * CalendarGrid.hourPx, accuracy: 0.0001)
        XCTAssertEqual(first.height, CalendarGrid.hourPx, accuracy: 0.0001)
        XCTAssertEqual(first.lane, 0)
        XCTAssertEqual(first.lanes, 1)
    }

    func testOverlappingEventsShareTheColumn() {
        let m = math()
        let a = event(m, 1, starts: fri + 9 * 3_600_000, ends: fri + 11 * 3_600_000)
        let b = event(m, 2, starts: fri + 10 * 3_600_000, ends: fri + 12 * 3_600_000)
        let placed = CalendarMath.layoutDay([a, b], dayStart: fri)
        XCTAssertNotEqual(placed[0].lane, placed[1].lane)
        XCTAssertEqual(placed[0].lanes, 2)
        XCTAssertEqual(placed[1].lanes, 2)
    }

    func testAFreedLaneIsReused() {
        let m = math()
        let a = event(m, 1, starts: fri + 9 * 3_600_000, ends: fri + 10 * 3_600_000)
        let b = event(m, 2, starts: fri + 34_200_000, ends: fri + 37_800_000)
        let c = event(m, 3, starts: fri + 10 * 3_600_000, ends: fri + 11 * 3_600_000)
        let placed = CalendarMath.layoutDay([a, b, c], dayStart: fri)
        XCTAssertEqual(placed.first { $0.event.id == 3 }?.lane, 0)
    }

    func testAllDayEventsAreSkippedAndOvernightIsClamped() {
        let m = math()
        let allDay = event(m, 1, starts: fri, ends: fri + CalendarGrid.dayMs, allDay: true)
        let overnight = event(m, 2, starts: fri - 2 * 3_600_000, ends: fri + 3_600_000)
        let placed = CalendarMath.layoutDay([allDay, overnight], dayStart: fri)
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed[0].top, 0)
        XCTAssertEqual(placed[0].height, CalendarGrid.hourPx, accuracy: 0.0001)
    }

    func testZeroLengthEventsGetAMinimumHeight() {
        let m = math()
        let placed = CalendarMath.layoutDay(
            [event(m, starts: fri + 9 * 3_600_000, ends: nil)], dayStart: fri)
        XCTAssertGreaterThanOrEqual(placed.first?.height ?? 0, CalendarGrid.minimumBlockPx)
    }

    // MARK: packSpans (`calendarGrid.test.ts`)

    func testMultiDayBarsSpanTheirColumnsEndExclusive() throws {
        let m = math()
        let week = (0..<7).map { at(m, 2026, 7, 6 + $0) }      // Mon 6 .. Sun 12
        let bar = event(m, 1, starts: at(m, 2026, 7, 7), ends: at(m, 2026, 7, 10), allDay: true)
        let spans = CalendarMath.packSpans([bar], days: week)
        XCTAssertEqual(spans.count, 1)
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.startCol, 1)
        XCTAssertEqual(span.endCol, 3)
        XCTAssertEqual(span.row, 0)
        XCTAssertFalse(span.clippedStart || span.clippedEnd)
    }

    func testBarsOutsideTheRangeAreClipped() throws {
        let m = math()
        let week = (0..<7).map { at(m, 2026, 7, 6 + $0) }
        let bar = event(m, 1, starts: at(m, 2026, 7, 1), ends: at(m, 2026, 7, 20), allDay: true)
        let spans = CalendarMath.packSpans([bar], days: week)
        XCTAssertEqual(spans.count, 1)
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual([span.startCol, span.endCol], [0, 6])
        XCTAssertTrue(span.clippedStart)
        XCTAssertTrue(span.clippedEnd)
    }

    func testOverlappingBarsStackAndReuseRows() {
        let m = math()
        let week = (0..<7).map { at(m, 2026, 7, 6 + $0) }
        let long = event(m, 1, starts: at(m, 2026, 7, 6), ends: at(m, 2026, 7, 9), allDay: true)
        let mid = event(m, 2, starts: at(m, 2026, 7, 8), ends: at(m, 2026, 7, 10), allDay: true)
        let late = event(m, 3, starts: at(m, 2026, 7, 11), ends: at(m, 2026, 7, 12), allDay: true)
        let spans = CalendarMath.packSpans([mid, late, long], days: week)
        func row(_ id: Int64) -> Int? { spans.first { $0.event.id == id }?.row }
        XCTAssertEqual(row(1), 0)
        XCTAssertEqual(row(2), 1)
        XCTAssertEqual(row(3), 0)
    }

    func testBarsOutsideTheRangeAreDropped() {
        let m = math()
        let week = (0..<7).map { at(m, 2026, 7, 6 + $0) }
        let far = event(m, 1, starts: at(m, 2026, 7, 20), ends: at(m, 2026, 7, 21), allDay: true)
        XCTAssertTrue(CalendarMath.packSpans([far], days: week).isEmpty)
    }

    // MARK: Month week layout (`layoutWeek` in MonthView.tsx)

    func testMonthWeekOverflowCountsHiddenBarsAndChips() {
        let m = math()
        let week = (0..<7).map { at(m, 2026, 7, 6 + $0) }
        let bar = event(m, 1, starts: at(m, 2026, 7, 6), ends: at(m, 2026, 7, 8), allDay: true)
        let timed = [
            event(m, 2, starts: at(m, 2026, 7, 6, 9), ends: at(m, 2026, 7, 6, 10)),
            event(m, 3, starts: at(m, 2026, 7, 6, 11), ends: at(m, 2026, 7, 6, 12)),
        ]
        let grouped = CalendarEventRules.groupByDay(timed, days: week)
        let spans = CalendarMath.packSpans([bar], days: week)
        let layout = CalendarMath.layoutMonthWeek(spans: spans, timed: grouped, days: week, cap: 2)
        XCTAssertEqual(layout.bars.count, 1)
        // The bar takes line 0; with cap 2 only one line is left for two chips.
        XCTAssertEqual(layout.columns[0].firstLine, 1)
        XCTAssertEqual(layout.columns[0].chips.count, 0)
        XCTAssertEqual(layout.columns[0].hidden, 2)
        XCTAssertEqual(layout.columns[1].firstLine, 1)
        XCTAssertEqual(layout.columns[1].hidden, 0)
    }
}
