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
        try check("list_threads", IPCArgs.ListThreads(view: .inbox, splitId: 1, accountId: 2, cursor: 3, limit: 40))
        // Optional arguments are omitted when nil (`types.ts`: `splitId?: number | null`).
        try check("list_threads", IPCArgs.ListThreads(view: .all, splitId: nil, accountId: nil, cursor: nil, limit: 100))

        try check("get_thread", IPCArgs.GetThread(threadId: 11))
        try check("get_body", IPCArgs.GetBody(messageId: 12))

        let action = IPCArgs.PerformAction(kind: .archive, threadIds: [1, 2], params: nil)
        try check("perform_action", WithArgs(args: action))
        try check("PerformActionArgs", action)
        try check("PerformActionArgs.params", IPCArgs.ActionParams(wakeAt: 5))

        try check("unread_counts", IPCArgs.UnreadCounts(accountId: nil))
        try check("unread_counts", IPCArgs.UnreadCounts(accountId: 3))

        let search = IPCArgs.Search(query: "a", accountId: nil, limit: 100)
        try check("search", WithArgs(args: search))
        try check("SearchArgs", search)

        try check("suggest_contacts", IPCArgs.SuggestContacts(query: "b", limit: 8))

        try check("save_draft", WithArgs(args: Self.draftArgs))
        // `Option<T>` in the Rust DTO: a nil field may be missing (serde
        // deserializes a missing option as None), so it is simply not sent.
        try check("SaveDraftArgs", Self.draftArgs)
        try check("save_draft", WithArgs(args: Self.fullDraftArgs))
        try check("SaveDraftArgs", Self.fullDraftArgs)

        try check("delete_draft", IPCArgs.DeleteDraft(draftId: 4))
        try check("queue_send", WithArgs(args: IPCArgs.QueueSend(draftId: 5)))
        try check("QueueSendArgs", IPCArgs.QueueSend(draftId: 5))
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
