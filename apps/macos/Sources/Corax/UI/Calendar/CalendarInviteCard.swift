import CoraxKit
import SwiftUI

/// Invite card above a message body (`InviteCard.tsx`): the calendar events a
/// message carries (`events_for_message`), their time and place, and the three
/// answers that email an ICS reply to the organizer (`rsvp_event`).
struct CalendarInviteCard: View {
    let messageId: Int64
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    private var store: CalendarStore { AppModel.shared.calendar }

    var body: some View {
        Group {
            let events = store.messageEvents[messageId] ?? []
            if !events.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { event in
                        card(event)
                    }
                }
            }
        }
        .task(id: messageId) {
            await store.loadMessageEvents(messageId)
        }
    }

    private func card(_ event: CalendarEvent) -> some View {
        let cancelled = CalendarEventRules.isCancelled(event)
        let color = CalendarChrome.color(for: event, calendars: store.calendars, theme: theme)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Text(monthLabel(event.startsAt))
                        .font(.system(size: 8, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.red)
                    Text("\(CalendarChrome.dayNumber(event.startsAt))")
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(theme.ink.color)
                }
                .frame(width: 32, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover.color))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.summary ?? "(kein Titel)")
                        .font(.system(size: 13, weight: .semibold))
                        .strikethrough(cancelled)
                        .foregroundStyle(theme.ink.color)
                    Text(whenLabel(event))
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.ink2.color)
                    HStack(spacing: 8) {
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse")
                        }
                        if let organizer = event.organizer, !organizer.isEmpty {
                            Label(organizer, systemImage: "person")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
                    if let recurrence = CalendarEventRules.recurrenceLabel(event.rrule) {
                        Text(recurrence)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.ink3.color)
                    }
                }
                Spacer(minLength: 4)
                if let url = MeetingLink.url(event.joinUrl) {
                    Button("Beitreten") { openURL(url) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                }
            }

            if event.isLocal == false {
                Divider().opacity(0.35)
                HStack(spacing: 6) {
                    Text("Teilnehmen?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.ink2.color)
                    Spacer(minLength: 4)
                    answerButton(event, "Ja", .accepted)
                    answerButton(event, "Vielleicht", .tentative)
                    answerButton(event, "Nein", .declined)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.win.color))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.35), lineWidth: 0.8))
        .opacity(cancelled ? 0.7 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Einladung: \(event.summary ?? "(kein Titel)"), \(whenLabel(event))")
    }

    private var currentAnswer: CalendarEventRules.RsvpKind? { nil }

    private func answerButton(_ event: CalendarEvent, _ title: String,
                              _ response: RsvpResponse) -> some View {
        let active = CalendarEventRules.rsvpKind(event)?.rawValue.uppercased()
            == response.rawValue.uppercased()
        return Button {
            Task { _ = await store.rsvp(event, response: response) }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? theme.accentInk.color : theme.ink.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(active ? theme.accent.color : theme.hover.color))
        }
        .buttonStyle(.plain)
        .disabled(store.busy)
    }

    private func whenLabel(_ event: CalendarEvent) -> String {
        let day = CalendarChrome.longDay(event.startsAt)
        if event.allDay { return "\(day) · Ganztägig" }
        let end = CalendarEventRules.eventEnd(event)
        return "\(day) · \(CalendarChrome.timeRange(event.startsAt, end))"
    }

    private func monthLabel(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        formatter.dateFormat = "MMM"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
