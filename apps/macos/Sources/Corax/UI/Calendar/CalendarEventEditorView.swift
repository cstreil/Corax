import CoraxKit
import SwiftUI

/// Die Felder eines Termins — einmal, für die Karte im Raster (M2.9 §7.3) und
/// nicht mehr als eigenes Sheet. Anzeigen und Bearbeiten liegen damit in
/// derselben Fläche; das Editor-Fenster entfällt.
///
/// Gesichert wird nur mit „Sichern" (`⌘↵`) oder `↵` im Titelfeld: CalDAV-Schreiben
/// kann Einladungen auslösen, das soll niemandem beim Tippen passieren.
struct EventEditFields: View {
    let store: CalendarStore
    let accounts: [Account]
    let draft: CalendarEventDraft
    /// Nur für die schmale Karte: weniger Innenabstand.
    var compact: Bool = false
    var onSaved: () -> Void
    var onCancel: () -> Void
    var onDelete: (CalendarEvent) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @FocusState private var titleFocused: Bool

    @State private var summary: String
    @State private var startsAt: Date
    @State private var endsAt: Date
    @State private var allDay: Bool
    @State private var location: String
    @State private var joinUrl: String
    @State private var attendeesText: String
    @State private var notes: String
    @State private var calendarId: Int64?
    @State private var saving = false
    /// M2.18 §3: Dauer in Tagen bei ganztägigen Terminen (der End-Picker ist dort
    /// ausgeblendet, die Länge bleibt trotzdem erhalten).
    @State private var allDayDays: Int
    /// M2.18 §6: Dialog vor dem Sichern einer Wiederholung.
    @State private var scopeAsk = false

    init(store: CalendarStore, accounts: [Account], draft: CalendarEventDraft, compact: Bool = false,
         onSaved: @escaping () -> Void, onCancel: @escaping () -> Void,
         onDelete: @escaping (CalendarEvent) -> Void = { _ in }) {
        self.store = store
        self.accounts = accounts
        self.draft = draft
        self.compact = compact
        self.onSaved = onSaved
        self.onCancel = onCancel
        self.onDelete = onDelete
        let stored = draft.event
        _summary = State(initialValue: stored?.summary ?? draft.title ?? "")
        _startsAt = State(initialValue: Date(timeIntervalSince1970: Double(draft.startsAt) / 1000))
        _endsAt = State(initialValue: Date(timeIntervalSince1970: Double(draft.endsAt) / 1000))
        _allDay = State(initialValue: stored?.allDay ?? draft.allDay)
        let startMs = draft.startsAt
        let endMs = stored.map { CalendarEventRules.eventEnd($0) } ?? draft.endsAt
        _allDayDays = State(initialValue: max(1, Int(((endMs - startMs) + 86_399_999) / 86_400_000)))
        _location = State(initialValue: stored?.location ?? draft.location ?? "")
        _joinUrl = State(initialValue: stored?.joinUrl ?? "")
        _attendeesText = State(initialValue: (stored.map { $0.attendees.map(\.email) } ?? draft.attendees.map(\.email))
            .joined(separator: ", "))
        _notes = State(initialValue: stored?.description ?? draft.notes ?? "")
        let writable = store.calendars.filter { $0.enabled && !$0.readOnly }
        let defaultCalendar = writable.first { $0.isDefault } ?? writable.first
        _calendarId = State(initialValue: stored?.calendarId ?? defaultCalendar?.id)
    }

    private var editing: Bool { draft.event != nil }

    private var accountId: Int64? {
        if let event = draft.event { return event.accountId }
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

    private var canSave: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && accountId != nil && !saving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            TextField("Titel", text: $summary)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 14 : 17, weight: .semibold))
                .focused($titleFocused)
                .onSubmit { requestSave() }
                .accessibilityLabel("Titel")
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.line.color).frame(height: 0.5)
                }

            field("Wann") {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        DatePicker("Beginn", selection: $startsAt,
                                   displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                            .datePickerStyle(.field)
                            .labelsHidden()
                        if !allDay {
                            DatePicker("Ende", selection: $endsAt, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.field)
                                .labelsHidden()
                        }
                        Text(durationLabel)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(theme.ink3.color)
                    }
                    Toggle("Ganztägig", isOn: $allDay)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
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
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover.color))
            }
            field("Ort") {
                TextField("Ort", text: $location)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover.color))
            }
            field("Link") {
                TextField("https://…", text: $joinUrl)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover.color))
            }
            field("Notiz") {
                TextEditor(text: $notes)
                    .font(.system(size: 12))
                    .frame(minHeight: compact ? 46 : 62)
                    .scrollContentBackground(.hidden)
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover.color))
            }

            if scopeAsk { scopePanel }

            HStack(spacing: 8) {
                if let event = draft.event, store.canEdit(event) {
                    Button {
                        onDelete(event)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                            .foregroundStyle(theme.ink3.color)
                    }
                    .buttonStyle(.plain)
                    .help("Termin löschen")
                    .accessibilityLabel("Termin löschen")
                }
                Spacer(minLength: 4)
                Button("Abbrechen") { onCancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
                    .help("Abbrechen (Esc)")
                Button {
                    requestSave()
                } label: {
                    HStack(spacing: 5) {
                        if saving { ProgressView().controlSize(.mini) }
                        Text(saveTitle).font(.system(size: 11.5, weight: .semibold))
                        Text("⌘↵").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.25)))
                    }
                    .foregroundStyle(theme.accentInk.color)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.color))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
                .help("Sichern (⌘↵)")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, compact ? 12 : 14)
        .padding(.vertical, compact ? 10 : 12)
        .onAppear {
            // M2.18 §1: Der Titel ist das erste Feld — „neuer Termin, lostippen".
            // Zweiter Versuch, weil das Feld beim ersten Layout noch nicht im
            // Fenster hängen kann.
            DispatchQueue.main.async { titleFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if !titleFocused { titleFocused = true }
            }
        }
        // M2.18 §3: Der Beginn zieht das Ende mit, die Dauer bleibt.
        .onChange(of: startsAt) { old, new in
            if allDay {
                endsAt = Calendar.current.date(byAdding: .day, value: allDayDays, to: new) ?? new
                return
            }
            let startMs = Int64(new.timeIntervalSince1970 * 1000)
            let oldStartMs = Int64(old.timeIntervalSince1970 * 1000)
            let oldEndMs = Int64(endsAt.timeIntervalSince1970 * 1000)
            let endMs = EventTimes.end(afterStartChangeFrom: oldStartMs, end: oldEndMs, to: startMs)
            endsAt = Date(timeIntervalSince1970: Double(endMs) / 1000)
        }
        .onChange(of: endsAt) { _, new in
            let startMs = Int64(startsAt.timeIntervalSince1970 * 1000)
            let endMs = Int64(new.timeIntervalSince1970 * 1000)
            let clamped = EventTimes.clampedEnd(start: startMs, end: endMs)
            if clamped != endMs { endsAt = Date(timeIntervalSince1970: Double(clamped) / 1000) }
        }
        .onChange(of: allDay) { _, isAllDay in
            let startMs = Int64(startsAt.timeIntervalSince1970 * 1000)
            let endMs = Int64(endsAt.timeIntervalSince1970 * 1000)
            allDayDays = max(1, Int(((endMs - startMs) + 86_399_999) / 86_400_000))
            if isAllDay {
                endsAt = Calendar.current.date(byAdding: .day, value: allDayDays, to: startsAt) ?? endsAt
            }
        }
        // `⌘↵` aus dem Raster (Monitor) und der Knopf im Fuß sichern beide hier.
        // M2.18o: nur die erste Karte verarbeitet den Aufruf — hing die Karte
        // doppelt im Baum (unsichtbare Messkopie im Monat), sicherte auch die
        // Kopie und die Änderung ging zweimal an den Kern.
        .onChange(of: store.saveRequest) { _, _ in
            guard store.takeSaveRequest() else { return }
            requestSave()
        }
    }

    private var saveTitle: String {
        let base = editing ? "Sichern" : "Anlegen"
        return invites.isEmpty ? base : (editing ? "Sichern & mailen" : "Anlegen & einladen")
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
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 74, alignment: .trailing)
                .padding(.top, 3)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// M2.18 §6: Bei einer Wiederholung fragt vor dem Sichern der Geltungsbereich.
    /// Der Kern kann bisher nur „alle" (Teil 2); die anderen Optionen sind
    /// sichtbar, aber gesperrt.
    private func requestSave() {
        if let event = draft.event, event.isSeriesOccurrence {
            scopeAsk = true
            PerfLog.shared.write("calendar_series_scope ask event=\(event.eventId)")
            return
        }
        performSave()
    }

    private var scopePanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Änderung gilt für …")
                .font(.system(size: 11.5, weight: .semibold))
            scopeRow("Nur dieser Termin", enabled: false)
            scopeRow("Dieser und alle folgenden", enabled: false)
            HStack(spacing: 8) {
                Button {
                    scopeAsk = false
                    PerfLog.shared.write("calendar_series_scope all")
                    performSave()
                } label: {
                    Text("Alle Termine der Serie")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.accentInk.color)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.color))
                }
                .buttonStyle(.plain)
                Button("Abbrechen") { scopeAsk = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
            }
            Text("„Nur dieser“ und „dieser und alle folgenden“ kommen mit dem nächsten Kern-Update.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover.color))
        .accessibilityElement(children: .contain)
    }

    private func scopeRow(_ title: String, enabled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10.5))
            Text(title).font(.system(size: 11.5))
            Spacer(minLength: 4)
            if !enabled {
                Text("kommt mit dem nächsten Kern-Update")
                    .font(.system(size: 10))
            }
        }
        .foregroundStyle(enabled ? theme.ink.color : theme.ink3.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + (enabled ? "" : ", nicht verfügbar"))
    }

    private func performSave() {
        guard let accountId, canSave else { return }
        saving = true
        let start = allDay
            ? store.math.startOfDay(Int64(startsAt.timeIntervalSince1970 * 1000))
            : Int64(startsAt.timeIntervalSince1970 * 1000)
        var end = allDay
            ? store.math.addDays(start, max(1, allDayDays))
            : Int64(endsAt.timeIntervalSince1970 * 1000)
        end = EventTimes.clampedEnd(start: start, end: end,
                                    minimumMs: allDay ? CalendarGrid.dayMs : EventTimes.minimumMs)
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationText = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let joinText = joinUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesText = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok: Bool
            if let event = draft.event {
                let args = UpdateEventArgs(
                    eventId: event.eventId, summary: summaryText,
                    description: notesText.isEmpty ? nil : notesText,
                    location: locationText.isEmpty ? nil : locationText,
                    joinUrl: joinText.isEmpty ? nil : joinText,
                    startsAt: start, endsAt: end, allDay: allDay,
                    attendees: invites, notify: true)
                ok = event.isSeriesOccurrence
                    ? await store.updateSeriesOccurrence(event, args: args)
                    : await store.update(args)
                saving = false
                if ok { store.savedOpenCard(); onSaved() }
                return
            }
            ok = await store.create(CreateEventArgs(
                accountId: accountId, calendarId: calendarId, summary: summaryText,
                description: notesText.isEmpty ? nil : notesText,
                location: locationText.isEmpty ? nil : locationText,
                joinUrl: joinText.isEmpty ? nil : joinText,
                startsAt: start, endsAt: end, allDay: allDay, attendees: invites))
            saving = false
            if ok { store.draftSaved(); onSaved() }
        }
    }
}
