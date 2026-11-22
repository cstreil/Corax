import XCTest
@testable import Corax
@testable import CoraxKit

/// M4 — Konto per App-Passwort. Geprüft wird die reine Übersetzung der beiden
/// Fehlerformen des Kerns: `ConnectionTestResult.error` (fertiges JSON) und
/// `CoreError::Auth`, das denselben JSON-Text in seiner Meldung trägt.
///
/// Die Fälle sind der echte Text aus einem Lauf gegen `imap.example.invalid`
/// (`failed to lookup address information: nodename nor servname …`) und die
/// Varianten, die `imap/mod.rs` sonst liefert.
final class AccountConnectionTextTests: XCTestCase {

    // MARK: Verbindungstest

    func testUnknownHostSaysTheNameWasNotFound() {
        let text = AccountConnectionText.message(forTestError: Self.dnsError)
        XCTAssertTrue(text.contains("nicht gefunden"), text)
        XCTAssertTrue(text.contains("IMAP-Adresse"), text)
        XCTAssertFalse(text.contains("nodename"), text)
        XCTAssertFalse(text.contains("lookup"), text)
    }

    func testTimeoutSaysTheServerDoesNotAnswer() {
        let json = Self.ipc(code: "imap", message: "imap error: connect mail.example.test:993: timed out")
        XCTAssertTrue(AccountConnectionText.message(forTestError: json).contains("antwortet nicht"))
    }

    func testRefusedPortPointsAtThePort() {
        let json = Self.ipc(code: "imap", message: "imap error: connect mail.example.test:993: connection refused")
        let text = AccountConnectionText.message(forTestError: json)
        XCTAssertTrue(text.contains("Port"), text)
        XCTAssertTrue(text.contains("993"), text)
    }

    func testRejectedLoginPointsAtTheAppPassword() {
        let json = Self.ipc(code: "auth", message: "auth failed: imap login: [AUTHENTICATIONFAILED] Invalid credentials")
        let text = AccountConnectionText.message(forTestError: json)
        XCTAssertTrue(text.contains("App-Passwort"), text)
        XCTAssertFalse(text.contains("Invalid credentials"), text)
    }

    func testTLSFailureExplainsTheSecureConnection() {
        let json = Self.ipc(code: "tls", message: "tls error: certificate verify failed")
        XCTAssertTrue(AccountConnectionText.message(forTestError: json).contains("sichere Verbindung"))
    }

    func testNetworkFailureExplainsTheConnection() {
        let json = Self.ipc(code: "network", message: "network error: no route to host")
        XCTAssertTrue(AccountConnectionText.message(forTestError: json).contains("nicht erreichbar"))
    }

    /// Unbekannter Code, kaputtes JSON und leeres Feld: neutraler Satz, nie der
    /// rohe Text.
    func testUnknownShapesFallBackToTheNeutralSentence() {
        let shapes = [
            "",
            "kein json",
            Self.ipc(code: "other", message: "boom: internal detail"),
            Self.ipc(code: "db", message: "database error: disk I/O error"),
        ]
        for shape in shapes {
            let text = AccountConnectionText.message(forTestError: shape)
            XCTAssertEqual(text, AccountConnectionText.generic, shape)
            XCTAssertFalse(text.contains("boom"), shape)
            XCTAssertFalse(text.contains("disk I/O"), shape)
        }
    }

    /// Ein `imap`-Fehler ohne bekannten Zusatz bleibt beim Server-Satz — der
    /// Code allein sagt schon, wo es hakt.
    func testABareImapErrorKeepsTheServerSentence() {
        for shape in [Self.ipc(code: "imap", message: "irgendwas vom Server"), #"{"code":"imap"}"#] {
            XCTAssertEqual(AccountConnectionText.message(forTestError: shape), AccountConnectionText.serverRefused, shape)
        }
    }

    // MARK: Hinzufügen (`CoreError::Auth` um den Probe-Text)

    /// Der wichtige Fall: `add_account_password` meldet „Anmeldung
    /// fehlgeschlagen“, obwohl in Wahrheit der Server-Name nicht auflösbar ist.
    /// Die innere Ursache muss gewinnen.
    func testAddUnwrapsTheInnerCause() {
        let error = CoraxClientError.core(code: "auth", message: "auth failed: " + Self.dnsError)
        let text = AccountConnectionText.message(for: error)
        XCTAssertTrue(text.contains("nicht gefunden"), text)
        XCTAssertFalse(text.contains("nodename"), text)
        XCTAssertFalse(text.contains("example.invalid"), text)
    }

    /// Ein echter Login-Fehler kommt doppelt verpackt: `auth` um `auth`.
    func testAddKeepsARealRejectedLogin() {
        let inner = Self.ipc(code: "auth", message: "auth failed: imap login: [AUTHENTICATIONFAILED] Invalid credentials")
        let error = CoraxClientError.core(code: "auth", message: "auth failed: " + inner)
        let text = AccountConnectionText.message(for: error)
        XCTAssertTrue(text.contains("App-Passwort"), text)
        XCTAssertFalse(text.contains("Invalid credentials"), text)
    }

    func testAddWithoutInnerJSONUsesTheOuterCode() {
        let error = CoraxClientError.core(code: "tls", message: "tls error: handshake failed")
        XCTAssertTrue(AccountConnectionText.message(for: error).contains("sichere Verbindung"))
    }

    /// Absagen aus dem Client (Nur-Lesen-Modus) bleiben stehen.
    func testTheReadOnlyRefusalKeepsItsSentence() {
        let error = CoraxClientError.core(code: "read_only", message: "Nur-Lesen-Modus – Postfach → Änderungen erlauben")
        let text = AccountConnectionText.message(for: error)
        XCTAssertEqual(text, Strings.errorText(error))
        XCTAssertTrue(text.contains("Nur-Lesen"), text)
    }

    func testACoreThatIsNotRunningSaysSo() {
        let text = AccountConnectionText.message(for: CoraxClientError.notStarted)
        XCTAssertTrue(text.contains("Kern läuft noch nicht"), text)
    }

    /// Kein Text aus dieser Datei gibt je den rohen Rust-Text weiter.
    func testNoRawTextLeaksThroughAnyPath() {
        let secrets = ["nodename nor servname", "imap error", "auth failed", "example.invalid", "Invalid credentials"]
        let errors: [Error] = [
            CoraxClientError.core(code: "auth", message: "auth failed: " + Self.dnsError),
            CoraxClientError.core(code: "imap", message: "imap error: connect mail.example.test:993: bang"),
            CoraxClientError.core(code: "other", message: "boom: internal detail"),
            CoraxClientError.notStarted,
            CoraxClientError.host("host exploded: detail"),
        ]
        for error in errors {
            let text = AccountConnectionText.message(for: error)
            for secret in secrets {
                XCTAssertFalse(text.lowercased().contains(secret.lowercased()), "\(secret) in: \(text)")
            }
        }
    }

    // MARK: Hilfen

    /// Derselbe Text, den `test_connection` im Feld `error` liefert.
    static let dnsError = ipc(
        code: "imap",
        message: "imap error: connect imap.example.invalid:993: failed to lookup address information: "
            + "nodename nor servname provided, or not known")

    static func ipc(code: String, message: String) -> String {
        let object: [String: String] = ["code": code, "message": message]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
