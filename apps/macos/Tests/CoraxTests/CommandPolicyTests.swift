import XCTest
@testable import Corax
@testable import CoraxKit

/// P2f: the real instance may only send what stands on the allowlist. The
/// sandbox stays unrestricted; the real instance writes only with the visible
/// switch on (P2g, `WriteAccessTests`).
///
/// Since the M2 audit every command and every `ActionKind` the app implements
/// is released. M4 released `mcp_install_client` too: the core writes the
/// instance's own key (`corax`), so the Tauri app's `comail` entry survives.
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

    /// The M2 audit's rule for the release: a write goes to `writing`, never to
    /// `reading` — `decision` checks the lists in that order, so a released
    /// write in `reading` would bypass "Änderungen erlauben".
    func testReleasedWritesSitOnTheWriteList() {
        let releasedWrites = [
            // M2.1
            "set_account_display_name", "remove_account",
            "save_snippet", "delete_snippet",
            "save_split", "delete_split", "reorder_tabs", "relabel_auto",
            "save_label", "delete_label", "restore_auto_labels", "create_category",
            "mcp_regenerate_token", "mcp_client_snippet",
            // M2.2
            "create_event", "update_event", "delete_event", "rsvp_event",
            "set_calendar_enabled", "set_calendar_color", "set_default_calendar",
            // M2.3
            "semantic_reindex", "set_ai_key", "set_decision_key", "ai_learn_voice",
            // M2.4
            "unsubscribe_message",
        ]
        for command in releasedWrites {
            XCTAssertTrue(CommandPolicy.writing.contains(command), command)
            XCTAssertFalse(CommandPolicy.reading.contains(command), "\(command) darf den Schalter nicht umgehen")
            XCTAssertEqual(CommandPolicy.decision(for: command), .writesDisabled, command)
            XCTAssertEqual(CommandPolicy.decision(for: command, writesAllowed: true), .allowed, command)
        }

        // The reading half of the release stays free of the switch.
        let releasedReads = [
            "list_snippets", "preview_split_condition",
            "mcp_status", "mcp_activity", "mcp_list_clients", "mcp_get_token",
            "list_calendars", "list_events", "events_for_message", "calendar_sync_now",
            "ai_status", "ai_usage_stats", "embedding_status", "ai_list_models",
            "test_decision_provider", "ai_summarize", "ai_ask", "ai_command", "ai_draft",
            "ai_draft_actions", "ai_proofread", "ai_quick_replies", "ai_search_filter",
            "ai_signature", "ai_plan_automation",
            "sender_avatar", "latest_verification_code", "thread_unsubscribe_message",
            "list_folders", "sync_now",
        ]
        for command in releasedReads {
            XCTAssertTrue(CommandPolicy.reading.contains(command), command)
            XCTAssertFalse(CommandPolicy.writing.contains(command), command)
            XCTAssertEqual(CommandPolicy.decision(for: command), .allowed, command)
        }
    }

    func testBlockedAndUnknownCommandsAreRefused() {
        let refused = CommandPolicy.blocked.sorted() + ["frobnicate", "", "perform_action_v2"]
        for command in refused {
            XCTAssertEqual(CommandPolicy.decision(for: command, writesAllowed: true), .notAllowed, command)
        }
        // M4: „Bei App eintragen“ schreibt nur den eigenen Schlüssel und
        // braucht wie jede andere Änderung den Schalter.
        XCTAssertEqual(CommandPolicy.decision(for: "mcp_install_client"), .writesDisabled)
        XCTAssertEqual(CommandPolicy.decision(for: "mcp_install_client", writesAllowed: true), .allowed)
    }

    func testOnlyTheUsedActionKindsPass() {
        for kind in CommandPolicy.actionKinds.sorted() {
            let json = #"{"args":{"kind":"\#(kind)","threadIds":[5]}}"#
            XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: json, writesAllowed: true), .allowed, kind)
        }
        // M2.5's six kinds were released by the M2 audit.
        for kind in ["spam", "not_spam", "move", "add_label", "remove_label", "delete_permanently"] {
            let json = #"{"args":{"kind":"\#(kind)","threadIds":[5]}}"#
            XCTAssertTrue(CommandPolicy.actionKinds.contains(kind), kind)
            XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: json, writesAllowed: true), .allowed, kind)
        }
        // The core knows kinds the UI never sends; those stay refused.
        for kind in ["send", "connect_calendar"] {
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

    /// M2.5: "Später senden"/"Sofort senden" carry a `sendAt`; the audit
    /// released them once W1 (the subject) was fixed.
    func testScheduledSendIsReleased() {
        let json = #"{"args":{"draftId":1,"sendAt":1750000000000}}"#
        XCTAssertEqual(CommandPolicy.decision(for: "queue_send", json: json, writesAllowed: true), .allowed)
        XCTAssertEqual(CommandPolicy.decision(for: "queue_send", json: json), .writesDisabled)
        XCTAssertEqual(CommandPolicy.decision(for: "queue_send", json: json, sandbox: true), .allowed)
    }

    /// The M2 audit released everything the app implements.
    func testTheAuditLeftNothingPending() {
        XCTAssertTrue(CommandPolicy.pendingAudit.isEmpty)
        XCTAssertTrue(CommandPolicy.blocked.isEmpty)
        // M2.12: `connect_calendar` is released under `writing` (the settings
        // window has "Konto verbinden"); the other two calendar commands the
        // UI does not use stay refused.
        for command in ["disconnect_calendar", "create_teams_meeting"] {
            XCTAssertEqual(CommandPolicy.decision(for: command, writesAllowed: true), .notAllowed, command)
            XCTAssertEqual(CommandPolicy.decision(for: command, sandbox: true), .allowed, command)
        }
        XCTAssertEqual(CommandPolicy.decision(for: "connect_calendar", writesAllowed: true), .allowed)
        XCTAssertEqual(CommandPolicy.decision(for: "connect_calendar"), .writesDisabled)
    }

    /// M4: Konto per App-Passwort ist freigegeben — aber nur mit dem Schalter.
    func testPasswordAccountIsReleasedWithTheSwitch() {
        for command in ["add_account_password", "test_connection"] {
            XCTAssertFalse(CommandPolicy.reading.contains(command), command)
            XCTAssertTrue(CommandPolicy.writing.contains(command), command)
            XCTAssertEqual(CommandPolicy.decision(for: command), .writesDisabled, command)
            XCTAssertEqual(CommandPolicy.decision(for: command, writesAllowed: true), .allowed, command)
            XCTAssertEqual(CommandPolicy.decision(for: command, sandbox: true), .allowed, command)
        }
    }

    func testTheSandboxIsUnrestricted() {
        for command in ["sync_now", "send_now", "mcp_install_client", "frobnicate"] {
            XCTAssertEqual(CommandPolicy.decision(for: command, sandbox: true), .allowed, command)
        }
        let json = #"{"args":{"kind":"move","threadIds":[1]}}"#
        XCTAssertEqual(CommandPolicy.decision(for: "perform_action", json: json, sandbox: true), .allowed)
    }

    func testListsAreDisjointAndKnownToTheCore() throws {
        XCTAssertTrue(CommandPolicy.reading.isDisjoint(with: CommandPolicy.writing))
        XCTAssertTrue(CommandPolicy.blocked.isDisjoint(with: CommandPolicy.reading))
        XCTAssertTrue(CommandPolicy.blocked.isDisjoint(with: CommandPolicy.writing))
        XCTAssertTrue(CommandPolicy.pendingAudit.isDisjoint(with: CommandPolicy.reading))
        XCTAssertTrue(CommandPolicy.pendingAudit.isDisjoint(with: CommandPolicy.writing))
        XCTAssertTrue(CommandPolicy.pendingAudit.isDisjoint(with: CommandPolicy.blocked))

        // Every listed name must exist in the Rust dispatcher, otherwise the
        // list would keep a typo alive forever.
        let dispatch = try String(contentsOf: ContractFile.repositoryFile("src-tauri/crates/corax-host/src/dispatch.rs"),
                                  encoding: .utf8)
        let known = ContractFile.commandNames(inRustDispatch: dispatch)
        for command in CommandPolicy.reading.union(CommandPolicy.writing)
            .union(CommandPolicy.blocked).union(CommandPolicy.pendingAudit) {
            XCTAssertTrue(known.contains(command), "\(command) fehlt in dispatch.rs")
        }
        XCTAssertFalse(known.isEmpty)
    }
}
