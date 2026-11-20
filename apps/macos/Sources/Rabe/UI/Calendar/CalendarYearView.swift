import SwiftUI
import RabeKit

/// M2.13 §8.3: Jahresansicht — zwölf Minimonate mit Farbpunkten.
///
/// Bewusst ein Gitter aus Monaten mit **einer** Geste je Monat: der Tag wird aus
/// der Klickposition gerechnet. 365 Einzelknöpfe mit eigener Geste wären der
/// Layout-Grund, warum so eine Ansicht hakt (Entwurf §8.5).
struct CalendarYearView: View {
    let store: CalendarStore
    @Environment(\.theme) private var theme
    var onOpenDay: (Int64) -> Void
    var onOpenMonth: (Int64) -> Void

    /// Höchstens drei Farben je Tag, in der Reihenfolge der Termine.
    private var dots: [Int64: [Color]] {
        var result: [Int64: [Color]] = [:]
        let math = store.math
        for event in store.visibleEvents {
            let day = math.startOfDay(event.startsAt)
            var colors = result[day] ?? []
            guard colors.count < 3 else { continue }
            colors.append(CalendarChrome.color(for: event, calendars: store.calendars, theme: theme))
            result[day] = colors
        }
        return result
    }

    var body: some View {
        let months = store.yearDays.first.map { first -> [Int64] in
            let math = store.math
            return (0..<12).map { math.startOfMonth(math.addMonths(first, $0)) }
        } ?? []
        let dots = dots
        GeometryReader { proxy in
            let columns = proxy.size.width >= 900 ? 4 : 3
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: columns),
                    alignment: .leading, spacing: 22) {
                    ForEach(months, id: \.self) { month in
                        yearMonth(month, dots: dots)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
    }

    // MARK: One month

    @ViewBuilder
    private func yearMonth(_ month: Int64, dots: [Int64: [Color]]) -> some View {
        let math = store.math
        let days = math.monthGridDays(month)
        let isCurrent = math.monthIndex(month) == math.monthIndex(store.todayStart)
            && math.calendar.component(.year, from: math.date(month))
                == math.calendar.component(.year, from: math.date(store.todayStart))
        VStack(spacing: 5) {
            Button {
                store.selectDay(month)
                onOpenMonth(month)
            } label: {
                Text(CalendarYearView.monthTitle(month))
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.accent.color : theme.ink2.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCurrent ? "Dieser Monat – öffnen" : "Monat öffnen")

            GeometryReader { proxy in
                let columns = 7
                let cellW = proxy.size.width / CGFloat(columns)
                let rows = max(days.count / columns, 1)
                let cellH = proxy.size.height / CGFloat(rows)
                ZStack(alignment: .topLeading) {
                    weekdayHeader(cellW: cellW)
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        yearDay(day, month: month,
                                dots: dots[day] ?? [],
                                cellW: cellW, cellH: cellH)
                            .offset(x: CGFloat(index % columns) * cellW,
                                    y: CalendarYearView.headerHeight + CGFloat(index / columns) * cellH)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 1).onEnded { value in
                    guard let day = day(at: value.location, days: days, cellW: cellW, cellH: cellH) else { return }
                    store.selectDay(day)
                })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                    guard let day = day(at: value.location, days: days, cellW: cellW, cellH: cellH) else { return }
                    store.selectDay(day)
                    onOpenDay(day)
                })
            }
            .frame(height: CalendarYearView.monthHeight)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isCurrent ? theme.sel.color : Color.clear))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CalendarYearView.monthTitle(month))
    }

    private func weekdayHeader(cellW: CGFloat) -> some View {
        let math = store.math
        return HStack(spacing: 0) {
            ForEach(Array(math.weekDays(store.todayStart).prefix(7).enumerated()), id: \.element) { _, day in
                Text(String(CalendarChrome.weekdayShort(day).prefix(2)))
                    .font(.system(size: 8.5))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: cellW, height: CalendarYearView.headerHeight)
            }
        }
    }

    private func yearDay(_ day: Int64, month: Int64, dots: [Color],
                         cellW: CGFloat, cellH: CGFloat) -> some View {
        let math = store.math
        let inMonth = math.monthIndex(day) == math.monthIndex(month)
        let isToday = day == store.todayStart
        let isSelected = day == store.selectedDayOrToday
        let isWeekend = CalendarYearView.isWeekend(day, calendar: math.calendar)
        let number = CalendarChrome.dayNumber(day)
        return VStack(spacing: 1) {
            ZStack {
                if isToday {
                    Circle().fill(theme.accent.color).frame(width: 17, height: 17)
                } else if isSelected {
                    Circle().strokeBorder(theme.accent.color, lineWidth: 1.4)
                        .frame(width: 17, height: 17)
                }
                Text("\(number)")
                    .font(.system(size: 9.5, weight: isToday ? .bold : (inMonth ? .regular : .light)))
                    .foregroundStyle(isToday ? theme.accentInk.color
                                     : (inMonth ? (isWeekend ? theme.ink3.color : theme.ink.color)
                                        : theme.ink3.color.opacity(0.5)))
            }
            .frame(width: cellW, height: CalendarYearView.numberHeight)
            HStack(spacing: 1.5) {
                ForEach(Array(dots.prefix(3).enumerated()), id: \.offset) { _, color in
                    Circle().fill(inMonth ? color : color.opacity(0.35))
                        .frame(width: 2.6, height: 2.6)
                }
            }
            .frame(height: CalendarYearView.dotHeight)
        }
        .frame(width: cellW, height: cellH, alignment: .top)
    }

    // MARK: Geometry

    private static let headerHeight: CGFloat = 12
    private static let numberHeight: CGFloat = 17
    private static let dotHeight: CGFloat = 5
    private static let monthHeight: CGFloat = 116

    /// Tag aus der Klickposition: Spalte und Zeile des Monatsgitters.
    private func day(at point: CGPoint, days: [Int64], cellW: CGFloat, cellH: CGFloat) -> Int64? {
        guard cellW > 0, cellH > 0 else { return nil }
        let y = point.y - CalendarYearView.headerHeight
        guard y >= 0 else { return nil }
        let column = Int(point.x / cellW)
        let row = Int(y / cellH)
        guard (0..<7).contains(column) else { return nil }
        let index = row * 7 + column
        guard days.indices.contains(index) else { return nil }
        return days[index]
    }

    /// Samstag oder Sonntag (`weekday`: 1 = Sonntag).
    static func isWeekend(_ day: Int64, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: Date(timeIntervalSince1970: Double(day) / 1000))
        return weekday == 1 || weekday == 7
    }

    static func monthTitle(_ month: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        formatter.dateFormat = "LLLL"
        return formatter.string(from: Date(timeIntervalSince1970: Double(month) / 1000))
    }
}
