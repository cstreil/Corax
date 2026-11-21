import RabeKit
import SwiftUI

/// M3.2: System → Updates. Die Schalter schreiben direkt in Sparkle; in der
/// Sandbox und in Hook-Builds bleibt der Updater aus und die Seite erklärt es.
struct UpdatesSettingsView: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section("Updates") {
                SettingRow(title: "Version", hint: "Aus dem Bundle.") {
                    Text(updater.versionText)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("Automatisch nach Updates suchen", isOn: $updater.automaticChecks)
                    .disabled(!updater.available)
                Toggle("Updates automatisch laden", isOn: $updater.automaticDownloads)
                    .disabled(!updater.available)
                if let last = updater.lastResult {
                    Text(last)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button("Jetzt nach Updates suchen") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }

            Section("Sicherheit") {
                Text("Updates sind mit einem EdDSA-Schlüssel signiert, der zum Schlüssel "
                     + "im Programm passt. Ohne gültige Signatur wird ein Update abgelehnt.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Die App ist nicht bei Apple notarisiert. Beim ersten Download warnt "
                     + "macOS einmal; Updates selbst laufen ohne Nachfrage des Systems.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !updater.available {
                Section("In dieser Instanz aus") {
                    Text((updater.disabledReason.map(Updater.explanation(for:)) ?? "Der Updater ist aus.")
                         + " Die Sandbox zieht nie ein echtes Update.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension Updater {
    /// Für die Einstellungen: der Grund im Klartext.
    static func explanation(for reason: String) -> String {
        switch reason {
        case "sandbox": "Der Updater läuft nur im Release-Bundle."
        case "test_feed_not_local": "Der Test-Feed ist nicht lokal — das ist in Sandbox und Hook-Builds nicht erlaubt."
        case "no_feed": "Im Bundle fehlt die Update-Adresse (SUFeedURL)."
        case "no_public_key": "Im Bundle fehlt der Update-Schlüssel (SUPublicEDKey)."
        case "insecure_feed": "Die Update-Adresse ist nicht verschlüsselt — der Updater lädt nur über https."
        case "switch_off": "Der Updater wurde über CORAX_UPDATER_DISABLE abgeschaltet."
        case "start_failed": "Sparkle konnte nicht starten."
        default: "Grund: \(reason)"
        }
    }
}
