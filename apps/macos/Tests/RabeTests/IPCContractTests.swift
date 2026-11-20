import XCTest
@testable import Rabe
@testable import RabeKit

/// The Rust dispatcher rejects unknown fields and requires the exact key names.
/// Every wrapper in `Core/RabeClient.swift` has its argument type in `IPCArgs`
/// (or `Models.swift` for the larger ones); this test encodes them and compares
/// the JSON keys with the contract in `src/ipc/types.ts`.
///
/// R-W4: the expected keys are read from `types.ts` at test time
/// (`ContractFile`), not copied into this file — a renamed field in the contract
/// or in a wrapper turns the test red.
final class IPCContractTests: XCTestCase {
    private var contract: ContractFile.Contract!

    override func setUpWithError() throws {
        contract = try ContractFile.load()
    }

    /// Every JSON key is in the contract, and every required contract key is
    /// sent. Optional and nullable fields may be omitted (serde `Option<T>`).
    private func check(_ key: String, _ value: some Encodable,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let shape = try contract.shape(key)
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   "\(key): kein JSON-Objekt", file: file, line: line)
        let keys = Set(object.keys)
        let unexpected = keys.subtracting(shape.all)
        XCTAssertTrue(unexpected.isEmpty, "\(key): nicht im Vertrag: \(unexpected.sorted())", file: file, line: line)
        let missing = shape.required.subtracting(keys)
        XCTAssertTrue(missing.isEmpty, "\(key): Pflichtfelder fehlen: \(missing.sorted())", file: file, line: line)
    }

    func testWrapperArgumentNames() throws {
        try check("list_threads", IPCArgs.ListThreads(view: .inbox, splitId: 1, accountId: 2, labelId: nil, folderId: nil, cursor: 3, limit: 40))
        // Optional arguments are omitted when nil (`types.ts`: `splitId?: number | null`).
        try check("list_threads", IPCArgs.ListThreads(view: .all, splitId: nil, accountId: nil, labelId: nil, folderId: nil, cursor: nil, limit: 100))

        try check("get_thread", IPCArgs.GetThread(threadId: 11))
        try check("get_body", IPCArgs.GetBody(messageId: 12))

        let action = IPCArgs.PerformAction(kind: .archive, threadIds: [1, 2], params: nil)
        try check("perform_action", WithArgs(args: action))
        try check("PerformActionArgs", action)
        try check("PerformActionArgs.params", ActionParams(wakeAt: 5))
        try check("PerformActionArgs.params", ActionParams(targetFolderId: 9))
        try check("PerformActionArgs.params", ActionParams(labelId: 7))
        // M2.5: Verschieben (Ordnerliste) und "jetzt synchronisieren".
        try check("list_folders", IPCArgs.ListFolders(accountId: 1))
        try check("list_folders", IPCArgs.ListFolders(accountId: nil))
        try check("sync_now", IPCArgs.ListFolders(accountId: 1))

        try check("unread_counts", IPCArgs.UnreadCounts(accountId: nil))
        try check("unread_counts", IPCArgs.UnreadCounts(accountId: 3))

        let search = IPCArgs.Search(query: "a", accountId: nil, limit: 100)
        try check("search", WithArgs(args: search))
        try check("SearchArgs", search)

        try check("suggest_contacts", IPCArgs.SuggestContacts(query: "b", limit: 8))

        // M2.4: avatars, verification codes, unsubscribing.
        try check("sender_avatar", IPCArgs.SenderAvatar(email: "a@b.de"))
        try check("latest_verification_code", IPCArgs.VerificationCode(maxAgeMinutes: 30))
        try check("latest_verification_code", IPCArgs.VerificationCode(maxAgeMinutes: nil))
        try check("thread_unsubscribe_message", IPCArgs.ThreadID(threadId: 4))
        try check("unsubscribe_message", IPCArgs.MessageID(messageId: 5))

        try check("save_draft", WithArgs(args: Self.draftArgs))
        // `Option<T>` in the Rust DTO: a nil field may be missing (serde
        // deserializes a missing option as None), so it is simply not sent.
        try check("SaveDraftArgs", Self.draftArgs)
        try check("save_draft", WithArgs(args: Self.fullDraftArgs))
        try check("SaveDraftArgs", Self.fullDraftArgs)

        try check("delete_draft", IPCArgs.DeleteDraft(draftId: 4))
        try check("queue_send", WithArgs(args: IPCArgs.QueueSend(draftId: 5, sendAt: nil)))
        try check("QueueSendArgs", IPCArgs.QueueSend(draftId: 5, sendAt: nil))
        // "Später senden"/"Sofort senden" setzen `sendAt`.
        try check("queue_send", WithArgs(args: IPCArgs.QueueSend(draftId: 5, sendAt: 1_760_000_000_000)))
        try check("QueueSendArgs", IPCArgs.QueueSend(draftId: 5, sendAt: 1_760_000_000_000))
        try check("cancel_send", IPCArgs.CancelSend(actionId: 6))

        try check("open_attachment", IPCArgs.OpenAttachment(attachmentId: 7))
        // W4: the dispatcher parses `rename_all = "camelCase"` (`attachmentId`, `dest`).
        try check("save_attachment", IPCArgs.SaveAttachment(attachmentId: 7, dest: "/tmp/x"))

        try check("test_connection", WithArgs(args: Self.accountArgs))
        try check("AddPasswordAccountArgs", Self.accountArgs)
        try check("add_account_password", WithArgs(args: Self.namedAccountArgs))
        try check("AddPasswordAccountArgs", Self.namedAccountArgs)

        // The client sends this one as raw JSON (`settingsJSON`), shape here too.
        try check("set_settings", SetSettingsArgs(settings: [:]))

        // M2.1 — settings editors.
        try check("set_account_display_name", IPCArgs.SetAccountDisplayName(accountId: 1, name: "N"))
        try check("remove_account", IPCArgs.RemoveAccount(accountId: 1))

        let snippet = SnippetInput(id: nil, name: "n", shortcut: "s", subject: nil, bodyText: "t")
        try check("save_snippet", IPCArgs.SaveSnippet(snippet: snippet))
        // The payload is `Omit<Snippet, "id"|"usageCount"> & { id }`: no usageCount.
        try check("save_snippet.snippet", snippet)
        try check("delete_snippet", IPCArgs.DeleteSnippet(snippetId: 2))

        let label = LabelInput(id: nil, name: "L", color: "#2563eb", position: 3)
        try check("save_label", IPCArgs.SaveLabel(label: label))
        // `Omit<Label, "id"|"keyword"> & { id }`: no keyword, no isAuto.
        try check("save_label.label", label)
        try check("delete_label", IPCArgs.DeleteLabel(labelId: 3))

        let split = SplitInput(id: nil, name: "R", position: 1,
                               condition: .sender(.contains, "@x.de"), target: nil, countAll: false)
        try check("save_split", IPCArgs.SaveSplit(split: split))
        try check("save_split.split", split)
        try check("delete_split", IPCArgs.DeleteSplit(splitId: 4))
        try check("reorder_tabs", IPCArgs.ReorderTabs(order: [.split(1), .label(2)]))
        try check("preview_split_condition", IPCArgs.PreviewSplitCondition(condition: .sender(.contains, "x"), limit: nil))

        try check("create_category", IPCArgs.CreateCategory(name: "K", color: "#16a34a", description: "d"))

        try check("mcp_client_snippet", IPCArgs.McpClientID(id: "claude"))
        try check("mcp_install_client", IPCArgs.McpClientID(id: "claude"))

        // M2.2 — Kalender.
        try check("list_events", IPCArgs.ListEvents(startMs: 1, endMs: 2))
        try check("events_for_message", IPCArgs.EventsForMessage(messageId: 1))
        let create = CreateEventArgs(accountId: 1, calendarId: nil, summary: "s", startsAt: 1, endsAt: 2)
        try check("create_event", WithArgs(args: create))
        try check("CreateEventArgs", create)
        // Every optional field sent: the host accepts all of them.
        try check("CreateEventArgs", CreateEventArgs(
            accountId: 1, calendarId: 7, summary: "s", description: "d", location: "l",
            joinUrl: "https://x", startsAt: 1, endsAt: 2, allDay: true,
            attendees: [Address(name: nil, email: "a@b.de")]))
        try check("rsvp_event", WithArgs(args: IPCArgs.RsvpEvent(eventId: 1, response: .accepted)))
        try check("rsvp_event.args", IPCArgs.RsvpEvent(eventId: 1, response: .declined))
        try check("delete_event", IPCArgs.DeleteEvent(eventId: 1, notify: true))
        try check("list_calendars", IPCArgs.ListCalendars(accountId: nil))
        try check("list_calendars", IPCArgs.ListCalendars(accountId: 3))
        try check("set_calendar_enabled", IPCArgs.SetCalendarEnabled(calendarId: 1, enabled: true))
        try check("set_calendar_color", IPCArgs.SetCalendarColor(calendarId: 1, color: nil))
        try check("set_calendar_color", IPCArgs.SetCalendarColor(calendarId: 1, color: "#112233"))
        try check("set_default_calendar", IPCArgs.SetDefaultCalendar(calendarId: 1))
        try check("calendar_sync_now", IPCArgs.CalendarSyncNow(accountId: nil))

        // M2.3 — KI. The keys are the ones the host's `deny_unknown_fields`
        // structs accept; `set_ai_key`/`set_decision_key` carry the secret, so
        // only their names are checked here, never a real value.
        try check("set_ai_key", IPCArgs.SetAIKey(apiKey: "x"))
        try check("set_decision_key", IPCArgs.SetDecisionKey(provider: "openrouter", apiKey: "x"))
        try check("ai_summarize", IPCArgs.AIThreadID(threadId: 1))
        try check("ai_quick_replies", IPCArgs.AIThreadID(threadId: 2))
        try check("ai_draft", IPCArgs.AIDraft(threadId: 1, replyToMessageId: 2, instruction: "i",
                                             currentDraft: "c", senderName: "s", voice: true,
                                             hasSignature: true, requestId: "r"))
        // Every optional omitted: the host reads them as `None`/`false`.
        try check("ai_draft", IPCArgs.AIDraft(threadId: nil, replyToMessageId: nil, instruction: "i",
                                             currentDraft: nil, senderName: nil, voice: nil,
                                             hasSignature: nil, requestId: nil))
        try check("ai_draft_actions", IPCArgs.AIDraftActions(threadId: nil, draft: "d"))
        try check("ai_draft_actions", IPCArgs.AIDraftActions(threadId: 4, draft: "d"))
        try check("ai_proofread", IPCArgs.AIProofread(body: "b"))
        try check("ai_signature", IPCArgs.AISignature(name: "n", email: "e@x.de"))
        try check("ai_command", IPCArgs.AICommand(query: "q"))
        try check("ai_search_filter", IPCArgs.AISearchFilterArgs(request: "r", history: []))
        try check("ai_search_filter", IPCArgs.AISearchFilterArgs(
            request: "r", history: [AIFilterTurn(question: "q", answer: "a")]))
        // The contract spells it `AiFilterTurn` (lowercase i), the Swift type `AIFilterTurn`.
        try check("AiFilterTurn", AIFilterTurn(question: "q", answer: "a"))
        try check("ai_plan_automation", IPCArgs.AIPlanAutomation(prompt: "p"))
        try check("ai_ask", IPCArgs.AIAsk(question: "q", requestId: "r", accountId: nil))
        try check("ai_ask", IPCArgs.AIAsk(question: "q", requestId: "r", accountId: 3))
    }

    /// `UpdateEventArgs extends CreateEventArgs` in `types.ts`. The contract
    /// parser does not resolve `extends`, and the Rust DTO behind `update_event`
    /// has neither `accountId` nor `calendarId` — so the fields are checked
    /// against the merged shape (what `create_event` accepts plus
    /// `eventId`/`notify`), and the two inherited Create-only fields are
    /// asserted absent. Tauri sends `accountId`; the host ignores it because
    /// `WithArgs<T>` does not deny unknown fields.
    func testUpdateEventMatchesTheHostShape() throws {
        let args = UpdateEventArgs(
            eventId: 1, summary: "s", description: "d", location: "l", joinUrl: nil,
            startsAt: 10, endsAt: 20, allDay: false,
            attendees: [Address(name: nil, email: "a@b.de")], notify: true)
        let inherited = try contract.shape("CreateEventArgs")
        let own = try contract.shape("UpdateEventArgs")
        let data = try JSONEncoder().encode(args)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(object.keys)
        let allowed = inherited.all.union(own.all)
        XCTAssertTrue(keys.subtracting(allowed).isEmpty,
                      "update_event: nicht im Vertrag: \(keys.subtracting(allowed).sorted())")
        // `accountId` is required by CreateEventArgs but does not exist in the
        // host's UpdateEventArgs; every other required field must be sent.
        XCTAssertTrue(inherited.required.contains("accountId"))
        let required = inherited.required.subtracting(["accountId"]).union(own.required)
        XCTAssertTrue(required.isSubset(of: keys), "update_event: Pflichtfelder fehlen")
        XCTAssertFalse(keys.contains("accountId"))
        XCTAssertFalse(keys.contains("calendarId"))
    }

    /// The conditions the rule editor can build encode the way the core reads
    /// them (`#[serde(tag = "kind")]`, `rename_all = "camelCase"`).
    func testRuleConditionsMatchTheContract() throws {
        let cases: [(RuleCondition, [String: Any])] = [
            (.sender(.contains, "a@b.de"), ["kind": "sender", "op": "contains", "value": "a@b.de"]),
            (.recipient(.startsWith, "x"), ["kind": "recipient", "op": "startsWith", "value": "x"]),
            (.subject(.equals, "Rechnung"), ["kind": "subject", "op": "equals", "value": "Rechnung"]),
            (.label(7), ["kind": "label", "id": 7]),
            (.isAutomated(true), ["kind": "isAutomated", "value": true]),
            (.hasAttachment(false), ["kind": "hasAttachment", "value": false]),
            (.not(.sender(.contains, "a")), ["kind": "not", "cond": ["kind": "sender", "op": "contains", "value": "a"]]),
        ]
        for (condition, expected) in cases {
            let data = try JSONEncoder().encode(condition)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let wanted = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: expected)) as? [String: Any]
            XCTAssertEqual(object as NSDictionary, (wanted ?? [:]) as NSDictionary, "\(condition)")
        }
        // Round trip through the decoder keeps the tree.
        let trees: [RuleCondition] = [.all([.sender(.contains, "a"), .hasAttachment(true)]),
                                      .any([.label(1), .not(.isAutomated(false))])]
        for tree in trees {
            let data = try JSONEncoder().encode(tree)
            XCTAssertEqual(try JSONDecoder().decode(RuleCondition.self, from: data), tree)
        }
    }

    /// Commands without arguments are encoded as `{}` (`Record<string, never>`).
    func testCommandsWithoutArgumentsAreEmpty() throws {
        for (command, empty) in Self.emptyCommands {
            let shape = try contract.shape(command)
            XCTAssertTrue(shape.all.isEmpty, "\(command): Vertrag erwartet Argumente", file: #filePath, line: #line)
            try check(command, empty, file: #filePath, line: #line)
        }
    }

    /// Guards the parser itself: the contract file must actually be read.
    func testContractIsParsed() throws {
        XCTAssertGreaterThan(contract.commands.count, 40)
        XCTAssertNotNil(contract.interfaces["SaveDraftArgs"])
        XCTAssertEqual(try contract.shape("save_attachment").required, ["attachmentId", "dest"])
        XCTAssertTrue(try contract.shape("undo_last").all.isEmpty)
    }

    private struct EmptyArgs: Encodable {}
    private struct WithArgs<A: Encodable>: Encodable { let args: A }
    private struct SetSettingsArgs: Encodable { let settings: [String: String] }

    private static let emptyCommands: [(String, EmptyArgs)] = [
        "list_accounts", "list_splits", "list_labels", "get_sync_status", "get_settings", "undo_last",
        // M2.1
        "list_snippets", "restore_auto_labels", "relabel_auto",
        "mcp_status", "mcp_activity", "mcp_list_clients", "mcp_get_token", "mcp_regenerate_token",
        // M2.3
        "ai_status", "ai_list_models", "ai_usage_stats", "ai_learn_voice",
        "embedding_status", "semantic_reindex", "test_decision_provider",
    ].map { ($0, EmptyArgs()) }

    private static let draftArgs = SaveDraftArgs(draftId: nil, accountId: 1, to: [Address(name: nil, email: "a@b.de")],
                                                 cc: [], bcc: [], subject: "s", bodyText: "t", bodyHtml: nil,
                                                 mode: .reply, inReplyToMessageId: nil, attachments: [])

    private static let fullDraftArgs = SaveDraftArgs(draftId: 9, accountId: 1, to: [], cc: [], bcc: [], subject: "s",
                                                     bodyText: "t", bodyHtml: "<p>t</p>", mode: .new,
                                                     inReplyToMessageId: 12, attachments: [])

    private static let accountArgs = AddPasswordAccountArgs(email: "a@b.de", displayName: nil, username: "a@b.de",
                                                            password: "x", imapHost: "imap.example", imapPort: 993,
                                                            smtpHost: "smtp.example", smtpPort: 587)

    private static let namedAccountArgs = AddPasswordAccountArgs(email: "a@b.de", displayName: "A", username: "a@b.de",
                                                                 password: "x", imapHost: "imap.example", imapPort: 993,
                                                                 smtpHost: "smtp.example", smtpPort: 587)
}
