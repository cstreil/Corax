import SwiftUI
import CoraxKit

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

    /// M2.17 §4: höchstens drei Punkte je Tag, einer je **Kalender** — nicht
    /// einer je Termin. Die Reihenfolge folgt dem ersten Termin des Tages.
    private var dots: [Int64: [Color]] {
        let byDay = YearDots.byDay(events: store.visibleEvents, days: store.yearDays,
                                   math: store.math)
        return byDay.mapValues { ids in
            ids.map { CalendarChrome.color(calendarId: $0, calendars: store.calendars,
                                           theme: theme) }
        }
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
                // M2.18h: Der ZStack hat ohne eigenen Rahmen nur die Höhe seiner
                // Kinder (Kopfzeile und ein Tagesfeld, ≈ 23 pt) — die Tage
                // darunter wurden gezeichnet, aber nicht getroffen: ein Klick
                // außerhalb der ersten Zeile lief ins Leere. Mit dem Rahmen
                // deckt die Fläche das ganze Monatsgitter ab.
                .frame(width: proxy.size.width, height: proxy.size.height,
                       alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 1).onEnded { value in
                    // M2.18h: Die lokale Position steht im Log — ohne sie war
                    // beim Belegen nicht zu sehen, ob ein Klick danebenging oder
                    // an der falschen Stelle ankam.
                    guard let day = day(at: value.location, days: days, cellW: cellW, cellH: cellH) else {
                        PerfLog.shared.write("calendar_year_click x=\(Int(value.location.x)) "
                                             + "y=\(Int(value.location.y)) cell=\(Int(cellW))x\(Int(cellH)) day=none")
                        return
                    }
                    PerfLog.shared.write("calendar_year_click x=\(Int(value.location.x)) "
                                         + "y=\(Int(value.location.y)) cell=\(Int(cellW))x\(Int(cellH)) day=\(day)")
                    open(day)
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

    /// M2.18h: Ein Klick auf einen Tag öffnet ihn in der Tagesansicht — genau
    /// wie das Tageszahlenfeld der Monatsansicht. Das markierte Datum bleibt
    /// dabei stehen, damit der Rückweg in die Jahresansicht dort landet.
    private func open(_ day: Int64) {
        // Wie in der Monatsansicht: eine offene Karte gibt dem Tag Platz.
        if store.cardIsOpen { store.closeCard() }
        store.selectDay(day)
        onOpenDay(day)
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
                // M2.18h: der **gewählte** Tag ist gefüllt (Akzent, weiße
                // Zahl), heute bekommt nur einen Ring. Vorher war es umgekehrt:
                // heute war gefüllt, die Auswahl ein dünner Ring — im Jahr
                // stand damit scheinbar immer „heute".
                if isSelected {
                    Circle().fill(theme.accent.color).frame(width: 17, height: 17)
                } else if isToday {
                    Circle().strokeBorder(theme.accent.color, lineWidth: 1.2)
                        .frame(width: 17, height: 17)
                }
                Text("\(number)")
                    .font(.system(size: 9.5,
                                  weight: isSelected || isToday ? .bold
                                      : (inMonth ? .regular : .light)))
                    .foregroundStyle(isSelected ? theme.accentInk.color
                                     : (isToday ? theme.accent.color
                                        : (inMonth ? (isWeekend ? theme.ink3.color : theme.ink.color)
                                           : theme.ink3.color.opacity(0.5))))
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
