import AppKit
import RabeKit
import SwiftUI

/// Detail popover of one event (`EventDetailPopover.tsx`): when, where, who,
/// recurrence and description, plus edit/delete for our own events and the three
/// RSVP answers for an invite.
struct CalendarEventDetailView: View {
    let store: CalendarStore
    let event: CalendarEvent
    var onEdit: () -> Void
    var onClose: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var confirmingDelete = false
    @State private var answering = false

    private var cancelled: Bool { CalendarEventRules.isCancelled(event) }
    private var rsvp: CalendarEventRules.RsvpKind? { CalendarEventRules.rsvpKind(event) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.summary ?? "(kein Titel)")
                        .font(.system(size: 14.5, weight: .semibold))
                        .strikethrough(cancelled)
                        .foregroundStyle(theme.ink.color)
                        .textSelection(.enabled)
                    Text(when)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink2.color)
                    if cancelled {
                        Text("Abgesagt").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.ink3.color)
                }
                .buttonStyle(.plain)
            }

            if let location = event.location, !location.isEmpty {
                row("mappin.and.ellipse", location)
            }
            if let urlText = event.joinUrl, let url = URL(string: urlText) {
                Button {
                    openURL(url)
                } label: {
                    row("video", "Beitreten")
                        .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
            }
            if let recurrence = CalendarEventRules.recurrenceLabel(event.rrule) {
                row("repeat", recurrence)
            }
            if let organizer = event.organizer, !organizer.isEmpty {
                row("person", "Organisiert von \(organizer)")
            }
            if !event.attendees.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(event.attendees.prefix(6).enumerated()), id: \.offset) { _, attendee in
                        HStack(spacing: 5) {
                            Text(attendee.name ?? attendee.email)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.ink2.color)
                            if let partstat = attendee.partstat {
                                Text(statusLabel(partstat))
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.ink3.color)
                            }
                        }
                    }
                    if event.attendees.count > 6 {
                        Text("+\(event.attendees.count - 6) weitere")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.ink3.color)
                    }
                }
            }
            if let notes = event.description, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(notes)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }

            if rsvp != nil, !cancelled {
                Divider().opacity(0.4)
                HStack(spacing: 6) {
                    Text("Teilnehmen?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.ink2.color)
                    Spacer(minLength: 4)
                    rsvpButton("Ja", .accepted, active: rsvp == .accepted)
                    rsvpButton("Vielleicht", .tentative, active: rsvp == .tentative)
                    rsvpButton("Nein", .declined, active: rsvp == .declined)
                }
            }

            Divider().opacity(0.4)
            HStack(spacing: 8) {
                if event.isLocal {
                    Button("Bearbeiten") { onClose(); onEdit() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                }
                Spacer()
                Button("Löschen") { confirmingDelete = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(theme.win.color)
        .alert(event.isLocal && !event.attendees.isEmpty ? "Diesen Termin absagen?" : "Diesen Termin löschen?",
               isPresented: $confirmingDelete) {
            Button("Abbrechen", role: .cancel) {}
            Button(event.isLocal && !event.attendees.isEmpty ? "Absagen" : "Löschen", role: .destructive) {
                onClose()
                Task { await store.delete(event) }
            }
        } message: {
            Text(deleteMessage)
        }
    }

    private var when: String {
        let start = CalendarChrome.longDay(event.startsAt)
        if event.allDay { return "\(start) · Ganztägig" }
        let end = CalendarEventRules.eventEnd(event)
        if store.math.isSameDay(event.startsAt, end) {
            return "\(start) · \(CalendarChrome.timeRange(event.startsAt, end))"
        }
        return "\(start) · \(CalendarChrome.time(event.startsAt)) – \(CalendarChrome.longDay(end)), \(CalendarChrome.time(end))"
    }

    private var deleteMessage: String {
        if event.isLocal && !event.attendees.isEmpty {
            return "\(event.attendees.count) Teilnehmende erhalten eine Absage per E-Mail."
        }
        if !event.isLocal {
            return "Der Termin verschwindet aus dem Kalender. Niemand wird benachrichtigt."
        }
        return "Der Termin wird gelöscht. Das lässt sich rückgängig machen, solange der Hinweis sichtbar ist."
    }

    private func rsvpButton(_ title: String, _ response: RsvpResponse, active: Bool) -> some View {
        Button {
            answering = true
            Task {
                _ = await store.rsvp(event, response: response)
                answering = false
                onClose()
            }
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
        .disabled(answering)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 13)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.ink2.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusLabel(_ partstat: String) -> String {
        switch partstat.uppercased() {
        case "ACCEPTED": "zugesagt"
        case "DECLINED": "abgesagt"
        case "TENTATIVE": "vielleicht"
        default: "offen"
        }
    }
}
