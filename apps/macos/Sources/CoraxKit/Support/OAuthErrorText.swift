import Foundation

// M3.4 — Google-Anmeldung über OAuth.
//
// Drei reine Regeln, damit die Oberfläche weder rohe Rust-Texte zeigt noch
// selbst raten muss, was im Log stehen darf:
//
// 1. `OAuthErrorText` macht aus den Fehlern des Kerns deutschen Text und einen
//    kurzen Grund für die Logzeile. Der Kern liefert die Fälle als
//    `CoreError::Auth("…")` aus `comail-core/src/oauth/flow.rs` und
//    `loopback.rs`: fehlende Client-ID, „sign-in cancelled“, „sign-in timed
//    out“, „oauth state mismatch“, abgelehnter Token-Tausch und fehlende
//    Mailadresse. Alles andere bleibt ein allgemeiner Satz — ein Rust-Text
//    gehört nicht in die Oberfläche.
// 2. `OAuthLog` baut die drei Zeilen `oauth start`, `oauth done` und
//    `oauth cancel`. Sie tragen Provider, Ergebnis, Dauer und einen Grund,
//    **nie** Token, Code, Client-Secret oder Mailadresse.
// 3. `GoogleOAuthSetup` sagt der Oberfläche, ob überhaupt eine Client-ID da ist
//    (Einstellungen oder `COMAIL_GOOGLE_CLIENT_ID`, dieselbe Reihenfolge wie
//    `resolve_credentials` im Kern).

public enum OAuthErrorText {
    /// Der Satz, den der Nutzer sieht.
    public static func message(for error: Error) -> String {
        guard let error = error as? CoraxClientError else { return generic }
        switch error {
        case .notStarted:
            return "Der Kern läuft noch nicht. Bitte die App neu starten."
        case .decode, .host:
            return "Die Anmeldung ist fehlgeschlagen. Bitte erneut versuchen."
        case .core(let code, let message):
            let lower = message.lowercased()
            if lower.contains("no oauth app configured") { return missingClientID }
            if lower.contains("cancel") { return cancelled }
            if lower.contains("timed out") || lower.contains("timeout") { return timedOut }
            if lower.contains("state mismatch") { return stateMismatch }
            if lower.contains("token exchange failed") { return rejected }
            if lower.contains("could not determine account email") { return noAddress }
            // Eigene, bereits deutsche Absagen aus `CoraxClient.refuse`
            // (Nur-Lesen-Modus, nicht freigegebener Befehl) bleiben stehen.
            if Self.localCodes.contains(code) { return Strings.errorText(error) }
            return generic
        }
    }

    /// Kurzer Grund für `oauth done … reason=…` — bewusst ohne Inhalt aus der
    /// Fehlermeldung, damit keine Adresse oder Antwort von Google im Log landet.
    public static func reason(for error: Error) -> String {
        guard let error = error as? CoraxClientError else { return "other" }
        switch error {
        case .notStarted: return "core_not_started"
        case .decode: return "decode"
        case .host: return "host"
        case .core(let code, let message):
            let lower = message.lowercased()
            if lower.contains("no oauth app configured") { return "missing_client_id" }
            if lower.contains("cancel") { return "cancelled" }
            if lower.contains("timed out") || lower.contains("timeout") { return "timeout" }
            if lower.contains("state mismatch") { return "state_mismatch" }
            if lower.contains("token exchange failed") { return "token_exchange" }
            if lower.contains("could not determine account email") { return "no_address" }
            return code
        }
    }

    // MARK: Texte

    static let missingClientID =
        "Es ist keine Google-Client-ID hinterlegt. Trage sie unter Einstellungen → Konten → Google (OAuth) ein."
    static let cancelled = "Die Anmeldung wurde abgebrochen."
    static let timedOut = "Der Browser hat nicht geantwortet. Bitte die Anmeldung erneut starten."
    static let stateMismatch =
        "Die Anmeldung ließ sich nicht sicher zuordnen. Bitte erneut starten."
    static let rejected =
        "Google hat die Anmeldung abgelehnt. Prüfe Client-ID und Client-Secret und ob der Zustimmungsbildschirm die Gmail-Berechtigung erlaubt."
    static let noAddress =
        "Google hat keine E-Mail-Adresse geliefert. Prüfe, ob der Zustimmungsbildschirm die Berechtigungen für E-Mail enthält."
    static let generic = "Die Anmeldung ist fehlgeschlagen. Bitte erneut versuchen."

    /// Absagen aus dem Client selbst (`CommandPolicy`, `WriteAccess`): dort steht
    /// schon deutscher Text, den `Strings` kennt.
    static let localCodes: Set<String> = [
        "read_only", "command_not_allowed", "action_not_allowed", "pending_audit",
        "keyring", "network", "offline", "host_stopped",
    ]
}

/// Die Zeilen, die die Anmeldung ins Log schreibt. Reine Funktionen: die
/// Oberfläche schreibt das Ergebnis über `PerfLog`, die Tests prüfen den Text.
public enum OAuthLog {
    public static func start(provider: String) -> String { "oauth start provider=\(provider)" }

    public static func done(ok: Bool, milliseconds: Int, reason: String? = nil) -> String {
        var line = "oauth done ok=\(ok ? 1 : 0) ms=\(max(0, milliseconds))"
        if let reason, !reason.isEmpty { line += " reason=\(reason)" }
        return line
    }

    public static let cancel = "oauth cancel"
}

/// Ob der Google-Knopf überhaupt etwas anfangen kann. Der Kern nimmt eine
/// Client-ID aus `COMAIL_GOOGLE_CLIENT_ID` vor der aus den Einstellungen
/// (`providers.rs`, `resolve_credentials`); die Oberfläche fragt deshalb in
/// derselben Reihenfolge.
public enum GoogleOAuthSetup {
    public static let clientIDKey = "googleClientId"
    public static let clientSecretKey = "googleClientSecret"
    public static let environmentKey = "COMAIL_GOOGLE_CLIENT_ID"

    public static func clientID(stored: String?, environment: [String: String]) -> String {
        let fromEnvironment = (environment[environmentKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromEnvironment.isEmpty { return fromEnvironment }
        return (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isConfigured(stored: String?, environment: [String: String]) -> Bool {
        !clientID(stored: stored, environment: environment).isEmpty
    }

    /// Der Hinweis unter dem gesperrten Knopf im Blatt „Konto hinzufügen“.
    public static let missingHint =
        "Für Google fehlt die Client-ID. Einstellungen → Konten → Google (OAuth)."
}
