import CoraxKit
import SwiftUI

/// Organization group → Kalender (M2.2, requirement 5): week start, meeting
/// reminder, and per calendar default, colour, visibility and "sync now".
///
/// M2.12 adds "Konto verbinden" (CalDAV server + mailbox address + app
/// password). The password only travels to the core, which stores it in the
/// keychain (`Slot::CaldavPassword`); this view drops its copy after a
/// successful connect and never writes it anywhere.
struct CalendarSettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var s: SettingsStore { model.settings }
    private var store: CalendarStore { model.calendar }
    private var writeAccess: WriteAccess { model.writeAccess }

    private let reminderChoices = [0, 5, 10, 15, 30, 60]
    private let swatches = ["#e5484d", "#f76808", "#f5b301", "#16a34a", "#0d9488",
                            "#2563eb", "#7c3aed", "#db2777", "#6d6a64"]

    // MARK: Konto verbinden (M2.12)

    @State private var accountId: Int64?
    @State private var server = "https://caldav.icloud.com"
    @State private var username = ""
    @State private var password = ""

    private var accounts: [Account] { model.mailbox.accounts }
    private var selectedAccount: Account? {
        accounts.first { $0.id == accountId } ?? accounts.first
    }
    private var canConnect: Bool {
        selectedAccount != nil && !store.connecting
            && !server.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

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

            Section("Konto verbinden") {
                statusRow
                connectForm
                if !writeAccess.allowed {
                    writeGateHint
                }
            }

            Section("Kalender") {
                if store.calendars.isEmpty {
                    Text("Keine Kalender verbunden. Verbinde oben ein CalDAV-Konto.")
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
            prefillIfNeeded()
            await store.loadCalendars()
            // Die Statuszeile lebt von `lastSyncedAt`; der Kern meldet dem
            // Kalender nur „CalendarUpdated“ (Termine), nicht die neue
            // Kalenderliste. Solange die Seite offen ist, alle fünf Sekunden
            // nachlesen, damit „Letzter Abgleich“ und der Fehlerzustand stimmen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await store.loadCalendars()
            }
        }
        .onChange(of: accounts.map(\.id)) { _, _ in prefillIfNeeded() }
    }

    // MARK: Status line (requirement 2)

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                if store.lastSyncUnconfirmed {
                    Text("Der letzte manuelle Abgleich lief ohne sichtbaren Fortschritt.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if store.busy || store.connecting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusSymbol: String {
        if store.connectError != nil { return "exclamationmark.triangle.fill" }
        switch store.syncStatus {
        case .noCalendars: return "circle.dashed"
        case .neverSynced: return "exclamationmark.circle"
        case .current: return "checkmark.circle.fill"
        case .stale: return "exclamationmark.circle.fill"
        }
    }

    private var statusTint: Color {
        if store.connectError != nil { return .red }
        switch store.syncStatus {
        case .noCalendars: return .secondary
        case .neverSynced: return .orange
        case .current: return .green
        case .stale: return .orange
        }
    }

    private var statusText: String {
        if let error = store.connectError {
            return "Verbindung fehlgeschlagen: \(error)"
        }
        switch store.syncStatus {
        case .noCalendars:
            return "Kein Kalender verbunden."
        case .neverSynced:
            return "Kalender vorhanden, aber noch nie abgeglichen."
        case .current(let at):
            return "Letzter Abgleich: \(syncStamp(at))."
        case .stale(let at):
            return "Letzter Abgleich: \(syncStamp(at)) – seitdem keiner. "
                + "Anmeldung fehlt möglicherweise: Konto verbinden oder App-Passwort erneuern."
        }
    }

    private func syncStamp(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "'heute', HH:mm" : "dd.MM.yyyy, HH:mm"
        return formatter.string(from: date) + " Uhr"
    }

    // MARK: Connect form (requirement 1)

    @ViewBuilder
    private var connectForm: some View {
        if accounts.count > 1 {
            Picker("Konto", selection: Binding(
                get: { selectedAccount?.id },
                set: { id in
                    accountId = id
                    if let account = accounts.first(where: { $0.id == id }) { username = account.email }
                    store.clearConnectFeedback()
                })) {
                ForEach(accounts) { account in
                    Text(account.label).tag(Optional(account.id))
                }
            }
        }
        SettingRow(title: "Server",
                   hint: "iCloud: caldav.icloud.com. Andere Anbieter tragen hier ihre CalDAV-Adresse ein.") {
            TextField("https://caldav.icloud.com", text: Binding(
                get: { server },
                set: { server = $0; store.clearConnectFeedback() }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .autocorrectionDisabled()
        }
        SettingRow(title: "Benutzer",
                   hint: "Die Apple-ID bzw. E-Mail-Adresse des Kontos.") {
            TextField("name@example.com", text: Binding(
                get: { username },
                set: { username = $0; store.clearConnectFeedback() }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .autocorrectionDisabled()
        }
        SettingRow(title: "App-Passwort",
                   hint: "Kein Apple-ID-Passwort: eines unter appleid.apple.com → Anmeldung und Sicherheit → App-Passwörter erzeugen.") {
            SecureField("xxxx-xxxx-xxxx-xxxx", text: Binding(
                get: { password },
                set: { password = $0; store.clearConnectFeedback() }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
        }
        SettingRow(title: "Verbinden",
                   hint: "Prüft Server und Anmeldung, legt die gefundenen Kalender an; der erste Abgleich startet sofort.") {
            Button {
                guard let account = selectedAccount else { return }
                let serverURL = server
                let user = username
                let secret = password
                Task {
                    let ok = await store.connectCalendar(accountId: account.id, server: serverURL,
                                                         username: user, password: secret)
                    // Das Passwort bleibt nicht in der Ansicht (der Kern hat es).
                    if ok { password = "" }
                }
            } label: {
                HStack(spacing: 6) {
                    if store.connecting { ProgressView().controlSize(.small) }
                    Text(store.connecting ? "Verbinde …" : "Verbinden")
                }
            }
            .disabled(!canConnect || !writeAccess.allowed)
            .keyboardShortcut(.defaultAction)
        }
        if let notice = store.connectNotice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(.green)
        }
        if let error = store.connectError {
            VStack(alignment: .leading, spacing: 3) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                Text("Prüfe Server, E-Mail-Adresse und App-Passwort. "
                     + "Ein falsches Passwort meldet der Server als Anmeldefehler.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var writeGateHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
            Text("Nur-Lesen-Modus: „Postfach → Änderungen erlauben“, um ein Konto zu verbinden.")
                .font(.system(size: 11))
            Spacer(minLength: 6)
            if writeAccess.canToggle {
                Button("Änderungen erlauben") { writeAccess.set(true) }
                    .font(.system(size: 11))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
    }

    private func prefillIfNeeded() {
        guard accountId == nil, let first = accounts.first else { return }
        accountId = first.id
        if username.isEmpty { username = first.email }
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
