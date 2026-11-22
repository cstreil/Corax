import Foundation

// Konto per App-Passwort: „Verbindung testen“ und „Hinzufügen“.
//
// Der Kern schickt zwei Formen, beide englisch:
//
// 1. `test_connection` antwortet mit `ConnectionTestResult.error`, und darin
//    steht bereits der IPC-Text des Kerns:
//    `{"code":"imap","message":"connect imap.example.invalid:993: failed to
//    lookup address information: …"}` (`lib.rs`, `to_ipc_json`).
// 2. `add_account_password` prüft dieselbe Verbindung und verpackt diesen Text
//    in `CoreError::Auth`: `{"code":"auth","message":"auth failed:{…}"}`.
//    Ohne Auspacken stünde dort „Anmeldung fehlgeschlagen“, obwohl in Wahrheit
//    bloß der Server-Name nicht auflösbar ist.
//
// Regel: Die Oberfläche zeigt nur Sätze aus dieser Datei. Der rohe Rust-Text
// wird nie durchgereicht — er kann Hostnamen und Antworten des Servers
// enthalten, und ins Log gehört von einem Verbindungsversuch nur das Ergebnis.
public enum AccountConnectionText {
    /// Für `ConnectionTestResult.error` (bereits JSON, siehe oben).
    public static func message(forTestError json: String) -> String {
        guard let inner = parse(json) else { return generic }
        return translation(code: inner.code, detail: inner.message)
    }

    /// Für den geworfenen Fehler von `addAccount`.
    public static func message(for error: Error) -> String {
        switch CoraxClientError.from(error) {
        case .notStarted:
            return "Der Kern läuft noch nicht. Bitte die App neu starten."
        case .decode, .host:
            return generic
        case .core(let code, let message):
            // Absagen aus dem Client selbst (Nur-Lesen-Modus, nicht
            // freigegebener Befehl) sind schon deutsch.
            if localCodes.contains(code) {
                return Strings.errorText(.core(code: code, message: message))
            }
            // `CoreError::Auth` legt den inneren IPC-Text in die Meldung.
            if let inner = parse(embeddedJSON(in: message)) {
                return translation(code: inner.code, detail: inner.message)
            }
            return translation(code: code, detail: message)
        }
    }

    // MARK: Kerne

    private static func translation(code: String, detail: String) -> String {
        let lower = detail.lowercased()
        switch code {
        case "auth":
            // `imap::connect` meldet einen abgelehnten Login als `auth`.
            return rejectedLogin
        case "imap":
            if lower.contains("lookup address") || lower.contains("nodename nor servname")
                || lower.contains("no such host") || lower.contains("name or service not known") {
                return hostNotFound
            }
            if lower.contains("timed out") || lower.contains("timeout") { return timedOut }
            if lower.contains("connection refused") || lower.contains("network is unreachable")
                || lower.contains("connection reset") {
                return portRefused
            }
            return serverRefused
        case "tls":
            return tlsFailed
        case "network":
            return offline
        case "keyring":
            return keyringFailed
        default:
            return generic
        }
    }

    /// `{"code":…,"message":…}` aus einem Text; `nil` heißt „kein IPC-Text“.
    private static func parse(_ json: String) -> (code: String, message: String)? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String else { return nil }
        return (code, object["message"] as? String ?? "")
    }

    /// Der JSON-Teil in `auth failed: {"code":…}`.
    private static func embeddedJSON(in message: String) -> String {
        guard let start = message.firstIndex(of: "{") else { return "" }
        return String(message[start...])
    }

    // MARK: Texte

    static let rejectedLogin =
        "Der Server hat die Anmeldung abgelehnt. Prüfe E-Mail-Adresse und App-Passwort; viele Anbieter brauchen dafür ein eigenes App-Passwort."
    static let hostNotFound =
        "Der Server-Name wurde nicht gefunden. Prüfe die IMAP-Adresse, zum Beispiel imap.mail.me.com."
    static let timedOut = "Der Server antwortet nicht. Prüfe Adresse, Port und deine Internetverbindung."
    static let portRefused =
        "Der Server nimmt auf diesem Port keine Verbindung an. Prüfe den IMAP-Port (meist 993)."
    static let serverRefused = "Der Server hat die Verbindung abgelehnt. Prüfe IMAP-Adresse und Port."
    static let tlsFailed =
        "Die sichere Verbindung ist fehlgeschlagen. Prüfe den IMAP-Port (meist 993) und ob der Server TLS unterstützt."
    static let offline = "Der Server ist nicht erreichbar. Prüfe deine Internetverbindung."
    static let keyringFailed = "Das Passwort ließ sich nicht im sicheren Speicher ablegen."
    static let generic = "Die Verbindung ist fehlgeschlagen. Prüfe Server, Port und Zugangsdaten."

    /// Absagen aus dem Client (`CommandPolicy`, `WriteAccess`): dort steht schon
    /// deutscher Text, den `Strings` kennt — dieselbe Liste wie
    /// `OAuthErrorText.localCodes`.
    static let localCodes: Set<String> = [
        "read_only", "command_not_allowed", "action_not_allowed", "pending_audit", "host_stopped",
    ]
}
