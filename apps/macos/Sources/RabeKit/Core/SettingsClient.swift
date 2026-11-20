import Foundation

// MARK: - Arguments of the settings commands (M2.1)

/// One type per command, encoded by `IPCContractTests` and compared with
/// `src/ipc/types.ts`. The dispatcher rejects unknown fields
/// (`deny_unknown_fields`), so these match the Rust input structs exactly —
/// including the places where `types.ts` is wider than the host
/// (`save_label` sends no `isAuto`, `save_split` no `keyword`).
extension IPCArgs {
    /// `set_account_display_name(args)`: `{accountId, name}`.
    struct SetAccountDisplayName: Encodable, Sendable {
        let accountId: Int64
        let name: String
    }

    /// `remove_account(args)`: `{accountId}`.
    struct RemoveAccount: Encodable, Sendable { let accountId: Int64 }

    /// `save_snippet(args)`: `{snippet: SnippetInput}` (no `args:` wrapper).
    struct SaveSnippet: Encodable, Sendable { let snippet: SnippetInput }
    struct DeleteSnippet: Encodable, Sendable { let snippetId: Int64 }

    /// `create_category(args)`: `{name, color, description}` — an auto label
    /// with model guidance, created outside the normal label editor.
    struct CreateCategory: Encodable, Sendable {
        let name: String
        let color: String
        let description: String
    }

    /// `save_label(args)`: `{label: {id, name, color, position}}`.
    struct SaveLabel: Encodable, Sendable { let label: LabelInput }
    struct DeleteLabel: Encodable, Sendable { let labelId: Int64 }

    /// `save_split(args)`: `{split: SplitInput}`.
    struct SaveSplit: Encodable, Sendable { let split: SplitInput }
    struct DeleteSplit: Encodable, Sendable { let splitId: Int64 }
    struct ReorderTabs: Encodable, Sendable { let order: [TabRef] }
    struct PreviewSplitCondition: Encodable, Sendable {
        let condition: RuleCondition
        let limit: Int64?
    }

    /// `mcp_client_snippet`/`mcp_install_client`: `{id}` (no camelCase rename).
    struct McpClientID: Encodable, Sendable { let id: String }
}

// MARK: - Typed wrappers for the settings editors

extension RabeClient {
    // Accounts
    public func setAccountDisplayName(accountId: Int64, name: String) async throws -> Account {
        try await call("set_account_display_name", IPCArgs.SetAccountDisplayName(accountId: accountId, name: name))
    }

    /// Removes the account from Rabe: credentials, account row, local mail cache
    /// and attachments. The server mailbox is untouched.
    public func removeAccount(_ id: Int64) async throws {
        try await send("remove_account", IPCArgs.RemoveAccount(accountId: id))
    }

    // Snippets
    public func listSnippets() async throws -> [Snippet] { try await call("list_snippets") }

    public func saveSnippet(_ input: SnippetInput) async throws -> Snippet {
        try await call("save_snippet", IPCArgs.SaveSnippet(snippet: input))
    }

    public func deleteSnippet(_ id: Int64) async throws {
        try await send("delete_snippet", IPCArgs.DeleteSnippet(snippetId: id))
    }

    // Labels
    public func saveLabel(_ input: LabelInput) async throws -> Label {
        try await call("save_label", IPCArgs.SaveLabel(label: input))
    }

    public func deleteLabel(_ id: Int64) async throws {
        try await send("delete_label", IPCArgs.DeleteLabel(labelId: id))
    }

    public func restoreAutoLabels() async throws -> Int64 { try await call("restore_auto_labels") }

    /// Adds an AI category (an auto label with a description for the model).
    public func createCategory(name: String, color: String, description: String) async throws -> Label {
        try await call("create_category", IPCArgs.CreateCategory(name: name, color: color, description: description))
    }

    // Splits, rules and tabs
    public func saveSplit(_ input: SplitInput) async throws -> SplitRule {
        try await call("save_split", IPCArgs.SaveSplit(split: input))
    }

    public func deleteSplit(_ id: Int64) async throws {
        try await send("delete_split", IPCArgs.DeleteSplit(splitId: id))
    }

    public func reorderTabs(_ order: [TabRef]) async throws {
        try await send("reorder_tabs", IPCArgs.ReorderTabs(order: order))
    }

    public func previewSplitCondition(_ condition: RuleCondition, limit: Int64? = nil) async throws -> ConditionPreview {
        try await call("preview_split_condition", IPCArgs.PreviewSplitCondition(condition: condition, limit: limit))
    }

    public func relabelAutoLabels() async throws -> Int64 { try await call("relabel_auto") }

    // MCP. The token never leaves `McpStore` unmasked and is never logged.
    public func mcpStatus() async throws -> McpStatus { try await call("mcp_status") }
    public func mcpActivity() async throws -> [McpCall] { try await call("mcp_activity") }
    public func mcpListClients() async throws -> [McpClientInfo] { try await call("mcp_list_clients") }
    public func mcpToken() async throws -> String { try await call("mcp_get_token") }
    public func mcpRegenerateToken() async throws -> String { try await call("mcp_regenerate_token") }
    public func mcpClientSnippet(id: String) async throws -> String {
        try await call("mcp_client_snippet", IPCArgs.McpClientID(id: id))
    }

    public func mcpInstallClient(id: String) async throws -> McpInstallResult {
        try await call("mcp_install_client", IPCArgs.McpClientID(id: id))
    }
}
