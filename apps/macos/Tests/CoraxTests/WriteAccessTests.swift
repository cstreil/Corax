import XCTest
@testable import Corax
@testable import CoraxKit

/// P2g: the visible write switch. The sandbox always writes; the real instance
/// starts read-only and, once switched on, only gets the P2f allowlist.
@MainActor
final class WriteAccessTests: XCTestCase {
    private var suites: [String] = []

    /// Own suite per test: the real switch must never touch `.standard`.
    private func defaults() -> UserDefaults {
        let name = "de.streil.rabe.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        suites.append(name)
        return defaults
    }

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private let archive = #"{"args":{"kind":"archive","threadIds":[1]}}"#

    /// Case 1: the sandbox writes whatever it wants, the switch is locked on.
    func testSandboxIsAlwaysAllowedAndNotSwitchable() {
        let store = defaults()
        let gate = WriteAccess(identifier: Instance.sandbox, mode: .sandbox, defaults: store)

        XCTAssertTrue(gate.allowed)
        XCTAssertFalse(gate.canToggle)
        XCTAssertFalse(gate.showsReadOnlyHint)

        gate.toggle()
        gate.set(false)
        XCTAssertTrue(gate.allowed, "die Sandbox lässt sich nicht ausschalten")
        XCTAssertNil(store.object(forKey: WriteAccess.defaultsKey(for: Instance.sandbox)),
                     "die Sandbox schreibt nichts in die Einstellungen")

        // The decision keeps the sandbox unrestricted even if the gate says no.
        XCTAssertEqual(CommandPolicy.decision(for: "sync_now", sandbox: true, writesAllowed: false), .allowed)
        XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: archive, sandbox: true,
                                             writesAllowed: false), .allowed)
    }

    /// Case 2: the real instance starts with the switch off.
    func testRealInstanceStartsWithTheSwitchOff() {
        let gate = WriteAccess(identifier: "de.streil.rabe.test.real", mode: .real, defaults: defaults())

        XCTAssertFalse(gate.allowed)
        XCTAssertTrue(gate.canToggle)
        XCTAssertTrue(gate.showsReadOnlyHint)
        for command in CommandPolicy.writing {
            let json = command == "perform_action" ? archive : "{}"
            XCTAssertEqual(CommandPolicy.decision(for: command, json: json, sandbox: false,
                                                 writesAllowed: gate.allowed), .writesDisabled, command)
        }
        // The refusal text names the way out (requirement 3).
        XCTAssertEqual(Strings.errorText(.core(code: "read_only", message: "")),
                       "Nur-Lesen-Modus – Postfach → Änderungen erlauben")
    }

    /// Case 3: switched on, the real instance follows the P2f allowlist.
    func testRealInstanceWithTheSwitchOnFollowsTheAllowlist() {
        let store = defaults()
        let identifier = "de.streil.rabe.test.real"
        let gate = WriteAccess(identifier: identifier, mode: .real, defaults: store)
        gate.set(true)

        XCTAssertTrue(gate.allowed)
        XCTAssertFalse(gate.showsReadOnlyHint)
        XCTAssertTrue(store.bool(forKey: WriteAccess.defaultsKey(for: identifier)),
                      "die Entscheidung liegt in UserDefaults")

        for command in CommandPolicy.reading.union(CommandPolicy.writing) {
            let json = command == "perform_action" ? archive : "{}"
            XCTAssertEqual(CommandPolicy.decision(for: command, json: json, sandbox: false,
                                                 writesAllowed: gate.allowed), .allowed, command)
        }
        // Still refused: the blocked commands and action kinds outside the list.
        for command in CommandPolicy.blocked {
            XCTAssertEqual(CommandPolicy.decision(for: command, sandbox: false, writesAllowed: true),
                           .notAllowed, command)
        }
        // M2.5's kinds and the scheduled send are released since the M2 audit.
        let move = #"{"args":{"kind":"move","threadIds":[1]}}"#
        XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: move, sandbox: false,
                                             writesAllowed: gate.allowed), .allowed)
        let later = #"{"args":{"draftId":1,"sendAt":1760000000000}}"#
        XCTAssertEqual(CommandPolicy.decision(for: "queue_send", json: later, sandbox: false,
                                             writesAllowed: gate.allowed), .allowed)

        // The switch survives a restart (same suite, new instance).
        let again = WriteAccess(identifier: identifier, mode: .real, defaults: store)
        XCTAssertTrue(again.allowed)
        gate.set(false)
        XCTAssertFalse(WriteAccess(identifier: identifier, mode: .real, defaults: store).allowed)
    }
}
