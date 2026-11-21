import AppKit
import RabeKit
import SwiftUI

/// Wo die Karte eines Termins sitzt (M2.9 §7.2): als Karte neben dem Block in
/// Tag und Woche, als Band unter der Woche im Monat.
enum CalendarCardLayout: Equatable {
    case card
    case band
}

/// Die Terminkarte: Anzeige und Bearbeiten in **derselben** Fläche. Vorher war
/// das ein Popover neben dem Fenster und ein Sheet für den Editor; beides ist
/// weg (§7.3).
struct CalendarEventCard: View {
    let store: CalendarStore
    let layout: CalendarCardLayout
    var onClose: () -> Void = {}
    var onDelete: (CalendarEvent) -> Void = { _ in }
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var answering = false

    private var accounts: [Account] { AppModel.shared.mailbox.accounts }

    var body: some View {
        Group {
            if store.cardMode == .edit {
                edit
            } else if let event = store.openEvent {
                display(event)
            } else {
                EmptyView()
            }
        }
        .background(shape.fill(theme.surface.color))
        .clipShape(shape)
        // Der 4-pt-Streifen in der Kalenderfarbe sitzt am Kartenrand: als
        // HStack-Kind mit `maxHeight: .infinity` bekam er keine Höhe.
        .overlay(alignment: .leading) {
            if store.cardMode == .view, let event = store.openEvent {
                Rectangle().fill(color(event)).frame(width: 4)
            }
        }
        .overlay(shape.strokeBorder(theme.line.color, lineWidth: 0.5))
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.16), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: layout == .card ? 12 : 10) }

    private func color(_ event: CalendarEvent) -> Color {
        CalendarChrome.color(for: event, calendars: store.calendars, theme: theme)
    }

    // MARK: Anzeige

    private func display(_ event: CalendarEvent) -> some View {
        let cancelled = CalendarEventRules.isCancelled(event)
        let color = color(event)
        return VStack(alignment: .leading, spacing: layout == .card ? 9 : 6) {
            if layout == .band {
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        title(event, color: color, cancelled: cancelled)
                        if store.needsResponse(event) { responseChip }
                        if let rsvp = CalendarEventRules.rsvpKind(event), !cancelled, store.canRSVP(event) { rsvpRow(event, rsvp: rsvp) }
                        if let reason = event.syncError, !reason.isEmpty { uploadWarning(reason) }
                        hints(event)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        details(event)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                title(event, color: color, cancelled: cancelled)
                if store.needsResponse(event) { responseChip }
                details(event)
                if let rsvp = CalendarEventRules.rsvpKind(event), !cancelled, store.canRSVP(event) { rsvpRow(event, rsvp: rsvp) }
                if let reason = event.syncError, !reason.isEmpty { uploadWarning(reason) }
                hints(event)
            }
        }
        .padding(.leading, (layout == .card ? 14 : 16) + 4)
        .padding(.trailing, layout == .card ? 14 : 16)
        .padding(.vertical, layout == .card ? 12 : 11)
        .frame(width: layout == .card ? 360 : nil, alignment: .leading)
    }

    /// 4-pt-Farbstreifen, Titel, Zeit als Satz, rechts die drei Knöpfe.
    private func title(_ event: CalendarEvent, color: Color, cancelled: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary ?? "(kein Titel)")
                    .font(.system(size: layout == .card ? 14.5 : 14, weight: .semibold))
                    .strikethrough(cancelled)
                    .foregroundStyle(theme.ink.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(when(event))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
                if cancelled {
                    Text("Abgesagt").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if store.canEdit(event) {
                    headButton("pencil", help: "Bearbeiten (⌘E)") { store.editOpenCard() }
                }
                headButton("trash", help: "Löschen (⌫)") { onDelete(event) }
                headButton("xmark", help: "Schließen (Esc)") { onClose() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func details(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let location = event.location, !location.isEmpty {
                row("mappin.and.ellipse", location)
            }
            if let url = MeetingLink.url(event.joinUrl) {
                Button { openURL(url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "video").font(.system(size: 10.5)).frame(width: 13)
                        Text("Beitreten").font(.system(size: 11.5, weight: .medium))
                        Text("O").font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 3)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent.color.opacity(0.5), lineWidth: 0.5))
                    }
                    .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
                .help("Meeting beitreten (O)")
            }
            if let recurrence = CalendarEventRules.recurrenceLabel(event.rrule) {
                row("repeat", event.isSeriesOccurrence ? "Teil einer Serie · \(recurrence)" : recurrence)
            }
            if let organizer = event.organizer, !organizer.isEmpty {
                row("person", "Organisiert von \(organizer)")
            }
            if !event.attendees.isEmpty {
                attendees(event)
            }
            if let calendarRow = calendarLabel(event) {
                calendarRow
            }
            if let notes = event.description, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.alignleft").font(.system(size: 10.5))
                        .foregroundStyle(theme.ink3.color).frame(width: 13)
                    Text(notes)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.ink2.color)
                        .lineLimit(layout == .card ? 6 : 4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func attendees(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "person.2").font(.system(size: 10.5))
                .foregroundStyle(theme.ink3.color).frame(width: 13)
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
    }

    /// Farbpunkt, Kalendername, Konto (§7.3).
    private func calendarLabel(_ event: CalendarEvent) -> AnyView? {
        guard let id = event.calendarId,
              let calendar = store.calendars.first(where: { $0.id == id }) else {
            return AnyView(row("externaldrive", "Nur auf diesem Gerät"))
        }
        let account = accounts.first { $0.id == calendar.accountId }?.label
        let text = account.map { "\(calendar.label) · \($0)" } ?? calendar.label
        return AnyView(HStack(alignment: .top, spacing: 6) {
            Circle().fill(color(event)).frame(width: 7, height: 7).padding(.top, 4).frame(width: 13)
            Text(text).font(.system(size: 11.5)).foregroundStyle(theme.ink2.color)
        })
    }

    private func rsvpRow(_ event: CalendarEvent, rsvp: CalendarEventRules.RsvpKind) -> some View {
        HStack(spacing: 6) {
            Text("Teilnehmen?").font(.system(size: 11.5)).foregroundStyle(theme.ink2.color)
            Spacer(minLength: 4)
            rsvpButton("Ja", .accepted, event: event, active: rsvp == .accepted)
            rsvpButton("Vielleicht", .tentative, event: event, active: rsvp == .tentative)
            rsvpButton("Nein", .declined, event: event, active: rsvp == .declined)
        }
    }

    /// M2.17 §3: Einladung, auf die noch keine Antwort gegeben wurde.
    private var responseChip: some View {
        Text("Antwort offen")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
            .fixedSize()
            .help("Antwort offen")
            .accessibilityLabel("Antwort offen")
    }

    /// M2.16: Der Kalender-Server hat den Termin abgelehnt (z. B. HTTP 501).
    /// Vorher stand das nur im Log, die App zeigte den Termin als gespeichert.
    private func uploadWarning(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text("Nicht hochgeladen: \(reason)")
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nicht hochgeladen: \(reason)")
    }

    private func hints(_ event: CalendarEvent) -> some View {
        HStack(spacing: 8) {
            hint("↑↓", "Termin")
            if store.canEdit(event) { hint("⌘E", "bearbeiten") }
            hint("Esc", "schließen")
            if event.joinUrl != nil { hint("O", "Meeting") }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 3.5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.hover.color))
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(theme.ink3.color)
    }

    // MARK: Bearbeiten

    private var edit: some View {
        EventEditFields(store: store, accounts: accounts,
                        draft: editDraft,
                        compact: layout == .card,
                        onSaved: {},
                        onCancel: { store.cancelEdit() },
                        onDelete: onDelete)
            .frame(width: layout == .card ? 360 : nil, alignment: .leading)
    }

    /// Beim Bearbeiten eines bestehenden Termins stammen die Anfangswerte aus
    /// ihm selbst, beim neuen Termin aus dem Entwurf.
    private var editDraft: CalendarEventDraft {
        if let event = store.openEvent {
            return CalendarEventDraft(event: event, startsAt: event.startsAt,
                                      endsAt: CalendarEventRules.eventEnd(event), allDay: event.allDay)
        }
        return store.draft ?? CalendarEventDraft(startsAt: store.anchor,
                                                 endsAt: store.anchor + 30 * 60_000)
    }

    // MARK: Bausteine

    private func headButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 19, height: 19)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func rsvpButton(_ title: String, _ response: RsvpResponse,
                            event: CalendarEvent, active: Bool) -> some View {
        Button {
            answering = true
            Task {
                _ = await store.rsvp(event, response: response)
                answering = false
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

    private func when(_ event: CalendarEvent) -> String {
        let start = CalendarChrome.longDay(event.startsAt)
        if event.allDay { return "\(start) · Ganztägig" }
        let end = CalendarEventRules.eventEnd(event)
        if store.math.isSameDay(event.startsAt, end) {
            return "\(start) · \(CalendarChrome.timeRange(event.startsAt, end))"
        }
        return "\(start) · \(CalendarChrome.time(event.startsAt)) – "
            + "\(CalendarChrome.longDay(end)), \(CalendarChrome.time(end))"
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
