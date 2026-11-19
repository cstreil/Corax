import XCTest
@testable import Rabe
@testable import RabeKit

/// P2f: the real instance may only send what stands on the allowlist. The
/// sandbox stays unrestricted; the real instance writes only with the visible
/// switch on (P2g, `WriteAccessTests`).
final class CommandPolicyTests: XCTestCase {
    func testEveryReadingCommandIsAllowed() {
        for command in CommandPolicy.reading {
            XCTAssertEqual(CommandPolicy.decision(for: command), .allowed, command)
        }
    }

    func testEveryWritingCommandIsAllowedWithTheSwitch() {
        for command in CommandPolicy.writing {
            let json = command == "perform_action" ? #"{"args":{"kind":"archive","threadIds":[1]}}"# : "{}"
            XCTAssertEqual(CommandPolicy.decision(for: command, json: json, writesAllowed: true), .allowed, command)
        }
    }

    func testWritingCommandsAreRefusedWithoutTheSwitch() {
        for command in CommandPolicy.writing {
            let json = command == "perform_action" ? #"{"args":{"kind":"archive","threadIds":[1]}}"# : "{}"
            XCTAssertEqual(CommandPolicy.decision(for: command, json: json), .writesDisabled, command)
        }
    }

    func testBlockedAndUnknownCommandsAreRefused() {
        let refused = CommandPolicy.blocked.sorted() + ["frobnicate", "", "perform_action_v2"]
        for command in refused {
            XCTAssertEqual(CommandPolicy.decision(for: command, writesAllowed: true), .notAllowed, command)
        }
    }

    func testOnlyTheUsedActionKindsPass() {
        for kind in CommandPolicy.actionKinds.sorted() {
            let json = #"{"args":{"kind":"\#(kind)","threadIds":[5]}}"#
            XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: json, writesAllowed: true), .allowed, kind)
        }
        // The core knows more kinds than the UI uses; those are refused.
        for kind in ["move", "add_label", "remove_label", "delete_permanently", "spam", "not_spam"] {
            let json = #"{"args":{"kind":"\#(kind)","threadIds":[5]}}"#
            XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: json, writesAllowed: true),
                           .actionNotAllowed(kind), kind)
        }
        // Unparsable arguments fail closed instead of passing through.
        for json in ["{}", #"{"args":{}}"#, #"{"args":{"kind":1}}"#] {
            XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: json, writesAllowed: true),
                           .notAllowed, json)
        }
    }

    func testTheSandboxIsUnrestricted() {
        for command in ["sync_now", "send_now", "add_account_password", "frobnicate"] {
            XCTAssertEqual(CommandPolicy.decision(for: command, sandbox: true), .allowed, command)
        }
        let json = #"{"args":{"kind":"move","threadIds":[1]}}"#
        XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: json, sandbox: true), .allowed)
    }

    func testListsAreDisjointAndKnownToTheCore() throws {
        XCTAssertTrue(CommandPolicy.reading.isDisjoint(with: CommandPolicy.writing))
        XCTAssertTrue(CommandPolicy.blocked.isDisjoint(with: CommandPolicy.reading))
        XCTAssertTrue(CommandPolicy.blocked.isDisjoint(with: CommandPolicy.writing))

        // Every listed name must exist in the Rust dispatcher, otherwise the
        // list would keep a typo alive forever.
        let dispatch = try String(contentsOf: ContractFile.repositoryFile("src-tauri/crates/rabe-host/src/dispatch.rs"),
                                  encoding: .utf8)
        let known = ContractFile.commandNames(inRustDispatch: dispatch)
        for command in CommandPolicy.reading.union(CommandPolicy.writing).union(CommandPolicy.blocked) {
            XCTAssertTrue(known.contains(command), "\(command) fehlt in dispatch.rs")
        }
        XCTAssertFalse(known.isEmpty)
    }
}
