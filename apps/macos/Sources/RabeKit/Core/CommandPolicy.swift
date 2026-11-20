import Foundation

/// Which commands the native client may send to the core.
///
/// P2f replaces the old blocklist with an allowlist for the real instance
/// (audit recommendation "Freigabeliste"): everything listed here goes
/// through, everything else is refused in the client layer and never reaches
/// the core. The sandbox keeps its unrestricted behaviour.
///
/// The lists are the ones the audit checked command by command:
///
/// - `reading` maps onto core methods in `dispatch.rs` that only read from the
///   database (`db.read`). Exceptions, all of them local bookkeeping rather
///   than mail state: `get_thread`/`get_body` mark an unfetched body as
///   `fetching` and nudge the fetch (`request_body` → `db.write`), and
///   `open_attachment`/`save_attachment` extract a file. None of them answers
///   a server command or changes a thread, message or draft.
/// - `writing` is the set the UI uses today.
/// - `actionKinds` is what the UI sends inside `perform_action`; any other kind
///   is refused before it reaches the core.
enum CommandPolicy {
    enum Decision: Equatable {
        case allowed
        /// Not on the list: unknown command, or deliberately blocked.
        case notAllowed
        /// On the write list, but the user has not switched writes on
        /// ("Postfach → Änderungen erlauben", `WriteAccess`).
        case writesDisabled
        /// `perform_action` with a kind the UI does not use.
        case actionNotAllowed(String)
        /// Implemented and used by the settings window, but not released for
        /// the real instance yet (M2.1, `pendingAudit`).
        case pendingAudit
    }

    /// Read-only commands (see the type comment for the two body fetches and
    /// the attachment helpers).
    ///
    /// The M2 audit released the settings, calendar, AI, M2.4 and M2.5
    /// commands. Nothing here changes mail, draft or settings state.
    static let reading: Set<String> = [
        // Mail list, thread and search (P2f).
        "list_accounts",
        "list_threads",
        "get_thread",
        "get_body",
        "list_splits",
        "list_labels",
        "unread_counts",
        "get_sync_status",
        "get_settings",
        "search",
        "suggest_contacts",
        "open_attachment",
        "save_attachment",
        // M2.1 — settings: snippets, the rule dry run, MCP status and the
        // instance's own token (masked in the UI, never logged).
        "list_snippets",
        "preview_split_condition",
        "mcp_status",
        "mcp_activity",
        "mcp_list_clients",
        "mcp_get_token",
        // M2.2 — calendar: read events, and a sync that changes nothing locally.
        "list_calendars",
        "list_events",
        "events_for_message",
        "calendar_sync_now",
        // M2.3 — AI. `ai_status` reads the key from the keychain (no network,
        // no cost); the model calls run on a user action only.
        "ai_status",
        "ai_usage_stats",
        "embedding_status",
        "ai_list_models",
        "test_decision_provider",
        "ai_summarize",
        "ai_ask",
        "ai_command",
        "ai_draft",
        "ai_draft_actions",
        "ai_proofread",
        "ai_quick_replies",
        "ai_search_filter",
        "ai_signature",
        "ai_plan_automation",
        // M2.4 — sender pictures (network on first use per sender, then seven
        // days on disk), verification codes, the `List-Unsubscribe` header.
        "sender_avatar",
        "latest_verification_code",
        "thread_unsubscribe_message",
        // M2.5 — folder names for the move popover, "sync now".
        "list_folders",
        "sync_now",
    ]

    /// Commands that change mail, drafts or settings. They run only with the
    /// visible switch on ("Postfach → Änderungen erlauben", `WriteAccess`).
    ///
    /// Everything the audit released as *writing* lives here and not in
    /// `reading`: `decision` checks `pendingAudit` before the switch, so a
    /// released write in `reading` would bypass it.
    public static let writing: Set<String> = [
        "perform_action",
        "undo_last",
        "save_draft",
        "delete_draft",
        "queue_send",
        "cancel_send",
        "set_settings",
        // M2.1 — accounts, snippets, splits, labels, MCP token and client entry.
        "set_account_display_name",
        "remove_account",
        "save_snippet",
        "delete_snippet",
        "save_split",
        "delete_split",
        "reorder_tabs",
        "relabel_auto",
        "save_label",
        "delete_label",
        "restore_auto_labels",
        "create_category",
        "mcp_regenerate_token",
        "mcp_client_snippet",
        // M2.2 — calendar: events (they mail invitations) and settings.
        "create_event",
        "update_event",
        "delete_event",
        "rsvp_event",
        "set_calendar_enabled",
        "set_calendar_color",
        "set_default_calendar",
        // M2.12 — CalDAV connect. Writes the password into the keychain and the
        // server/principal/collection rows into the database, then nudges the
        // first sync; nothing leaves the machine before that sync. Released
        // under `writing` because it changes the instance's state.
        "connect_calendar",
        // M2.3 — local index and the keys in the keychain.
        "semantic_reindex",
        "set_ai_key",
        "set_decision_key",
        "ai_learn_voice",
        // M2.4 — a real unsubscribe on the sender's side.
        "unsubscribe_message",
    ]

    /// `ActionKind` in the core (`models.rs`), limited to what the UI offers.
    /// The six M2.5 kinds were released by the M2 audit (`spam` and `move`
    /// directly; `not_spam`, `add_label`/`remove_label` and
    /// `delete_permanently` after W2, W6 and W3 were fixed).
    static let actionKinds: Set<String> = [
        "archive", "unarchive", "trash", "snooze", "unsnooze",
        "star", "unstar", "mark_read", "mark_unread",
        "spam", "not_spam", "move", "add_label", "remove_label", "delete_permanently",
    ]

    /// Deliberately refused, for the report and for readers of this file.
    ///
    /// `mcp_install_client` writes the fixed key `comail` into the config of
    /// Cursor, Claude or Codex (`mcp/clients.rs:19`) and would overwrite the
    /// working entry of the Tauri app with this instance's port and token. That
    /// needs one key per instance in the core first — a core change and the
    /// user's call (M2 audit).
    ///
    /// `add_account_password` and `test_connection` are not part of the daily
    /// use yet.
    public static let blocked: Set<String> = [
        "add_account_password", "test_connection", "mcp_install_client",
    ]

    /// **Empty since the M2 audit.** Every command the settings window, the
    /// calendar, the AI pages and M2.4/M2.5 implement was released above, most
    /// of them with a condition that is now met in the UI:
    ///
    /// - `ai_ask`: links in an answer open only as a web address (W4).
    /// - `unsubscribe_message`: `⌘U` asks before the core acts (K3).
    /// - `update_event`: dragging an event with attendees mails only after a
    ///   click (K4).
    /// - `relabel_auto`: the palette asks, because reclassifying the inbox
    ///   costs AI calls (K5).
    /// - `mcp_client_snippet`: the UI says the entry is named `comail` and
    ///   replaces the Tauri app's entry.
    ///
    /// The set stays: a future command can wait here again, and the UI already
    /// shows "Noch nicht freigegeben" for this answer.
    public static let pendingAudit: Set<String> = []

    static func decision(for command: String, json: String = "{}", sandbox: Bool = false,
                         writesAllowed: Bool = false) -> Decision {
        // The sandbox is a local mockup mailbox on `*.invalid` hosts: it stays
        // unrestricted so the walkthroughs can exercise every path.
        if sandbox { return .allowed }
        if reading.contains(command) { return .allowed }
        if pendingAudit.contains(command) { return .pendingAudit }
        guard writing.contains(command) else { return .notAllowed }
        guard writesAllowed else { return .writesDisabled }
        if command == "perform_action" {
            guard let kind = actionKind(in: json) else { return .notAllowed }
            guard actionKinds.contains(kind) else { return .actionNotAllowed(kind) }
        }
        // `queue_send` with a delivery time ("Später senden"/"Sofort senden")
        // was pending in M2.5; the M2 audit released it with W1 fixed.
        return .allowed
    }

    /// `perform_action` arguments are `{"args":{"kind":"archive",…}}`.
    static func actionKind(in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let args = object["args"] as? [String: Any] { return args["kind"] as? String }
        return object["kind"] as? String
    }

}
