import CoraxKit
import SwiftUI

/// M2.9: der Kalender-Inhalt der gemeinsamen Seitenleiste (`CalendarSidebar.tsx`
/// + `MiniMonth.tsx`): neuer Termin, Minimonat mit Terminpunkten und sichtbarem
/// Zeitraum, ein Schalter je Kalendersammlung, „Einladungen & lokal". Die Spalte
/// selbst (Breite, Hintergrund, Trennlinie) stellt `SidebarColumn`.
struct CalendarSidebarContent: View {
    let store: CalendarStore
    let accounts: [Account]
    @Environment(\.theme) private var theme
    @State private var month: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                NotificationCenter.default.post(name: .coraxCalendarNewEvent, object: nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("Neuer Termin").font(.system(size: 12.5, weight: .medium))
                }
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(theme.accentInk.color)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.color))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Neuer Termin (B)")

            miniMonth

            VStack(alignment: .leading, spacing: 2) {
                Text("Kalender")
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(theme.ink3.color)
                    .padding(.leading, 4)
                    .padding(.bottom, 2)
                let groups = store.calendarGroups(accounts: accounts)
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    if let account = group.account {
                        Text(account.label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.ink2.color)
                            .padding(.leading, 4)
                            .padding(.top, 2)
                    }
                    ForEach(group.calendars) { calendar in
                        toggle(calendar.label,
                               color: CalendarChrome.hex(calendar.color) ?? theme.accent.color,
                               checked: !store.hiddenCalendars.contains(calendar.id)) {
                            store.toggleCalendar(calendar.id)
                        }
                    }
                }
                toggle("Einladungen & lokal", color: theme.ink3.color, checked: !store.hiddenLocal) {
                    store.toggleLocal()
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Mini month

    private var miniMonth: some View {
        let math = store.math
        let anchorMonth = math.startOfMonth(store.anchor)
        let shown = month ?? anchorMonth
        let days = math.monthGridDays(shown)
        let first = days.first ?? shown
        let last = days.last ?? shown
        let byDay = CalendarEventRules.groupByDay(
            store.visibleEvents.filter { $0.startsAt < last + CalendarGrid.dayMs && CalendarEventRules.eventEnd($0) > first },
            days: days)
        let today = store.todayStart
        let range = store.range
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        formatter.dateFormat = "LLLL yyyy"
        return VStack(spacing: 6) {
            HStack(spacing: 2) {
                Text(formatter.string(from: math.date(shown)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Spacer(minLength: 4)
                miniButton("chevron.left", help: "Voriger Monat") {
                    month = math.startOfMonth(math.addMonths(shown, -1))
                }
                miniButton("chevron.right", help: "Nächster Monat") {
                    month = math.startOfMonth(math.addMonths(shown, 1))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(days.prefix(7), id: \.self) { day in
                    Text(String(CalendarChrome.weekdayShort(day).prefix(2)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.ink3.color)
                        .frame(height: 18)
                }
                ForEach(days, id: \.self) { day in
                    miniDay(day, month: shown, today: today, range: range,
                            hasEvents: !(byDay[day] ?? []).isEmpty, math: math)
                }
            }
        }
        .onChange(of: anchorMonth) { _, newValue in month = newValue }
    }

    private func miniDay(_ day: Int64, month: Int64, today: Int64,
                         range: (start: Int64, end: Int64), hasEvents: Bool,
                         math: CalendarMath) -> some View {
        let inMonth = math.monthIndex(day) == math.monthIndex(month)
        let inRange = day >= range.start && day < range.end
        let isToday = day == today
        return Button {
            store.go(to: day)
        } label: {
            VStack(spacing: 1) {
                Text("\(CalendarChrome.dayNumber(day))")
                    .font(.system(size: 11, weight: isToday ? .bold : (inRange ? .medium : .regular)))
                    .foregroundStyle(isToday ? theme.accentInk.color
                                     : (inRange ? theme.accent.color : (inMonth ? theme.ink.color : theme.ink3.color)))
                    .frame(width: 22, height: 20)
                    .background {
                        if isToday {
                            Circle().fill(theme.accent.color).frame(width: 20, height: 20)
                        } else if inRange {
                            RoundedRectangle(cornerRadius: 5).fill(theme.accent.color.opacity(0.12))
                        }
                    }
                Circle()
                    .fill(isToday ? theme.accentInk.color : theme.ink3.color)
                    .frame(width: 3, height: 3)
                    .opacity(hasEvents ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(CalendarChrome.longDay(day))
    }

    private func miniButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Calendar toggle

    private func toggle(_ label: String, color: Color, checked: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color, lineWidth: 1.2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(checked ? color : .clear))
                    .frame(width: 13, height: 13)
                    .overlay {
                        if checked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(checked ? "eingeblendet" : "ausgeblendet")
    }
}

extension Notification.Name {
    /// Sidebar "Neuer Termin" asks the screen for the editor.
    static let coraxCalendarNewEvent = AppIdentity.notification("calendar.newEvent")
    /// M2.6: the hook build opens the "+N weitere" card for a screenshot.
    static let coraxCalendarDayList = AppIdentity.notification("calendar.dayList")
    /// M2.8b: the hook build feeds one click into the grid (`userInfo`: id), so
    /// the click → detail → popover path can be checked without a pointer.
    static let coraxCalendarClick = AppIdentity.notification("calendar.click")
    /// M2.3: the palette's `create_event` intent opens the editor pre-filled
    /// (`userInfo`: summary, location, startsAt, endsAt, allDay).
    static let coraxCalendarPrefill = AppIdentity.notification("calendar.prefill")
}
