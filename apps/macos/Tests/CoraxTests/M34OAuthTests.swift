import XCTest
@testable import Corax
@testable import CoraxKit

/// M3.4 — Google-Anmeldung (schlank). Geprüft werden die Regeln ohne
/// Oberfläche: Argumentform am Dispatcher, Freigabe in der `CommandPolicy`,
/// deutsche Fehlertexte, die Logzeilen und der Ablauf gegen `FakeCore`.
final class M34OAuthTests: XCTestCase {

    // MARK: Argumente (dispatch.rs parst beide ohne `args`-Hülle)

    func testStartOAuthSendsTheProviderName() throws {
        let data = try JSONEncoder().encode(IPCArgs.StartOAuth(provider: .gmail))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"provider\":\"gmail\"}")
    }

    func testReauthSendsTheCamelCaseAccountId() throws {
        let data = try JSONEncoder().encode(IPCArgs.ReauthAccount(accountId: 7))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"accountId\":7}")
    }

    // MARK: Freigabe

    /// Alle drei Befehle schreiben in der echten Instanz: ohne „Änderungen
    /// erlauben“ nichts, mit Schalter ja, in der Sandbox immer.
    func testOAuthCommandsNeedTheWriteSwitch() {
        for command in ["start_oauth", "reauth_account", "cancel_oauth"] {
            XCTAssertEqual(CommandPolicy.decision(for: command), .writesDisabled, command)
            XCTAssertEqual(CommandPolicy.decision(for: command, writesAllowed: true), .allowed, command)
            XCTAssertEqual(CommandPolicy.decision(for: command, sandbox: true), .allowed, command)
        }
    }

    /// M4: Das Konto-mit-Passwort ist seit der Freigabe nicht mehr gesperrt,
    /// sondern läuft wie jede andere Änderung über den Schalter (siehe
    /// `CommandPolicyTests.testPasswordAccountIsReleasedWithTheSwitch`).
    func testPasswordAccountsLeftTheBlocklist() {
        XCTAssertFalse(CommandPolicy.blocked.contains("add_account_password"))
        XCTAssertFalse(CommandPolicy.blocked.contains("test_connection"))
        XCTAssertEqual(CommandPolicy.decision(for: "add_account_password", writesAllowed: true), .allowed)
        XCTAssertEqual(CommandPolicy.decision(for: "test_connection", writesAllowed: true), .allowed)
    }

    // MARK: Deutsche Texte statt Rust

    func testMissingClientIDSaysWhereToPutIt() {
        let error = CoraxClientError.core(
            code: "auth",
            message: "no OAuth app configured for gmail: add a client ID in Settings → Accounts, or set COMAIL_GOOGLE_CLIENT_ID")
        let text = OAuthErrorText.message(for: error)
        XCTAssertTrue(text.contains("Einstellungen → Konten"), text)
        XCTAssertTrue(text.contains("Client-ID"), text)
        XCTAssertFalse(text.contains("OAuth app configured"), text)
    }

    func testCancelledAndTimedOutAreDistinct() {
        let cancelled = OAuthErrorText.message(for: CoraxClientError.core(code: "auth", message: "sign-in cancelled"))
        XCTAssertEqual(cancelled, "Die Anmeldung wurde abgebrochen.")
        let timedOut = OAuthErrorText.message(for: CoraxClientError.core(code: "auth", message: "sign-in timed out"))
        XCTAssertEqual(timedOut, "Der Browser hat nicht geantwortet. Bitte die Anmeldung erneut starten.")
    }

    func testStateMismatchAndRejectedExchange() {
        let mismatch = OAuthErrorText.message(for: CoraxClientError.core(code: "auth", message: "oauth state mismatch"))
        XCTAssertTrue(mismatch.contains("nicht sicher zuordnen"), mismatch)
        let rejected = OAuthErrorText.message(
            for: CoraxClientError.core(code: "auth", message: "token exchange failed: {\"error\":\"invalid_client\"}"))
        XCTAssertTrue(rejected.contains("abgelehnt"), rejected)
        XCTAssertFalse(rejected.contains("invalid_client"), rejected)
    }

    func testMissingAddressExplainsTheConsentScreen() {
        let text = OAuthErrorText.message(
            for: CoraxClientError.core(code: "auth", message: "could not determine account email"))
        XCTAssertTrue(text.contains("E-Mail-Adresse"), text)
    }

    /// Unbekannte Kerntexte werden nicht roh durchgereicht.
    func testUnknownCoreErrorIsGeneric() {
        let text = OAuthErrorText.message(for: CoraxClientError.core(code: "auth", message: "boom: internal detail"))
        XCTAssertEqual(text, "Die Anmeldung ist fehlgeschlagen. Bitte erneut versuchen.")
        XCTAssertFalse(text.contains("boom"))
    }

    /// Eigene Absagen (Nur-Lesen-Modus) bleiben die deutschen Texte aus
    /// `Strings`, damit der Nutzer den Schalter genannt bekommt.
    func testLocalRefusalKeepsItsGermanText() {
        let error = CoraxClientError.core(
            code: "read_only", message: "Nur-Lesen-Modus – Postfach → Änderungen erlauben")
        XCTAssertEqual(OAuthErrorText.message(for: error), Strings.errorText(error))
        XCTAssertTrue(OAuthErrorText.message(for: error).contains("Nur-Lesen"))
    }

    func testReasonsForTheLogCarryNoContent() {
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.core(code: "auth", message: "sign-in cancelled")), "cancelled")
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.core(code: "auth", message: "sign-in timed out")), "timeout")
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.core(
            code: "auth",
            message: "no OAuth app configured for gmail: add a client ID …")), "missing_client_id")
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.core(code: "auth", message: "oauth state mismatch")),
                       "state_mismatch")
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.core(
            code: "auth", message: "token exchange failed: {\"error\":\"invalid_client\"}")), "token_exchange")
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.core(code: "auth", message: "could not determine account email")),
                       "no_address")
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.core(code: "keyring", message: "…")), "keyring")
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.notStarted), "core_not_started")
        XCTAssertEqual(OAuthErrorText.reason(for: CoraxClientError.host("boom")), "host")
    }

    // MARK: Logzeilen

    func testLogLinesSayWhatHappenedWithoutSecrets() {
        XCTAssertEqual(OAuthLog.start(provider: "gmail"), "oauth start provider=gmail")
        XCTAssertEqual(OAuthLog.done(ok: true, milliseconds: 42), "oauth done ok=1 ms=42")
        XCTAssertEqual(OAuthLog.done(ok: false, milliseconds: 7, reason: "cancelled"),
                       "oauth done ok=0 ms=7 reason=cancelled")
        XCTAssertEqual(OAuthLog.cancel, "oauth cancel")
        // Kein Platz für Adresse, Code oder Secret: die Zeilen bestehen nur aus
        // festen Wörtern, Zahlen und dem Grund-Token.
        for line in [OAuthLog.start(provider: "gmail"), OAuthLog.done(ok: true, milliseconds: 5),
                     OAuthLog.done(ok: false, milliseconds: 5, reason: "timeout"), OAuthLog.cancel] {
            XCTAssertFalse(line.contains("@"), line)
        }
    }

    // MARK: Client-ID

    func testClientIDPrefersTheEnvironmentLikeTheCore() {
        let env = [GoogleOAuthSetup.environmentKey: "  env.apps.googleusercontent.com  "]
        XCTAssertEqual(GoogleOAuthSetup.clientID(stored: "settings.apps.googleusercontent.com", environment: env),
                       "env.apps.googleusercontent.com")
        XCTAssertEqual(GoogleOAuthSetup.clientID(stored: " settings.apps.googleusercontent.com ", environment: [:]),
                       "settings.apps.googleusercontent.com")
        XCTAssertEqual(GoogleOAuthSetup.clientID(stored: "   ", environment: [:]), "")
    }

    func testOnlyARealClientIDEnablesTheButton() {
        XCTAssertFalse(GoogleOAuthSetup.isConfigured(stored: nil, environment: [:]))
        XCTAssertFalse(GoogleOAuthSetup.isConfigured(stored: "  ", environment: [:]))
        XCTAssertTrue(GoogleOAuthSetup.isConfigured(stored: "x.apps.googleusercontent.com", environment: [:]))
        XCTAssertTrue(GoogleOAuthSetup.isConfigured(stored: nil,
                                                    environment: [GoogleOAuthSetup.environmentKey: "env"]))
        // Der Hinweis nennt den Weg dorthin.
        XCTAssertTrue(GoogleOAuthSetup.missingHint.contains("Einstellungen → Konten"))
    }

    // MARK: Ablauf gegen FakeCore

    private func gmailAccount() -> Account {
        Account(id: 9, email: "ich@gmail.com", displayName: "Ich", provider: "gmail",
                authKind: "oauth2", syncState: "idle")
    }

    func testStartOAuthReturnsTheNewAccount() async throws {
        let core = FakeCore()
        let account = gmailAccount()
        await core.setOAuthAccount(account)
        let result = try await core.startOAuth(provider: .gmail)
        XCTAssertEqual(result.id, account.id)
        let starts = await core.oauthStarts
        XCTAssertEqual(starts, ["gmail"])
    }

    /// Bricht der Nutzer ab, antwortet der Kern mit „sign-in cancelled“; die
    /// Oberfläche zeigt den deutschen Satz, nicht den Kerntext.
    func testCancelledSignInShowsTheGermanSentence() async {
        let core = FakeCore()
        do {
            _ = try await core.startOAuth(provider: .gmail)
            XCTFail("ohne Konto muss die Anmeldung scheitern")
        } catch {
            XCTAssertEqual(OAuthErrorText.message(for: error), "Die Anmeldung wurde abgebrochen.")
        }
        try? await core.cancelOAuth()
        let cancels = await core.oauthCancels
        XCTAssertEqual(cancels, 1)
    }

    func testReauthUsesTheAccountID() async throws {
        let core = FakeCore()
        await core.setOAuthAccount(gmailAccount())
        _ = try await core.reauthAccount(id: 9)
        let reauths = await core.oauthReauths
        XCTAssertEqual(reauths, [9])
    }

    // MARK: Kontenseite

    func testReconnectIsOfferedOnlyForNeedsReauth() {
        XCTAssertTrue(AccountsSettingsView.needsReconnect("needs_reauth"))
        XCTAssertFalse(AccountsSettingsView.needsReconnect("idle"))
        XCTAssertFalse(AccountsSettingsView.needsReconnect(nil))
        XCTAssertEqual(AccountsSettingsView.syncText("needs_reauth"), "Abgemeldet – bitte neu verbinden")
    }

    /// Der Browserweg gilt nur für OAuth-Konten; ein IMAP-Konto braucht ein
    /// neues Passwort.
    func testOnlyOAuthAccountsOfferTheBrowserWay() {
        XCTAssertTrue(AccountsSettingsView.canReauthenticate(provider: "gmail"))
        XCTAssertTrue(AccountsSettingsView.canReauthenticate(provider: "microsoft"))
        XCTAssertFalse(AccountsSettingsView.canReauthenticate(provider: "imap"))
    }
}
