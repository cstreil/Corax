import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.13b: Startsperre am Compile-Flag (W-A) und Meeting-Links nur http/https (W-B).
final class M213bTests: XCTestCase {

    // MARK: W-A — Startsperre hängt am Compile-Flag

    /// Geprüft wird im Debug-Build: Der Testlauf selbst ist ein Debug-Build,
    /// also muss er die Sperre tragen — unabhängig davon, ob später ein
    /// App-Paket mit `CoraxTestHooks` darum liegt.
    func testDebugBuildCarriesTheGuard() {
        #if DEBUG || CORAX_TEST_HOOKS
        XCTAssertTrue(StartGuard.hooksInThisBuild)
        #else
        XCTFail("Tests laufen nur im Debug-Build")
        #endif
    }

    /// Die reine Funktion bleibt unverändert: alles außer der Sandbox verweigert.
    func testGuardRefusesEverythingButTheSandbox() {
        XCTAssertTrue(StartGuard.shouldRefuseStart(hooks: true, identifier: ""))
        XCTAssertTrue(StartGuard.shouldRefuseStart(hooks: true, identifier: Instance.native))
        XCTAssertFalse(StartGuard.shouldRefuseStart(hooks: true, identifier: Instance.sandbox))
    }

    // MARK: W-B — nur http und https verlassen die App

    func testJoinLinkRejectsDangerousSchemes() {
        XCTAssertNil(MeetingLink.url("javascript:alert(1)"))
        XCTAssertNil(MeetingLink.url("JavaScript:alert(1)"))
        XCTAssertNil(MeetingLink.url("file:///etc/passwd"))
        XCTAssertNil(MeetingLink.url("data:text/html,<script>alert(1)</script>"))
        XCTAssertNil(MeetingLink.url("mailto:someone@example.test"))
        XCTAssertNil(MeetingLink.url("ssh://host"))
        // Auch getarnt hinter führendem Leerraum bleibt es verboten.
        XCTAssertNil(MeetingLink.url("  javascript:alert(1)"))
    }

    func testJoinLinkAcceptsHttpAndHttps() {
        XCTAssertEqual(MeetingLink.url("https://meet.example.test/team")?.scheme, "https")
        XCTAssertEqual(MeetingLink.url(" http://meet.example.test/team ")?.scheme, "http")
        XCTAssertEqual(MeetingLink.url("HTTPS://meet.example.test/x")?.host, "meet.example.test")
        XCTAssertNil(MeetingLink.url(nil))
        XCTAssertNil(MeetingLink.url(""))
        XCTAssertNil(MeetingLink.url("https://"))
    }

    /// Dieselbe Entscheidung deckt alle drei Beitreten-Wege ab: Terminkarte,
    /// Einladungskarte und der Tastenweg im Kalender fragen `MeetingLink.url`.
    func testJoinLinkIsTheSingleFilterForUiAndKeyboard() {
        let evil = "javascript:alert(1)"
        let good = "https://meet.example.test/team"
        XCTAssertNil(MeetingLink.url(evil))
        XCTAssertNotNil(MeetingLink.url(good))
    }
}
