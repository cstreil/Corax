import RabeKit
import SwiftUI

/// Organization group → Kalender (M2.2, requirement 5): week start, meeting
/// reminder, and per calendar default, colour, visibility and "sync now".
/// Connecting a calendar (OAuth today, CalDAV later) is deliberately absent —
/// that part belongs to M3; only the commands that already exist are used.
struct CalendarSettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var s: SettingsStore { model.settings }
    private var store: CalendarStore { model.calendar }

    private let reminderChoices = [0, 5, 10, 15, 30, 60]
    private let swatches = ["#e5484d", "#f76808", "#f5b301", "#16a34a", "#0d9488",
                            "#2563eb", "#7c3aed", "#db2777", "#6d6a64"]

    var body: some View {
        Form {

            Section("Woche") {
                SettingPickerRow(title: "Wochenbeginn",
                                 hint: "Erster Tag in Wochen- und Monatsansicht.",
                                 selection: Binding(
                                    get: { s.calendarWeekStart },
                                    set: { s.set("calendarWeekStart", $0) })) {
                    Text("Montag").tag("monday")
                    Text("Sonntag").tag("sunday")
                }
                SettingPickerRow(title: "Erinnerung vor Terminen",
                                 hint: "Desktop-Hinweis vor einem Termin; „Aus“ schaltet ihn ab.",
                                 selection: Binding(
                                    get: { s.meetingNotifyLeadMinutes },
                                    set: { s.set("meetingNotifyLeadMinutes", $0) })) {
                    ForEach(reminderChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Aus" : "\(minutes) Minuten vorher").tag(minutes)
                    }
                }
            }

            Section("Kalender") {
                if store.calendars.isEmpty {
                    Text("Keine Kalender verbunden. Kalender verbinden kommt mit der OAuth-Phase (M3).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.calendars) { calendar in
                    row(calendar)
                }
                SettingRow(title: "Jetzt synchronisieren",
                           hint: "Stößt einen Abgleich aller verbundenen Kalender an.") {
                    Button("Jetzt synchronisieren") {
                        Task { await store.syncNow() }
                    }
                    .disabled(store.busy || store.calendars.isEmpty)
                }
            }

            Section("Anzeige") {
                SettingHintRow(title: "Kalender in der Seitenleiste",
                               hint: "Farbe, Sichtbarkeit und Standardkalender legst du hier fest; die Sidebar im Kalender zeigt dieselben Einträge.")
                SettingHintRow(title: "Standardkalender",
                               hint: "Neue Termine landen in diesem Kalender, solange du im Dialog keinen anderen wählst.")
            }
        }
        .formStyle(.grouped)
        .disabled(!s.loaded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            store.settings = s
            await store.loadCalendars()
        }
    }

    private func row(_ calendar: CalendarCollection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(title: calendar.label,
                       hint: "\(accountLabel(calendar.accountId))\(calendar.readOnly ? " · schreibgeschützt" : "")") {
                HStack(spacing: 8) {
                    if calendar.isDefault {
                        Text("Standard")
                            .font(.system(size: 9.5, weight: .semibold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.16)))
                    } else if !calendar.readOnly {
                        Button("Als Standard") {
                            Task { await store.setDefaultCalendar(calendar.id) }
                        }
                        .font(.system(size: 11))
                    }
                    Toggle("Anzeigen", isOn: Binding(
                        get: { calendar.enabled },
                        set: { enabled in Task { await store.setCalendarEnabled(calendar.id, enabled: enabled) } }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                ForEach(swatches, id: \.self) { hex in
                    let selected = CalendarChrome.hex(calendar.color) == CalendarChrome.hex(hex)
                    Button {
                        Task { await store.setCalendarColor(calendar.id, color: hex) }
                    } label: {
                        Circle()
                            .fill(CalendarChrome.hex(hex) ?? .gray)
                            .frame(width: 14, height: 14)
                            .overlay {
                                if selected {
                                    Circle().strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5)
                                        .padding(-2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
                Button("Automatisch") {
                    Task { await store.setCalendarColor(calendar.id, color: nil) }
                }
                .font(.system(size: 10.5))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func accountLabel(_ id: Int64) -> String {
        model.mailbox.accounts.first { $0.id == id }?.label ?? "Konto \(id)"
    }
}
