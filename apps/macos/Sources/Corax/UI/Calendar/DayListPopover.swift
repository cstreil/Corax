import CoraxKit
import SwiftUI

/// "+N weitere" in the month view (M2.6, Tauri's `DayListPopover`): every event
/// of that day in a compact card, anchored at the day cell. A row opens the
/// event detail; the header shows the weekday, the date and how many there are.
struct DayListPopover: View {
    let day: Int64
    let events: [CalendarEvent]
    let calendars: [CalendarCollection]
    let theme: Theme
    let onOpen: (CalendarEvent) -> Void
    let onOpenDay: () -> Void
    let onClose: () -> Void

    private var sorted: [CalendarEvent] {
        events.sorted { left, right in
            if left.allDay != right.allDay { return left.allDay }
            return left.startsAt < right.startsAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.line.color)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(sorted, id: \.self) { event in
                        row(event)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxHeight: 320)
            Divider().overlay(theme.line.color)
            Button(action: onOpenDay) {
                Text("Tag anzeigen")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.accent.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Die Tagesansicht für diesen Tag öffnen")
        }
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line.color))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .accessibilityLabel("Termine am \(CalendarChrome.longDay(day))")
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(CalendarChrome.weekdayShort(day, single: false).uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.ink3.color)
                HStack(spacing: 5) {
                    Text(CalendarChrome.shortDay(day))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(events.count == 1 ? "1 Termin" : "\(events.count) Termine")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.ink3.color)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schließen")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private func row(_ event: CalendarEvent) -> some View {
        let cancelled = CalendarEventRules.isCancelled(event)
        let color = CalendarChrome.color(for: event, calendars: calendars, theme: theme)
        let when = event.allDay ? "Ganztägig"
            : CalendarChrome.timeRange(event.startsAt, CalendarEventRules.eventEnd(event))
        return Button {
            onOpen(event)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.summary ?? "(ohne Titel)")
                        .font(.system(size: 12, weight: .medium))
                        .strikethrough(cancelled)
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(2)
                    Text(when)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .opacity(cancelled ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.summary ?? "Termin"), \(when)")
    }
}
