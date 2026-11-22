import CoraxKit
import SwiftUI

/// System group → KI-Clients (MCP): server switch, port, permissions, the
/// access token (masked, copied on click) and the client helpers.
///
/// The token and the client snippets contain the bearer secret: they are shown
/// only on request and never logged (`McpStore` holds them in memory only).
struct McpSettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var s: SettingsStore { model.settings }
    private var store: McpStore { model.mcp }
    private var writeAccess: WriteAccess { model.writeAccess }
    /// Name des Eintrags, wie ihn der Host meldet (`corax`, im Standard `comail`).
    private var mcpName: String { store.status?.name ?? "comail" }

    @State private var portText = ""
    @State private var instructions = ""
    /// Der gezeigte Konfig-Ausschnitt. Der Text steckt mit im Item: ein
    /// separates `@State` neben `.sheet(item:)` wird beim ersten Präsentieren
    /// aus dem alten Zustand gelesen und das Blatt bliebe leer (M4-Befund).
    private struct ShownSnippet: Identifiable {
        let client: McpClientInfo
        let text: String
        var id: String { client.id }
    }
    @State private var shownSnippet: ShownSnippet?
    @State private var confirmRegenerate = false

    var body: some View {
        Form {

            Section("MCP-Server") {
                SettingToggleRow(title: "KI-Apps Zugriff auf Corax erlauben",
                                 hint: "Startet einen lokalen MCP-Server, nur auf diesem Computer (127.0.0.1). Apps brauchen das Zugriffstoken.",
                                 isOn: Binding(get: { s.mcpEnabled }, set: { s.set("mcpEnabled", $0) }))
                SettingRow(title: "Status", hint: statusHint) {
                    HStack(spacing: 6) {
                        Circle().fill(store.status?.running == true ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 8, height: 8)
                        Text(statusText).font(.system(size: 12))
                    }
                }
                if let status = store.status, status.running {
                    SettingRow(title: "Server-URL", hint: "Streamable-HTTP-Endpunkt für MCP-Clients.") {
                        Text(status.url).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                SettingRow(title: "Port", hint: "Nur ändern, wenn eine andere App diesen Port nutzt. Füge deine KI-Apps danach neu hinzu.") {
                    HStack(spacing: 6) {
                        TextField("Port", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Button("Sichern") { savePort() }
                            .disabled(!portIsValid || Int(portText) == s.mcpPort)
                    }
                }
                if !portIsValid {
                    Text("Der Port muss eine Zahl zwischen 1024 und 65535 sein.")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
            }

            Section("Zugriffstoken") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Token")
                    HStack(spacing: 6) {
                        Text(store.displayedToken)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 12)
                        Button(store.tokenRevealed ? "Ausblenden" : "Anzeigen") {
                            if store.tokenRevealed {
                                store.hideToken()
                            } else {
                                Task { await store.revealToken() }
                            }
                        }
                        Button("Kopieren") {
                            Task {
                                if await store.copyToken() { model.toasts.show("Token kopiert") }
                            }
                        }
                        Button("Neu erzeugen") { confirmRegenerate = true }
                            .disabled(store.busy)
                    }
                    Text("Wird von KI-Apps als Bearer-Token gesendet. Wer es hat, kann deine E-Mails auf diesem Computer lesen.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Berechtigungen") {
                SettingToggleRow(title: "Entwürfe anlegen und ändern",
                                 isOn: Binding(get: { s.mcpAllowDrafts }, set: { s.set("mcpAllowDrafts", $0) }))
                SettingToggleRow(title: "Entwürfe senden",
                                 hint: "Der Versand läuft weiter über das Zeitfenster für „Senden rückgängig“.",
                                 isOn: Binding(get: { s.mcpAllowSend }, set: { s.set("mcpAllowSend", $0) }))
                SettingToggleRow(title: "Unterhaltungen bearbeiten",
                                 hint: "Archivieren, in den Papierkorb, Label setzen, verschieben, markieren.",
                                 isOn: Binding(get: { s.mcpAllowActions }, set: { s.set("mcpAllowActions", $0) }))
                SettingToggleRow(title: "Endgültig löschen erlauben",
                                 hint: "Nur für Nachrichten, die schon im Papierkorb liegen; braucht zusätzlich die Bearbeiten-Erlaubnis.",
                                 isOn: Binding(get: { s.mcpAllowPermanentDelete }, set: { s.set("mcpAllowPermanentDelete", $0) }))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Eigene Hinweise für KI-Apps").font(.system(size: 12))
                    TextEditor(text: $instructions)
                        .font(.system(size: 12))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    Text("Wird MCP-Clients zusätzlich zu den Standardhinweisen mitgeteilt.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Hinweise sichern") {
                        s.set("mcpInstructions", instructions)
                        model.toasts.show("Hinweise gespeichert")
                    }
                    .disabled(instructions == s.mcpInstructions)
                }
            }

            Section("Clients") {
                if store.clients.isEmpty {
                    Text("Keine Client-Vorlagen gemeldet.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(store.clients) { client in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(client.name).fontWeight(.medium)
                                if client.detected {
                                    Text("gefunden").font(.system(size: 10))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.green.opacity(0.15)))
                                }
                            }
                            Text(Self.clientDetail(client))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Snippet kopieren") {
                            Task {
                                if await store.copySnippet(for: client.id) {
                                    model.toasts.show("Snippet kopiert")
                                }
                            }
                        }
                        Button("Anzeigen") {
                            Task {
                                if let text = await store.snippet(for: client.id) {
                                    shownSnippet = ShownSnippet(client: client, text: text)
                                }
                            }
                        }
                        if client.method != .copy {
                            Button("Einrichten") {
                                Task {
                                    if let result = await store.install(client.id) {
                                        model.toasts.show(result.message)
                                    }
                                }
                            }
                            .disabled(store.busy || !writeAccess.allowed)
                            .help(writeAccess.allowed
                                  ? "Trägt „\(mcpName)“ in die Konfiguration ein und sichert die Datei vorher als .bak."
                                  : "Nur mit „Änderungen erlauben“ (Postfach-Menü).")
                        }
                    }
                }
                // M4: Der Name kommt vom Host (`McpStatus.name`); die native
                // Instanz schreibt `corax` und lässt den `comail`-Eintrag der
                // Tauri-App stehen.
                Text("Der Eintrag heißt „\(mcpName)“. Der comail-Eintrag der Tauri-App bleibt erhalten — beide können nebeneinander stehen.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Letzte Aufrufe") {
                if store.activity.isEmpty {
                    Text("Noch keine Aufrufe.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(store.activity.suffix(8).reversed()) { call in
                    HStack(spacing: 8) {
                        Image(systemName: call.ok ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(call.ok ? .green : .red)
                        Text(call.tool).font(.system(size: 12, design: .monospaced))
                        Text(call.client).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if let error = call.error {
                            Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                        }
                        Text(Self.timeText(call.at)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(s.mcpPort)
            instructions = s.mcpInstructions
        }
        .onChange(of: s.mcpPort) { _, newValue in portText = String(newValue) }
        .sheet(item: $shownSnippet) { shown in
            VStack(alignment: .leading, spacing: 10) {
                Text("Snippet für \(shown.client.name)").font(.headline)
                Text("Enthält das Zugriffstoken. Nur in die Konfiguration dieses Clients einfügen.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    Text(shown.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 240)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                HStack {
                    Spacer()
                    Button("Kopieren") {
                        Task {
                            if await store.copySnippet(for: shown.client.id) { model.toasts.show("Snippet kopiert") }
                        }
                    }
                    Button("Fertig") { shownSnippet = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 620)
        }
        .alert("Neues Token erzeugen?", isPresented: $confirmRegenerate) {
            Button("Neu erzeugen", role: .destructive) {
                Task {
                    if await store.regenerateToken() {
                        model.toasts.show("Neues Token erzeugt – Clients neu einrichten")
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Das alte Token wird ungültig. Jede KI-App, die es benutzt, muss danach neu eingerichtet werden.")
        }
    }

    // MARK: Helpers

    private var portIsValid: Bool {
        guard let value = Int(portText) else { return false }
        return value >= 1024 && value <= 65535
    }

    private func savePort() {
        guard let value = Int(portText), value >= 1024, value <= 65535 else { return }
        s.set("mcpPort", value)
    }

    private var statusText: String {
        guard let status = store.status else { return "…" }
        if status.running {
            let n = Int(status.clientCount)
            return n == 0 ? "Läuft" : (n == 1 ? "Läuft · 1 App verbunden" : "Läuft · \(n) Apps verbunden")
        }
        if let error = status.error, !error.isEmpty { return "Start fehlgeschlagen: \(error)" }
        return s.mcpEnabled ? "Startet …" : "Aus"
    }

    private var statusHint: String {
        if let error = store.status?.error, !error.isEmpty, store.status?.running != true {
            return "Der Server konnte nicht starten: \(error)"
        }
        return "Der Server hört nur auf 127.0.0.1, also nur auf diesem Computer."
    }

    private static func clientDetail(_ client: McpClientInfo) -> String {
        var text = methodText(client.method)
        if let path = client.configPath { text += " · " + path }
        return text
    }

    private static func methodText(_ method: McpInstallMethod) -> String {
        switch method {
        case .command: "Befehl"
        case .deeplink: "Ein-Klick-Link"
        case .write: "Konfigurationsdatei"
        case .copy: "Kopieren"
        }
    }

    private static func timeText(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
