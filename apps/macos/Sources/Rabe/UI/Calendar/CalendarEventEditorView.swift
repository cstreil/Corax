import RabeKit
import SwiftUI

/// Create-or-edit sheet (`EventCreate.tsx`). Opens prefilled from a click or a
/// drag in the grid; `event` switches it to edit mode. Attendees get an ICS
/// invite / update through the host's normal send path.
struct CalendarEventEditorView: View {
    let store: CalendarStore
    let accounts: [Account]
    let request: EventEditorRequest
    var onClose: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var summary = ""
    @State private var startsAt: Date
    @State private var endsAt: Date
    @State private var allDay = false
    @State private var location = ""
    @State private var joinUrl = ""
    @State private var attendeesText = ""
    @State private var notes = ""
    @State private var calendarId: Int64?
    @State private var saving = false

    init(store: CalendarStore, accounts: [Account], request: EventEditorRequest, onClose: @escaping () -> Void) {
        self.store = store
        self.accounts = accounts
        self.request = request
        self.onClose = onClose
        // Editing keeps the stored values; a new event takes the prefill
        // (palette intent or AI suggestion). Locals keep the initialiser
        // readable for the type checker.
        let stored = request.event
        let summaryText: String = stored?.summary ?? request.title ?? ""
        let locationText: String = stored?.location ?? request.location ?? ""
        let notesText: String = stored?.description ?? request.notes ?? ""
        let attendeeEmails: [String] = stored.map { $0.attendees.map(\.email) }
            ?? request.attendees.map(\.email)
        _summary = State(initialValue: summaryText)
        _startsAt = State(initialValue: Date(timeIntervalSince1970: Double(request.startsAt) / 1000))
        _endsAt = State(initialValue: Date(timeIntervalSince1970: Double(request.endsAt) / 1000))
        _allDay = State(initialValue: stored?.allDay ?? request.allDay)
        _location = State(initialValue: locationText)
        _joinUrl = State(initialValue: stored?.joinUrl ?? "")
        _attendeesText = State(initialValue: attendeeEmails.joined(separator: ", "))
        _notes = State(initialValue: notesText)
        let writable = store.calendars.filter { $0.enabled && !$0.readOnly }
        let defaultCalendar = writable.first { $0.isDefault } ?? writable.first
        _calendarId = State(initialValue: request.event?.calendarId ?? defaultCalendar?.id)
    }

    private var editing: Bool { request.event != nil }

    /// The account the event belongs to: the edited event's, else the selected
    /// calendar's, else the first account.
    private var accountId: Int64? {
        if let event = request.event { return event.accountId }
        if let calendarId, let calendar = store.calendars.first(where: { $0.id == calendarId }) {
            return calendar.accountId
        }
        return accounts.first?.id
    }

    private var invites: [Address] {
        attendeesText
            .split(whereSeparator: { ",; \n".contains($0) })
            .map(String.init)
            .filter { $0.contains("@") }
            .map { Address(name: nil, email: $0) }
    }

    private var writableCalendars: [CalendarCollection] {
        store.calendars.filter { $0.enabled && !$0.readOnly }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing ? "Termin bearbeiten" : "Termin erstellen")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.ink2.color)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink2.color)
                }
                .buttonStyle(.plain)
                .help("Schließen (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Titel", text: $summary)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.bottom, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(theme.line.color).frame(height: 0.5)
                        }

                    field("Wann") {
                        VStack(alignment: .leading, spacing: 6) {
                            DatePicker("Datum", selection: $startsAt,
                                       displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                                .datePickerStyle(.field)
                                .labelsHidden()
                            if !allDay {
                                HStack(spacing: 6) {
                                    DatePicker("Ende", selection: $endsAt, displayedComponents: [.date, .hourAndMinute])
                                        .datePickerStyle(.field)
                                        .labelsHidden()
                                    Text(durationLabel)
                                        .font(.system(size: 11.5).monospacedDigit())
                                        .foregroundStyle(theme.ink3.color)
                                }
                            }
                            Toggle("Ganztägig", isOn: $allDay)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                        }
                    }

                    if !editing, writableCalendars.count > 1 {
                        field("Kalender") {
                            Picker("Kalender", selection: $calendarId) {
                                Text("Nur auf diesem Gerät").tag(Int64?.none)
                                ForEach(writableCalendars) { calendar in
                                    Text("\(calendar.label) · \(accountLabel(calendar.accountId))")
                                        .tag(Int64?.some(calendar.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    field("Teilnehmende") {
                        TextField("E-Mail-Adressen, durch Kommas getrennt", text: $attendeesText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                    }
                    field("Ort") {
                        TextField("Ort", text: $location)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                    }
                    field("Meeting-Link") {
                        TextField("https://…", text: $joinUrl)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                    }
                    field("Notizen") {
                        TextEditor(text: $notes)
                            .font(.system(size: 12.5))
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover.color))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            HStack(spacing: 8) {
                Text("⌘↩ speichert")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.ink3.color)
                Spacer()
                Button("Abbrechen") { close() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if saving { ProgressView().controlSize(.small) }
                    else { Text(saveTitle) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || accountId == nil || saving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.line.color).frame(height: 0.5)
            }
        }
        .frame(width: 540, height: 560)
        .background(theme.win.color)
        .onExitCommand(perform: close)
    }

    private var saveTitle: String {
        if invites.isEmpty { return editing ? "Änderungen speichern" : "Speichern" }
        return editing ? "Speichern & Änderungen mailen" : "Speichern & Einladungen senden"
    }

    private var durationLabel: String {
        let minutes = Int(endsAt.timeIntervalSince(startsAt) / 60)
        guard minutes > 0 else { return "" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func accountLabel(_ id: Int64) -> String {
        accounts.first { $0.id == id }?.label ?? "Konto \(id)"
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 88, alignment: .trailing)
                .padding(.top, 3)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func close() {
        onClose()
        dismiss()
    }

    private func save() {
        guard let accountId, !saving else { return }
        saving = true
        let start = allDay
            ? Int64(store.math.startOfDay(Int64(startsAt.timeIntervalSince1970 * 1000)))
            : Int64(startsAt.timeIntervalSince1970 * 1000)
        var end = allDay
            ? store.math.addDays(start, 1)
            : Int64(endsAt.timeIntervalSince1970 * 1000)
        if end <= start { end = start + CalendarGrid.dayMs }
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationText = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let joinText = joinUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesText = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok: Bool
            if let event = request.event {
                ok = await store.update(UpdateEventArgs(
                    eventId: event.id, summary: summaryText,
                    description: notesText.isEmpty ? nil : notesText,
                    location: locationText.isEmpty ? nil : locationText,
                    joinUrl: joinText.isEmpty ? nil : joinText,
                    startsAt: start, endsAt: end, allDay: allDay,
                    attendees: invites, notify: true))
            } else {
                ok = await store.create(CreateEventArgs(
                    accountId: accountId, calendarId: calendarId, summary: summaryText,
                    description: notesText.isEmpty ? nil : notesText,
                    location: locationText.isEmpty ? nil : locationText,
                    joinUrl: joinText.isEmpty ? nil : joinText,
                    startsAt: start, endsAt: end, allDay: allDay, attendees: invites))
            }
            saving = false
            if ok { close() }
        }
    }
}
