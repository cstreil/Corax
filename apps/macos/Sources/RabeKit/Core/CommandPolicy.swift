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
    }

    /// Read-only commands (see the type comment for the two body fetches and
    /// the attachment helpers).
    static let reading: Set<String> = [
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
    ]

    /// Commands that change mail, drafts or settings.
    public static let writing: Set<String> = [
        "perform_action",
        "undo_last",
        "save_draft",
        "delete_draft",
        "queue_send",
        "cancel_send",
        "set_settings",
    ]

    /// `ActionKind` in the core (`models.rs`), limited to what the UI offers.
    static let actionKinds: Set<String> = [
        "archive", "unarchive", "trash", "snooze", "unsnooze",
        "star", "unstar", "mark_read", "mark_unread",
    ]

    /// Deliberately refused, for the report and for readers of this file:
    /// adding/removing accounts, `test_connection` (the account sheet is not
    /// part of the daily use yet), `send_now` and `sync_now` are not on either
    /// list and therefore fall into `.notAllowed` above.
    public static let blocked: Set<String> = [
        "add_account_password", "test_connection", "remove_account", "send_now", "sync_now",
    ]

    static func decision(for command: String, json: String = "{}", sandbox: Bool = false,
                         writesAllowed: Bool = false) -> Decision {
        // The sandbox is a local mockup mailbox on `*.invalid` hosts: it stays
        // unrestricted so the walkthroughs can exercise every path.
        if sandbox { return .allowed }
        if reading.contains(command) { return .allowed }
        guard writing.contains(command) else { return .notAllowed }
        guard writesAllowed else { return .writesDisabled }
        if command == "perform_action" {
            guard let kind = actionKind(in: json) else { return .notAllowed }
            guard actionKinds.contains(kind) else { return .actionNotAllowed(kind) }
        }
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
