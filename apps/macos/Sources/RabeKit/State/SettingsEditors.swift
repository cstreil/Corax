import Foundation
import Observation

// Stores behind the settings editors (M2.1). They follow the pattern of
// `SettingsStore`: one `any MailCore`, one `ToastCenter` for failures, a
// `busy` flag while a write runs, and a reload after every change so the UI
// never shows a row the core did not keep.

// MARK: - Textbausteine

@MainActor
@Observable
public final class SnippetsStore {
    public private(set) var items: [Snippet] = []
    public private(set) var loaded = false
    public private(set) var busy = false
    public var client: (any MailCore)?
    public let toasts: ToastCenter

    public init(toasts: ToastCenter) { self.toasts = toasts }

    public func load() async {
        guard let client else { return }
        do {
            items = try await client.listSnippets()
            loaded = true
        } catch { toasts.error(error) }
    }

    @discardableResult
    public func save(_ input: SnippetInput) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.saveSnippet(input)
            await load()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func delete(_ id: Int64) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.deleteSnippet(id)
            items.removeAll { $0.id == id }
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }
}

// MARK: - Labels

@MainActor
@Observable
public final class LabelsStore {
    public private(set) var items: [Label] = []
    public private(set) var loaded = false
    public private(set) var busy = false
    public var client: (any MailCore)?
    public let toasts: ToastCenter

    public init(toasts: ToastCenter) { self.toasts = toasts }

    /// User labels first, then the auto categories, each by position — the
    /// order the labels panel lists them in.
    public var sorted: [Label] {
        items.sorted { lhs, rhs in
            let l = lhs.isAuto == true ? 1 : 0
            let r = rhs.isAuto == true ? 1 : 0
            if l != r { return l < r }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Position for a new label: one past the highest user-label position.
    public var nextPosition: Int64 {
        (items.filter { $0.isAuto != true }.map(\.position).max() ?? -1) + 1
    }

    public func load() async {
        guard let client else { return }
        do {
            items = try await client.labels()
            loaded = true
        } catch { toasts.error(error) }
    }

    @discardableResult
    public func save(_ input: LabelInput) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.saveLabel(input)
            await load()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    @discardableResult
    public func delete(_ id: Int64) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.deleteLabel(id)
            items.removeAll { $0.id == id }
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// Adds an AI category (an auto label plus its model guidance).
    @discardableResult
    public func createCategory(name: String, color: String, description: String) async -> Label? {
        guard let client, !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let label = try await client.createCategory(name: name, color: color, description: description)
            await load()
            return label
        } catch {
            toasts.error(error)
            return nil
        }
    }

    /// Recreates the four missing auto categories; returns how many came back.
    @discardableResult
    public func restoreAutoLabels() async -> Int64? {
        guard let client, !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let count = try await client.restoreAutoLabels()
            await load()
            return count
        } catch {
            toasts.error(error)
            return nil
        }
    }
}

// MARK: - Splits, Regeln und Tab-Reihenfolge

/// One reorderable inbox tab: a custom split or an auto-label tab. The built-in
/// Important/Other rows are not part of this list — Important is always first,
/// Other always last (`settings:splits.builtinNote`).
public struct TabItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case split, label }

    public let kind: Kind
    public let id: Int64
    public let name: String
    public let position: Int64
    /// Set for splits only; a split with a `target` routes into an existing tab.
    public let target: String?
    public let isAutoCategory: Bool

    public var tabIdentity: String { "\(kind.rawValue):\(id)" }
    public var reference: TabRef { TabRef(kind: kind.rawValue, id: id) }
    /// Rules routed into an existing tab own no tab of their own.
    public var ownsTab: Bool { kind == .label || target == nil }
}

@MainActor
@Observable
public final class SplitsStore {
    public private(set) var splits: [SplitRule] = []
    public private(set) var autoLabels: [Label] = []
    /// Custom splits and auto-label tabs in their shared order.
    public private(set) var tabs: [TabItem] = []
    public private(set) var loaded = false
    public private(set) var busy = false
    public private(set) var lastPreview: ConditionPreview?
    public var client: (any MailCore)?
    public let toasts: ToastCenter

    public init(toasts: ToastCenter) { self.toasts = toasts }

    /// Position for a new rule: one past the highest position across splits and
    /// auto-label tabs (`nextTabPosition` in `src/lib/splitOrder.ts`).
    public var nextPosition: Int64 {
        let positions = splits.map(\.position) + autoLabels.map(\.position)
        return (positions.max() ?? -1) + 1
    }

    public func load() async {
        guard let client else { return }
        do {
            let rules = try await client.splits()
            let labels = try await client.labels()
            splits = rules
            autoLabels = labels.filter { $0.isAuto == true }
            tabs = Self.mergeTabOrder(splits, autoLabels)
            loaded = true
        } catch { toasts.error(error) }
    }

    /// `mergeTabOrder` (`src/lib/splitOrder.ts`): both lists by position; if the
    /// two position ranges collide (legacy data), splits first, then labels, so
    /// the user's arrangement does not shuffle.
    static func mergeTabOrder(_ splits: [SplitRule], _ labels: [Label]) -> [TabItem] {
        let splitItems = splits.sorted { $0.position < $1.position }.map {
            TabItem(kind: .split, id: $0.id, name: $0.name, position: $0.position,
                    target: $0.target, isAutoCategory: false)
        }
        let labelItems = labels.sorted { $0.position < $1.position }.map {
            TabItem(kind: .label, id: $0.id, name: $0.name, position: $0.position,
                    target: nil, isAutoCategory: true)
        }
        let collides = splitItems.contains { s in labelItems.contains { $0.position == s.position } }
        if collides { return splitItems + labelItems }
        return (splitItems + labelItems).sorted { $0.position < $1.position }
    }

    @discardableResult
    public func save(_ input: SplitInput) async -> SplitRule? {
        guard let client, !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let rule = try await client.saveSplit(input)
            await load()
            return rule
        } catch {
            toasts.error(error)
            return nil
        }
    }

    @discardableResult
    public func delete(_ id: Int64) async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await client.deleteSplit(id)
            splits.removeAll { $0.id == id }
            tabs = Self.mergeTabOrder(splits, autoLabels)
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// Moves a tab and persists the shared order (`reorder_tabs`). `to` is the
    /// target index among `tabs`; the built-in rows stay outside this list.
    @discardableResult
    public func move(from: Int, to: Int) async -> Bool {
        guard let client, !busy else { return false }
        guard from != to, tabs.indices.contains(from), to >= 0, to < tabs.count else { return false }
        var next = tabs
        let moved = next.remove(at: from)
        next.insert(moved, at: to)
        busy = true
        defer { busy = false }
        do {
            try await client.reorderTabs(next.map(\.reference))
            tabs = next
            await load()
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// Dry run of a condition against the most recent threads.
    @discardableResult
    public func preview(_ condition: RuleCondition) async -> ConditionPreview? {
        guard let client else { return nil }
        do {
            let result = try await client.previewSplitCondition(condition, limit: nil)
            lastPreview = result
            return result
        } catch {
            toasts.error(error)
            return nil
        }
    }

    /// Re-runs auto-label classification; returns the number of labeled threads.
    @discardableResult
    public func relabelAutoLabels() async -> Int64? {
        guard let client, !busy else { return nil }
        busy = true
        defer { busy = false }
        do { return try await client.relabelAutoLabels() } catch {
            toasts.error(error)
            return nil
        }
    }

    @discardableResult
    public func restoreAutoLabels() async -> Int64? {
        guard let client, !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let count = try await client.restoreAutoLabels()
            await load()
            return count
        } catch {
            toasts.error(error)
            return nil
        }
    }
}

// MARK: - MCP

/// Status, clients and the access token of the local MCP server.
///
/// The token is held in memory only and never logged, printed or written to a
/// report (`mcp_get_token`/`mcp_regenerate_token`); the UI shows `maskedToken`
/// and copies the real value straight to the clipboard.
@MainActor
@Observable
public final class McpStore {
    public private(set) var status: McpStatus?
    public private(set) var clients: [McpClientInfo] = []
    public private(set) var activity: [McpCall] = []
    public private(set) var token: String?
    public private(set) var tokenRevealed = false
    public private(set) var busy = false
    public var client: (any MailCore)?
    public let toasts: ToastCenter
    private let platform: any PlatformServices

    public init(toasts: ToastCenter, platform: any PlatformServices) {
        self.toasts = toasts
        self.platform = platform
    }

    public var maskedToken: String {
        guard let token, token.count > 8 else { return "••••••••••••" }
        return token.prefix(4) + "…" + token.suffix(4)
    }

    /// What the token field shows: masked unless the user revealed it.
    public var displayedToken: String { tokenRevealed ? (token ?? "") : maskedToken }

    public func load() async {
        guard let client else { return }
        do {
            status = try await client.mcpStatus()
            clients = try await client.mcpListClients()
            activity = try await client.mcpActivity()
        } catch { toasts.error(error) }
    }

    /// Fetches the token once; `mcp_get_token` may create it in the keychain.
    @discardableResult
    public func revealToken() async -> Bool {
        guard let client else { return false }
        if token == nil {
            do { token = try await client.mcpToken() } catch { toasts.error(error); return false }
        }
        tokenRevealed = true
        return true
    }

    public func hideToken() { tokenRevealed = false }

    /// Creates a new token; every client has to be re-added afterwards.
    @discardableResult
    public func regenerateToken() async -> Bool {
        guard let client, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            token = try await client.mcpRegenerateToken()
            tokenRevealed = true
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// Copies the token to the clipboard — the only way it leaves the store.
    @discardableResult
    public func copyToken() async -> Bool {
        guard let client else { return false }
        do {
            var value = token
            if value == nil { value = try await client.mcpToken() }
            guard let value else { return false }
            token = value
            return platform.copyToClipboard(value)
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// A ready-made client config snippet. It contains the token, so callers
    /// only write it to the clipboard or show it on request.
    public func snippet(for clientID: String) async -> String? {
        guard let client else { return nil }
        do { return try await client.mcpClientSnippet(id: clientID) } catch {
            toasts.error(error)
            return nil
        }
    }

    @discardableResult
    public func copySnippet(for clientID: String) async -> Bool {
        guard let snippet = await snippet(for: clientID) else { return false }
        return platform.copyToClipboard(snippet)
    }

    @discardableResult
    public func install(_ clientID: String) async -> McpInstallResult? {
        guard let client, !busy else { return nil }
        busy = true
        defer { busy = false }
        do {
            let result = try await client.mcpInstallClient(id: clientID)
            await load()
            return result
        } catch {
            toasts.error(error)
            return nil
        }
    }
}
