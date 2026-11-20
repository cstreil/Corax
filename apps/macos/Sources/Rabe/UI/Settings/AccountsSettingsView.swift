import RabeKit
import SwiftUI

/// System group → Konten: list with provider and sync state, rename the sender
/// name, and sign out (removes the account from Rabe; the server mailbox stays).
struct AccountsSettingsView: View {
    private var model: AppModel { AppModel.shared }

    @State private var names: [Int64: String] = [:]
    @State private var removeTarget: Account?

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

                    SettingRow(title: "Abmelden",
                               hint: "Entfernt das Konto aus Rabe: Zugangsdaten, lokaler Mail-Cache und Anhänge dieses Kontos werden gelöscht. Auf dem Server bleibt alles.") {
                        Button("Konto entfernen", role: .destructive) { removeTarget = account }
                    }
                }
            }
        }
        .formStyle(.grouped)
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

    private func status(for accountId: Int64) -> String? {
        model.sync.statuses.first { $0.accountId == accountId }?.state
    }

    static func providerName(_ provider: String) -> String {
        switch provider {
        case "gmail": "Google"
        case "microsoft": "Microsoft"
        case "imap": "IMAP"
        default: provider
        }
    }

    static func syncText(_ state: String?) -> String {
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
