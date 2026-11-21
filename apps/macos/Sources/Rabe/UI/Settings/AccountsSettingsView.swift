import RabeKit
import SwiftUI

/// System group → Konten: list with provider and sync state, rename the sender
/// name, and sign out (removes the account from Rabe; the server mailbox stays).
/// M3.4 kommt der Google-Zugang dazu (Client-ID/Secret, Anleitung, „Neu
/// anmelden“ für ein Konto mit `needs_reauth`).
struct AccountsSettingsView: View {
    private var model: AppModel { AppModel.shared }

    @State private var names: [Int64: String] = [:]
    @State private var removeTarget: Account?

    /// M3.4: Google-Zugang. Die Felder werden beim Öffnen aus den
    /// Einstellungen gefüllt und erst mit „Speichern“ geschrieben — sonst
    /// ginge jeder Tastendruck als `set_settings` an den Kern.
    @State private var googleID = ""
    @State private var googleSecret = ""
    @State private var googleSeeded = false
    @State private var googleSaved = false
    @State private var helpOpen = false
    /// Konto, für das gerade der Browser offen ist.
    @State private var reauthID: Int64?
    @State private var reauthError: String?

    private var accounts: [Account] { model.mailbox.accounts }

    var body: some View {
        Form {
            if accounts.isEmpty {
                Text("Keine Konten verbunden.").foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email).fontWeight(.medium)
                            Text("\(Self.providerName(account.provider)) · \(Self.syncText(status(for: account.id)))")
                                .font(.system(size: 11))
                                .foregroundStyle(status(for: account.id) == "needs_reauth" ? .red : .secondary)
                        }
                        Spacer()
                    }

                    SettingRow(title: "Name", hint: "Erscheint als Absendername bei neuen E-Mails.") {
                        HStack(spacing: 6) {
                            TextField("Name", text: Binding(
                                get: { names[account.id] ?? account.displayName ?? "" },
                                set: { names[account.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            Button("Sichern") {
                                let name = (names[account.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                Task {
                                    if await model.mailbox.renameAccount(account.id, to: name) {
                                        names[account.id] = nil
                                    }
                                }
                            }
                            .disabled((names[account.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                        == (account.displayName ?? ""))
                        }
                    }

                    // M3.4: abgelaufene Anmeldung. Der Browserweg gilt nur für
                    // OAuth-Konten; ein IMAP-Konto braucht ein neues Passwort.
                    if Self.needsReconnect(status(for: account.id)) {
                        if Self.canReauthenticate(provider: account.provider) {
                            SettingRow(title: reauthID == account.id ? "Warte auf Browser …" : "Neu anmelden",
                                       hint: "Die Anmeldung ist abgelaufen. Ein Klick öffnet den Browser und verbindet das Konto neu.") {
                                HStack(spacing: 8) {
                                    if reauthID == account.id {
                                        ProgressView().controlSize(.small)
                                        Button("Abbrechen") { Task { await cancelReauth() } }
                                    } else {
                                        Button("Neu anmelden") { Task { await reauth(account) } }
                                            .disabled(reauthID != nil)
                                    }
                                }
                            }
                        } else {
                            Text("Die Anmeldung ist abgelaufen. Für dieses Konto muss das Passwort neu hinterlegt werden.")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        if let reauthError, reauthID == nil {
                            Label(reauthError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5)).foregroundStyle(.red)
                        }
                    }

                    SettingRow(title: "Abmelden",
                               hint: "Entfernt das Konto aus Rabe: Zugangsdaten, lokaler Mail-Cache und Anhänge dieses Kontos werden gelöscht. Auf dem Server bleibt alles.") {
                        Button("Konto entfernen", role: .destructive) { removeTarget = account }
                    }
                }
            }

            googleSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $helpOpen) { GoogleOAuthHelpSheet() }
        .onAppear(perform: seedGoogleFields)
        .alert("Konto abmelden?", isPresented: Binding(
            get: { removeTarget != nil },
            set: { if !$0 { removeTarget = nil } }
        )) {
            Button("Abmelden und entfernen", role: .destructive) {
                if let target = removeTarget {
                    let id = target.id
                    Task {
                        if await model.mailbox.removeAccount(id) {
                            model.toasts.show("\(target.email) entfernt")
                        }
                    }
                }
                removeTarget = nil
            }
            Button("Abbrechen", role: .cancel) { removeTarget = nil }
        } message: {
            Text("„\(removeTarget?.email ?? "")“ wird aus Rabe entfernt. Dabei werden die gespeicherten Zugangsdaten, der lokale Mail-Cache und die Anhänge dieses Kontos gelöscht. Deine E-Mails auf dem Server bleiben unberührt. Zum Wiederhinzufügen müsstest du das Konto neu einrichten.")
        }
    }

    // MARK: M3.4 — Google (OAuth)

    private var googleSection: some View {
        Section {
            SettingRow(title: "Client-ID",
                       hint: "OAuth-Client vom Typ „Desktop-App“ aus der Google Cloud Console. Endet meist auf .apps.googleusercontent.com.") {
                TextField("…apps.googleusercontent.com", text: $googleID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .autocorrectionDisabled()
                    .onChange(of: googleID) { _, _ in googleSaved = false }
            }
            SettingRow(title: "Client-Secret",
                       hint: "Das Secret des Desktop-Clients. Google behandelt es nicht als vertraulich; es liegt in den Einstellungen.") {
                SecureField("Client-Secret", text: $googleSecret)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onChange(of: googleSecret) { _, _ in googleSaved = false }
            }
            SettingRow(title: "Speichern",
                       hint: "Gilt sofort für die nächste Anmeldung, ohne Neustart.") {
                HStack(spacing: 8) {
                    Button("Speichern") { saveGoogle() }.disabled(!googleDirty)
                    Button("Anleitung") { helpOpen = true }
                    if googleSaved {
                        Label("Gespeichert", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(.green)
                    }
                }
            }
            // Der Hinweis auf die 7-Tage-Grenze im Modus „Testing“ (M3.4).
            Label {
                Text("Solange deine Google-App im Modus „Testing“ ist, läuft die Anmeldung nach 7 Tagen ab. Dann hier „Neu anmelden“.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.orange)
        } header: {
            Text("Google (OAuth)")
        }
    }

    private var storedGoogleID: String {
        (model.settings.raw[GoogleOAuthSetup.clientIDKey] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedGoogleSecret: String {
        (model.settings.raw[GoogleOAuthSetup.clientSecretKey] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var googleDirty: Bool {
        googleID.trimmingCharacters(in: .whitespacesAndNewlines) != storedGoogleID
            || googleSecret.trimmingCharacters(in: .whitespacesAndNewlines) != storedGoogleSecret
    }

    private func seedGoogleFields() {
        guard !googleSeeded else { return }
        googleSeeded = true
        googleID = storedGoogleID
        googleSecret = storedGoogleSecret
    }

    /// Schreibt beide Felder über die vorhandenen Einstellungen
    /// (`googleClientId`/`googleClientSecret`); der Kern übernimmt sie sofort
    /// (`set_settings` → `apply_oauth_settings`).
    private func saveGoogle() {
        model.settings.set(GoogleOAuthSetup.clientIDKey,
                           googleID.trimmingCharacters(in: .whitespacesAndNewlines))
        model.settings.set(GoogleOAuthSetup.clientSecretKey,
                           googleSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        googleSaved = true
    }

    /// `reauth_account`: Browser öffnen, Token erneuern. Logzeile ohne Adresse.
    private func reauth(_ account: Account) async {
        guard let client = model.client else { return }
        reauthID = account.id
        reauthError = nil
        PerfLog.shared.write(OAuthLog.start(provider: account.provider))
        let started = Date()
        do {
            let updated = try await client.reauthAccount(id: account.id)
            PerfLog.shared.write(OAuthLog.done(ok: true, milliseconds: milliseconds(since: started)))
            model.toasts.show("\(updated.email) ist wieder verbunden")
            await model.mailbox.refreshAccounts()
            model.sync.refreshSoon()
        } catch {
            PerfLog.shared.write(OAuthLog.done(ok: false, milliseconds: milliseconds(since: started),
                                               reason: OAuthErrorText.reason(for: error)))
            reauthError = OAuthErrorText.message(for: error)
        }
        reauthID = nil
    }

    private func cancelReauth() async {
        PerfLog.shared.write(OAuthLog.cancel)
        if let client = model.client { try? await client.cancelOAuth() }
    }

    private func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: Helpers

    private func status(for accountId: Int64) -> String? {
        model.sync.statuses.first { $0.accountId == accountId }?.state
    }

    /// M3.4: nur dann gibt es „Neu anmelden“.
    nonisolated static func needsReconnect(_ state: String?) -> Bool { state == "needs_reauth" }

    /// Der Browserweg funktioniert nur für OAuth-Konten; IMAP braucht ein
    /// neues Passwort (der Konten-Editor für Passwörter ist noch gesperrt).
    nonisolated static func canReauthenticate(provider: String) -> Bool {
        provider == "gmail" || provider == "microsoft"
    }

    nonisolated static func providerName(_ provider: String) -> String {
        switch provider {
        case "gmail": "Google"
        case "microsoft": "Microsoft"
        case "imap": "IMAP"
        default: provider
        }
    }

    nonisolated static func syncText(_ state: String?) -> String {
        switch state {
        case "needs_reauth": "Abgemeldet – bitte neu verbinden"
        case "offline": "Offline"
        case "error": "Synchronisierung fehlgeschlagen"
        case "syncing": "Wird synchronisiert …"
        case "idle": "Aktuell"
        default: "Bereit"
        }
    }
}

/// M3.4: die Anleitung aus `docs/native-ui/GOOGLE-OAUTH.md` als Blatt. Der Text
/// steht hier und nicht als Bundle-Ressource, weil `Package.swift` (Coder 1)
/// dafür angefasst werden müsste; Inhalt und Doku bleiben gleich.
struct GoogleOAuthHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var console: URL { URL(string: "https://console.cloud.google.com/projectcreate")! }
    private var gmailAPI: URL { URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")! }
    private var consent: URL { URL(string: "https://console.cloud.google.com/apis/credentials/consent")! }
    private var credentials: URL { URL(string: "https://console.cloud.google.com/apis/credentials")! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Google-Konto einrichten").font(.system(size: 17, weight: .semibold))
                Text("Dauert etwa fünf Minuten. Die Client-ID gehört zu deiner eigenen Google-Cloud-App, nicht zu Corax.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                step(1, "Projekt anlegen", "In der Google Cloud Console ein neues Projekt erstellen (oder ein vorhandenes wählen).") {
                    Link("Google Cloud Console", destination: console)
                }
                step(2, "Gmail-API aktivieren", "APIs und Dienste → Bibliothek → Gmail API → Aktivieren.") {
                    Link("Gmail API", destination: gmailAPI)
                }
                step(3, "Zustimmungsbildschirm", "Typ „Extern“, Modus „Testing“, und dich selbst als Testnutzer eintragen. Nur Testnutzer dürfen sich anmelden, solange die App nicht geprüft ist.") {
                    Link("Zustimmungsbildschirm", destination: consent)
                }
                step(4, "OAuth-Client anlegen", "Anmeldedaten → Anmeldedaten erstellen → OAuth-Client-ID. Anwendungstyp „Desktop-App“. Die angezeigte Client-ID und das Client-Secret kopieren.") {
                    Link("Anmeldedaten", destination: credentials)
                }
                step(5, "In Corax eintragen", "Einstellungen → Konten → Google (OAuth): Client-ID und Client-Secret einfügen und speichern.") { EmptyView() }
                step(6, "Anmelden", "„Konto hinzufügen …“ → „Mit Google anmelden“. Der Browser öffnet sich; nach der Zustimmung schließt sich der Kreis.") { EmptyView() }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sieben Tage im Modus „Testing“").font(.system(size: 12, weight: .medium))
                    Text("Solange die App im Modus „Testing“ ist, läuft die Anmeldung nach sieben Tagen ab. Dann hier „Neu anmelden“ — das erneuert sie. Wer die App veröffentlichen will, braucht die Prüfung durch Google (Sicherheitsaudit für eingeschränkte Berechtigungen).")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Berechtigungen").font(.system(size: 12, weight: .medium))
                    Text("Corax fragt genau diese vier an: https://mail.google.com/, openid, email, profile. Sonst nichts.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alternative").font(.system(size: 12, weight: .medium))
                    Text("Ohne Google-App geht Gmail auch per IMAP mit einem App-Passwort (Konto mit Passwort hinzufügen). Dafür muss im Google-Konto die Bestätigung in zwei Schritten an sein.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 560)
    }

    private func step(_ number: Int, _ title: String, _ text: String,
                      @ViewBuilder link: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(number).").font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            link().font(.system(size: 11.5))
        }
    }
}
