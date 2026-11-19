import Foundation
import Observation
import os

/// One row of the mail list.
/// Geometry of the list for keyboard scrolling (implemented by the table).
@MainActor
public protocol ListNavigating: AnyObject {
    /// Visible part of the detail row, in its own coordinates (top = 0).
    func visibleDetailRange(_ id: Int64) -> ClosedRange<CGFloat>?
    /// Scrolls so that detail coordinate `y` lies at the top of the visible area.
    func scrollDetail(_ id: Int64, toTop y: CGFloat)
    func scrollList(by dy: CGFloat)
    /// Bild↓/Bild↑ in the list: scroll one page, return the thread at the same
    /// window position as `selected`.
    func pageList(_ direction: Int, selected: Int64?) -> Int64?
}

public enum ListRow: Hashable {
    case header(key: String, label: String)
    case thread(Int64)
    case detail(Int64)

    public var threadID: Int64? {
        switch self {
        case .thread(let id), .detail(let id): id
        case .header: nil
        }
    }
}

/// Inbox tab: a split (`list_splits`) or the built-in Important/Other routes.
public struct InboxTab: Identifiable, Hashable {
    public let id: String
    public let title: String
    let splitId: Int64?
    public var unread: Int64
}

/// List state: view, tab, account, pages, selection, the expanded thread,
/// optimistic actions with rollback and undo, search.
@MainActor
@Observable
public final class MailboxStore {
    static let splitImportant: Int64 = -1   // SPLIT_IMPORTANT in src/stores/ui.ts
    static let splitOther: Int64 = -2       // SPLIT_OTHER

    // Navigation
    public private(set) var view: MailView = .inbox
    private(set) var tabID: String = "important"
    public private(set) var accountId: Int64?
    public private(set) var accounts: [Account] = []
    private(set) var splits: [SplitRule] = []
    public private(set) var labels: [Int64: Label] = [:]
    public private(set) var unread: UnreadCounts?

    // List
    public private(set) var threads: [ThreadSummary] = [] {
        didSet {
            contentVersion &+= 1
            if appendingThreads == 0 { baseRowsValid = false }
            let has = !threads.isEmpty
            if hasThreads != has { hasThreads = has }
        }
    }
    /// For views that only need to know whether the list is empty, so they do
    /// not re-render on every page.
    public private(set) var hasThreads = false
    /// Bumped on every change of `threads`; the table redraws visible rows then
    /// (replaces hashing all threads in each view update).
    public private(set) var contentVersion = 0
    public private(set) var nextCursor: Int64?
    public private(set) var isLoading = false
    public private(set) var loadedOnce = false
    public private(set) var selectedId: Int64?
    public private(set) var expandedId: Int64?

    // Search
    public private(set) var searchQuery: String?
    public var searchText = ""

    // Detail
    public private(set) var details: [Int64: ThreadDetail] = [:]
    private(set) var loadingDetail: Set<Int64> = []
    /// Per message: show remote images despite the setting ("Bilder laden").
    public var remoteImageOverride: Set<Int64> = []
    /// Older messages the user unfolded.
    public var unfoldedMessages: Set<Int64> = []
    /// State B (TASTATUR.md): the message keys and replies refer to. nil =
    /// default (newest unread, else the last one).
    public var focusedMessageId: Int64?
    /// Message frames inside the detail row (SwiftUI geometry, top = 0).
    @ObservationIgnored public var messageFrames: [Int64: CGRect] = [:]
    /// The list view, for scroll steps that depend on its geometry.
    @ObservationIgnored public weak var navigator: ListNavigating?

    // Inline reply
    public var inlineCompose: ComposeDraft?
    /// Bumped to give the list keyboard focus again (after sending, Esc in a field).
    public private(set) var focusListRequest = 0
    public func focusList() { focusListRequest += 1 }

    public var client: (any MailCore)?
    public let toasts: ToastCenter
    public let settings: SettingsStore
    /// P2g: the visible write switch. Read right before a write, so switching
    /// it off stops the automatic `mark_read` at once.
    public let writeAccess: WriteAccess
    /// AppKit work the store needs (the save panel); injected by `AppModel`.
    private let platform: any PlatformServices
    private let cache = ThreadCache()
    private let pageSize = 100
    private var listGeneration = 0
    private static let signposter = OSSignposter(subsystem: "de.streil.rabe.native", category: "ui")
    public private(set) var firstListMs: Int?

    public init(toasts: ToastCenter, settings: SettingsStore, writeAccess: WriteAccess,
                platform: any PlatformServices) {
        self.toasts = toasts
        self.settings = settings
        self.writeAccess = writeAccess
        self.platform = platform
    }

    // MARK: Derived

    public var title: String { searchQuery.map { "Suche: \($0)" } ?? Strings.view(view) }

    public var tabs: [InboxTab] {
        guard view == .inbox, searchQuery == nil else { return [] }
        // One unsplit inbox: the title already says "Posteingang".
        if !settings.inboxDefaultSplits, !splits.contains(where: { $0.target == nil }) { return [] }
        let ownTabs = splits.filter { $0.target == nil }.sorted { $0.position < $1.position }
        var out: [InboxTab] = []
        if settings.inboxDefaultSplits {
            out.append(InboxTab(id: "important", title: "Wichtig", splitId: Self.splitImportant, unread: unread?.important ?? 0))
        } else {
            out.append(InboxTab(id: "important", title: "Posteingang", splitId: nil, unread: unread?.inbox ?? 0))
        }
        for split in ownTabs {
            out.append(InboxTab(id: "split-\(split.id)", title: split.name, splitId: split.id,
                                unread: unread?.splits[String(split.id)] ?? 0))
        }
        if settings.inboxDefaultSplits {
            out.append(InboxTab(id: "other", title: "Andere", splitId: Self.splitOther, unread: unread?.other ?? 0))
        }
        return out
    }

    private var currentSplitId: Int64? {
        tabs.first(where: { $0.id == tabID })?.splitId ?? tabs.first?.splitId
    }

    /// Rows for the table: date headers, threads, and the expanded thread's
    /// detail row directly below its own row (`buildListItems`). The rows
    /// without the detail row are kept and only extended when a page is
    /// appended (P2d: paging cost no longer grows with the list).
    public var rows: [ListRow] {
        _ = contentVersion                 // observation
        let day = Calendar.current.startOfDay(for: Date())
        if !baseRowsValid || baseRowsDay != day || baseRowsSearch != (searchQuery != nil) {
            baseRows = []; baseThreadIndex = [:]; baseLastKey = nil; baseCount = 0
            baseRowsDay = day; baseRowsSearch = searchQuery != nil
            extendBaseRows()
            baseRowsValid = true
        } else if baseCount < threads.count {
            extendBaseRows()
        }
        guard let expandedId, let i = baseThreadIndex[expandedId] else { return baseRows }
        var out = baseRows
        out.insert(.detail(expandedId), at: i + 1)
        return out
    }

    @ObservationIgnored private var baseRows: [ListRow] = []
    @ObservationIgnored private var baseThreadIndex: [Int64: Int] = [:]
    @ObservationIgnored private var baseLastKey: String?
    @ObservationIgnored private var baseCount = 0
    @ObservationIgnored private var baseRowsValid = false
    @ObservationIgnored private var baseRowsDay = Date.distantPast
    @ObservationIgnored private var baseRowsSearch = false
    @ObservationIgnored private var appendingThreads = 0

    private func extendBaseRows() {
        let grouping = Format.Grouping(now: Date())
        baseRows.reserveCapacity(threads.count + 24)
        for thread in threads[baseCount...] {
            if !baseRowsSearch {
                let group = grouping.group(thread.date)
                if group.key != baseLastKey {
                    baseRows.append(.header(key: group.key, label: group.label))
                    baseLastKey = group.key
                }
            }
            baseThreadIndex[thread.id] = baseRows.count
            baseRows.append(.thread(thread.id))
        }
        baseCount = threads.count
    }

    /// Focused message of the open thread (explicit, else newest unread, else last).
    public func focusedMessage(in detail: ThreadDetail) -> MessageDetail? {
        let messages = detail.messages.filter { !($0.isDraft && $0.sendState == nil) }
        if let id = focusedMessageId, let m = messages.first(where: { $0.id == id }) { return m }
        return messages.last(where: { !$0.isRead }) ?? messages.last
    }

    public var hasMore: Bool { nextCursor != nil }

    public func thread(_ id: Int64) -> ThreadSummary? { threads.first { $0.id == id } }
    public func index(of id: Int64) -> Int? { threads.firstIndex { $0.id == id } }

    // MARK: Start / navigation

    public func bootstrap() async {
        guard let client else { return }
        async let accounts = try? client.accounts()
        async let splits = try? client.splits()
        async let labels = try? client.labels()
        self.accounts = await accounts ?? []
        self.splits = await splits ?? []
        self.labels = Dictionary(uniqueKeysWithValues: (await labels ?? []).map { ($0.id, $0) })
        if !tabs.contains(where: { $0.id == tabID }) { tabID = tabs.first?.id ?? "important" }
        await reload()
        refreshUnread()
    }

    func refreshAccounts() async {
        guard let client else { return }
        if let list = try? await client.accounts() { accounts = list }
    }

    public func setView(_ newView: MailView) {
        guard newView != view || searchQuery != nil else { return }
        view = newView
        searchQuery = nil
        searchText = ""
        tabID = tabs.first?.id ?? "important"
        resetAndReload()
    }

    public func setAccount(_ id: Int64?) {
        guard id != accountId else { return }
        accountId = id
        resetAndReload()
        refreshUnread()
    }

    public func setTab(_ id: String) {
        guard id != tabID else { return }
        tabID = id
        resetAndReload()
    }

    public func cycleTab(_ step: Int) {
        let all = tabs
        guard all.count > 1, let i = all.firstIndex(where: { $0.id == tabID }) else { return }
        setTab(all[(i + step + all.count) % all.count].id)
    }

    public var currentTabID: String { tabID }

    private func resetAndReload() {
        userNavigation = true
        isLoading = true
        expandedId = nil
        inlineCompose = nil
        threads = []
        nextCursor = nil
        Task { await reload() }
    }

    // MARK: Loading

    func reload() async {
        guard let client else { return }
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        defer { if generation == listGeneration { isLoading = false } }
        let state = Self.signposter.beginInterval("list_page")
        do {
            if let query = searchQuery {
                let results = try await client.search(query, accountId: accountId)
                guard generation == listGeneration else { return }
                applyThreads(results.threads, cursor: nil)
            } else {
                let page = try await client.listThreads(view: view, splitId: currentSplitId, accountId: accountId, cursor: nil, limit: pageSize)
                guard generation == listGeneration else { return }
                applyThreads(page.threads, cursor: page.nextCursor)
            }
            Self.signposter.endInterval("list_page", state)
            if firstListMs == nil {
                firstListMs = PerfLog.shared.elapsedMilliseconds
                PerfLog.shared.write("first_list_data ms=\(firstListMs!) count=\(threads.count)")
                client.notifyUiReady()
            }
        } catch {
            Self.signposter.endInterval("list_page", state)
            toasts.error(error)
        }
        loadedOnce = true
    }

    /// Applies a fresh list (reload, sync update; internal for the W3 test).
    public func applyThreads(_ fresh: [ThreadSummary], cursor: Int64?) {
        let oldIndex = selectedId.flatMap { id in threads.firstIndex { $0.id == id } }
        let stillThere = selectedId.map { id in fresh.contains { $0.id == id } } ?? false
        let openGone = expandedId.map { id in !fresh.contains { $0.id == id } } ?? false
        threads = fresh
        nextCursor = cursor
        if selectedId == nil {
            selectedId = fresh.first?.id          // first page: row one
        } else if !stillThere {
            // W3: the thread vanished (e.g. archived on another device). Move to
            // the neighbour at the old position instead of jumping to row one.
            let neighbour = oldIndex.flatMap { i in fresh.indices.contains(i) ? fresh[i].id : fresh.last?.id }
            selectedId = neighbour
            // Only a change nobody asked for arms the "ignore the next action"
            // guard; after a view switch the user knows where the selection is.
            if neighbour != nil, !userNavigation { autoSelectedAt = CFAbsoluteTimeGetCurrent() }
        }
        userNavigation = false
        if openGone {
            expandedId = nil
            inlineCompose = nil
            toasts.show("Thread wurde verschoben")
        }
    }

    /// The table asks for this near the end of the list.
    public func loadMoreIfNeeded() {
        guard !isLoading, searchQuery == nil, let cursor = nextCursor, let client else { return }
        isLoading = true
        let generation = listGeneration
        Task {
            defer { isLoading = false }
            do {
                let page = try await client.listThreads(view: view, splitId: currentSplitId, accountId: accountId, cursor: cursor, limit: pageSize)
                guard generation == listGeneration else { return }
                let known = Set(threads.map(\.id))
                let fresh = page.threads.filter { !known.contains($0.id) }
                appendingThreads += 1
                threads.append(contentsOf: fresh)
                appendingThreads -= 1
                nextCursor = page.nextCursor
            } catch {
                toasts.error(error)
            }
        }
    }

    func refreshUnread() {
        guard let client else { return }
        Task { if let counts = try? await client.unreadCounts() { self.unread = counts } }
    }

    /// `mail:updated` / `mail:new`: refresh the affected rows; unknown ids (new
    /// mail) reload the first page.
    public func mailUpdated(_ ids: [Int64]) {
        guard let client, loadedOnce else { return }
        refreshUnread()
        let known = Set(threads.map(\.id))
        let affected = ids.filter { known.contains($0) }
        let unknown = ids.contains { !known.contains($0) }
        for id in affected { cache.invalidate(id) }
        Task {
            if unknown || affected.count > 20 {
                await reloadKeepingPosition()
                return
            }
            for id in affected {
                guard let detail = try? await client.getThread(id) else {
                    // Gone from this view (moved elsewhere).
                    continue
                }
                cache.put(detail)
                if let i = index(of: id) { threads[i] = detail.thread }
                if details[id] != nil { details[id] = detail }
            }
        }
    }

    private func reloadKeepingPosition() async {
        guard let client, searchQuery == nil else { return }
        guard let page = try? await client.listThreads(view: view, splitId: currentSplitId, accountId: accountId, cursor: nil, limit: max(pageSize, threads.count)) else { return }
        applyThreads(page.threads, cursor: page.nextCursor)
    }

    // MARK: Selection and expansion

    public func select(_ id: Int64?) { selectedId = id; autoSelectedAt = nil }

    public func step(_ delta: Int) {
        guard !threads.isEmpty else { return }
        autoSelectedAt = nil
        let current = selectedId.flatMap { index(of: $0) } ?? -1
        let next = max(0, min(threads.count - 1, current + delta))
        let id = threads[next].id
        if expandedId != nil, expandedId != id {
            selectedId = id
            expand(id)
        } else {
            selectedId = id
        }
        if next >= threads.count - 60 { loadMoreIfNeeded() }
    }

    /// `Bild↓`/`Bild↑` in state A.
    public func pageList(_ direction: Int) {
        guard let id = navigator?.pageList(direction, selected: selectedId) else { return }
        autoSelectedAt = nil
        selectedId = id
        if let i = index(of: id), i >= threads.count - 60 { loadMoreIfNeeded() }
    }

    /// `Pos1`/`Ende` in state A; `Ende` loads every remaining page first.
    public func selectEdge(first: Bool) {
        autoSelectedAt = nil
        if first { selectedId = threads.first?.id; return }
        guard nextCursor != nil, searchQuery == nil, let client else { selectedId = threads.last?.id; return }
        let generation = listGeneration
        Task {
            while generation == listGeneration, let cursor = nextCursor {
                guard let page = try? await client.listThreads(view: view, splitId: currentSplitId, accountId: accountId,
                                                               cursor: cursor, limit: 500) else { break }
                guard generation == listGeneration else { return }
                let known = Set(threads.map(\.id))
                appendingThreads += 1
                threads.append(contentsOf: page.threads.filter { !known.contains($0.id) })
                appendingThreads -= 1
                nextCursor = page.nextCursor
            }
            selectedId = threads.last?.id
        }
    }

    public func toggle(_ id: Int64? = nil) {
        guard let id = id ?? selectedId else { return }
        autoSelectedAt = nil
        selectedId = id
        if expandedId == id { collapse() } else { expand(id) }
    }

    public func collapse() {
        expandedId = nil
        inlineCompose = nil
    }

    /// Timing of the current expansion (Anforderung 13).
    private(set) var expandStart: (id: Int64, at: CFAbsoluteTime, cached: Bool)?
    private var loggedVisible: Set<Int64> = []
    private var loggedHTML: Set<Int64> = []

    public func noteDetailVisible(_ id: Int64, hasHTML: Bool) {
        guard let start = expandStart, start.id == id, !loggedVisible.contains(id) else { return }
        loggedVisible.insert(id)
        let ms = (CFAbsoluteTimeGetCurrent() - start.at) * 1000
        PerfLog.shared.write(String(format: "detail_visible id=%lld ms=%.1f cached=%@ html=%@", id, ms, start.cached ? "1" : "0", hasHTML ? "1" : "0"))
    }

    public func noteHTMLMeasured(_ id: Int64) {
        guard let start = expandStart, start.id == id, !loggedHTML.contains(id) else { return }
        loggedHTML.insert(id)
        let ms = (CFAbsoluteTimeGetCurrent() - start.at) * 1000
        PerfLog.shared.write(String(format: "html_measured id=%lld ms=%.1f cached=%@", id, ms, start.cached ? "1" : "0"))
    }

    public func expand(_ id: Int64) {
        let state = Self.signposter.beginInterval("expand")
        inlineCompose = nil
        unfoldedMessages = []
        focusedMessageId = nil
        messageFrames = [:]
        let cached = cache.get(id)
        expandStart = (id, CFAbsoluteTimeGetCurrent(), cached != nil)
        loggedVisible.remove(id)
        loggedHTML.remove(id)
        if let cached {
            details[id] = cached
        }
        expandedId = id
        Self.signposter.endInterval("expand", state)
        loadDetail(id)
        if let summary = thread(id), summary.isUnread { markRead(id) }
    }

    private func loadDetail(_ id: Int64) {
        guard let client, !loadingDetail.contains(id) else { return }
        loadingDetail.insert(id)
        let started = Date()
        Task {
            defer { loadingDetail.remove(id) }
            do {
                var detail = try await client.getThread(id)
                // Fetch missing bodies of the newest message (others load when unfolded).
                if let last = detail.messages.indices.last, detail.messages[last].bodyState != "cached" {
                    if let body = try? await client.getBody(detail.messages[last].id) { detail.messages[last] = body }
                }
                cache.put(detail)
                details[id] = detail
                PerfLog.shared.write("thread_loaded id=\(id) ms=\(Int(Date().timeIntervalSince(started) * 1000)) messages=\(detail.messages.count)")
            } catch {
                toasts.error(error)
            }
        }
    }

    public func loadBody(messageId: Int64, threadId: Int64) {
        guard let client else { return }
        Task {
            guard let body = try? await client.getBody(messageId), var detail = details[threadId],
                  let i = detail.messages.firstIndex(where: { $0.id == messageId }) else { return }
            detail.messages[i] = body
            details[threadId] = detail
            cache.put(detail)
        }
    }

    // MARK: Actions (optimistic, `E # H S U Z`)

    private struct Removed { let thread: ThreadSummary; let index: Int; let wasExpanded: Bool }
    /// The thread the last removing action took out, to select it again after undo.
    private var lastRemovedId: Int64?

    // MARK: Undo ticket (W1) and deferred auto-mark-read

    /// The action the visible undo toast belongs to. While it stands, the
    /// automatic `mark_read` of an opened thread is only shown locally and sent
    /// when the toast goes away: `undo_last` undoes the *newest* core action
    /// (`db/repo/actions.rs: last_undoable`), so an early `mark_read` would
    /// swallow the undo.
    private struct UndoEntry {
        enum Kind { case removed, star, readState }
        let kind: Kind
        let threadId: Int64
        /// The row as it was before the action, to restore and to verify.
        let previous: ThreadSummary
        /// Only for `.removed`: the thread was open, undo opens it again.
        var wasExpanded = false
    }
    private var undoTicket: UndoEntry?
    /// Writes this UI sent after the ticket's own action; then `undo_last` would
    /// not hit the ticket's action any more (R2 c, own actions only).
    private var coreActionsAfterTicket = 0
    /// Auto `mark_read` held back while an undo toast stands.
    private var pendingMarkRead: [Int64: ThreadSummary] = [:]
    /// Serializes every write to the core, so a deferred `mark_read` can never
    /// land after the action it was meant to precede.
    private var writeChain: Task<Void, Never>?
    /// Selection that changed without the user (list update, W3).
    private var autoSelectedAt: CFAbsoluteTime?
    /// The next `apply` belongs to a view/tab/search switch the user asked for.
    private var userNavigation = false

    /// Tests: waits until every queued write has run (the chain keeps chaining).
    func waitForPendingWrites() async { await writeChain?.value }

    private func enqueueWrite(countsAsOtherAction: Bool = true, _ op: @escaping @MainActor () async -> Void) {
        if countsAsOtherAction, undoTicket != nil { coreActionsAfterTicket += 1 }
        let previous = writeChain
        writeChain = Task { @MainActor in
            _ = await previous?.value
            await op()
        }
    }

    /// A new user action: deferred reads belong to the core before it, and the
    /// old ticket ends (its toast is replaced by the new one).
    private func beginUserAction() {
        // The old toast goes first: its onClose ends the old undo window (and
        // flushes deferred reads before the action below is queued).
        toasts.dismiss()
        flushPendingMarkRead()
        undoTicket = nil
        coreActionsAfterTicket = 0
        autoSelectedAt = nil
    }

    private func takePendingMarkRead() -> [Int64: ThreadSummary] {
        let pending = pendingMarkRead
        pendingMarkRead = [:]
        return pending
    }

    private func sendPending(_ entries: [Int64: ThreadSummary]) {
        // A read held back while the undo toast stood must not go out after the
        // switch was turned off (it would be refused and toast for nothing).
        guard writeAccess.allowed else {
            if !entries.isEmpty { PerfLog.shared.write("mark_read_dropped writes=off count=\(entries.count)") }
            return
        }
        for (id, before) in entries.sorted(by: { $0.key < $1.key }) {
            PerfLog.shared.write("mark_read_flushed id=\(id)")
            enqueueWrite(countsAsOtherAction: false) { [weak self] in
                guard let self, let client = self.client else { return }
                do { _ = try await client.performAction(.markRead, threadIds: [id]); self.refreshUnread() } catch {
                    if let j = self.index(of: id) { self.threads[j] = before }
                }
            }
        }
    }

    /// Sends the reads that were held back while the toast stood. Called when
    /// the toast closes, and before the next user action.
    func flushPendingMarkRead() { sendPending(takePendingMarkRead()) }

    /// W3: an action key right after a list update selected a thread the user
    /// did not see yet — ignore it once.
    public func shouldIgnoreActionOnAutoSelection() -> Bool {
        guard let at = autoSelectedAt else { return false }
        autoSelectedAt = nil
        let recent = CFAbsoluteTimeGetCurrent() - at < 0.5
        if recent { PerfLog.shared.write("action_ignored reason=auto_selection") }
        return recent
    }

    public func archive(_ id: Int64? = nil) { remove(id, kind: .archive, label: Strings.archived) }
    public func trash(_ id: Int64? = nil) { remove(id, kind: .trash, label: Strings.trashed) }
    public func snooze(_ id: Int64? = nil, until date: Date = Format.tomorrowMorning(), label: String = Strings.snoozedUntilTomorrow) {
        remove(id, kind: .snooze, label: label, wakeAt: Int64(date.timeIntervalSince1970 * 1000))
    }

    private func remove(_ id: Int64?, kind: ActionKind, label: String, wakeAt: Int64? = nil) {
        guard let id = id ?? selectedId, let client, let index = index(of: id) else { return }
        let removed = Removed(thread: threads[index], index: index, wasExpanded: expandedId == id)
        beginUserAction()
        undoTicket = UndoEntry(kind: .removed, threadId: id, previous: removed.thread, wasExpanded: removed.wasExpanded)
        lastRemovedId = id
        // Same frame: the row goes, the selection moves on.
        threads.remove(at: index)
        if expandedId == id { expandedId = nil; inlineCompose = nil }
        if selectedId == id {
            let next = threads.indices.contains(index) ? threads[index].id : threads.last?.id
            selectedId = next
            if removed.wasExpanded, let next { expand(next) }
        }
        toasts.show(label, actionTitle: Strings.undo, action: { [weak self] in self?.undo() },
                    onClose: { [weak self] in self?.endUndoWindow() })
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.performAction(kind, threadIds: [id], wakeAt: wakeAt)
                self.refreshUnread()
            } catch {
                self.restore(removed)
                self.toasts.error(error)
            }
        }
    }

    private func restore(_ removed: Removed) {
        guard index(of: removed.thread.id) == nil else { return }
        threads.insert(removed.thread, at: min(removed.index, threads.count))
        // Same rule as the undo path (N-P2a): an open thread keeps the selection.
        selectedId = expandedId ?? removed.thread.id
    }

    public func toggleStar(_ id: Int64? = nil) {
        guard let id = id ?? selectedId, let i = index(of: id), let client else { return }
        let before = threads[i]
        beginUserAction()
        threads[i].isStarred.toggle()
        let kind: ActionKind = threads[i].isStarred ? .star : .unstar
        undoTicket = UndoEntry(kind: .star, threadId: id, previous: before)
        toasts.show(threads[i].isStarred ? Strings.starred : Strings.unstarred, actionTitle: Strings.undo,
                    action: { [weak self] in self?.undo() },
                    onClose: { [weak self] in self?.endUndoWindow() })
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do { _ = try await client.performAction(kind, threadIds: [id]); self.refreshUnread() } catch {
                if let j = self.index(of: id) { self.threads[j] = before }
                self.toasts.error(error)
            }
        }
    }

    public func toggleUnread(_ id: Int64? = nil) {
        guard let id = id ?? selectedId, let i = index(of: id), let client else { return }
        let before = threads[i]
        let makeUnread = !before.isUnread
        beginUserAction()
        threads[i].unreadCount = makeUnread ? max(1, before.messageCount > 0 ? 1 : 1) : 0
        if makeUnread, expandedId == id { collapse() }
        undoTicket = UndoEntry(kind: .readState, threadId: id, previous: before)
        toasts.show(makeUnread ? Strings.markedUnread : Strings.markedRead, actionTitle: Strings.undo,
                    action: { [weak self] in self?.undo() },
                    onClose: { [weak self] in self?.endUndoWindow() })
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do { _ = try await client.performAction(makeUnread ? .markUnread : .markRead, threadIds: [id]); self.refreshUnread() } catch {
                if let j = self.index(of: id) { self.threads[j] = before }
                self.toasts.error(error)
            }
        }
    }

    /// Opening an unread thread marks it read (no toast, no undo entry). While an
    /// undo toast stands it is only shown locally and sent when the toast closes.
    private func markRead(_ id: Int64) {
        guard let client, writeAccess.allowed, let i = index(of: id) else { return }
        let before = threads[i]
        threads[i].unreadCount = 0
        if undoTicket != nil {
            pendingMarkRead[id] = before
            if let start = expandStart, start.id == id { PerfLog.shared.write("mark_read_deferred id=\(id) toast=1") }
            return
        }
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do { _ = try await client.performAction(.markRead, threadIds: [id]); self.refreshUnread() } catch {
                if let j = self.index(of: id) { self.threads[j] = before }
            }
        }
    }

    /// The undo toast went away: its action is out of reach now.
    private func endUndoWindow() {
        undoTicket = nil
        coreActionsAfterTicket = 0
        flushPendingMarkRead()
    }

    /// `Z` / toast button: `undo_last`, but only while the toast's action is
    /// still the newest core action (W1).
    public func undo() {
        guard let client else { return }
        guard let ticket = undoTicket else {
            toasts.show(Strings.nothingToUndo)
            return
        }
        if coreActionsAfterTicket > 0 {
            // One of our own actions reached the core after the toast's action;
            // `undo_last` would hit that one instead.
            undoTicket = nil
            flushPendingMarkRead()
            toasts.show(Strings.undoGone)
            return
        }
        let deferred = takePendingMarkRead()
        undoTicket = nil
        toasts.dismiss()
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do {
                let undone = try await client.undoLast()
                await self.reloadKeepingPosition()
                let confirmed = undone && self.confirmUndone(ticket)
                if confirmed {
                    self.restoreLocally(ticket)
                    self.toasts.show(Strings.undone)
                } else if undone {
                    // `undo_last` took back a foreign action (MCP, a send); the
                    // ticket's action is still there (R-W1).
                    self.toasts.show(Strings.undoForeignAction)
                } else {
                    self.toasts.show(Strings.undoGone)
                }
                // Deferred reads go out after the undo (A2: B stays read).
                self.sendPending(deferred)
                self.refreshUnread()
            } catch {
                self.toasts.error(error)
                self.sendPending(deferred)
            }
        }
    }

    /// Did `undo_last` really restore the ticket's action? A foreign action
    /// (e.g. through the MCP server) can be the newest one instead.
    private func confirmUndone(_ ticket: UndoEntry) -> Bool {
        switch ticket.kind {
        case .removed:
            // Back in the list the user is looking at.
            return index(of: ticket.threadId) != nil
        case .star:
            guard let row = thread(ticket.threadId) else { return false }
            return row.isStarred == ticket.previous.isStarred
        case .readState:
            guard let row = thread(ticket.threadId) else { return false }
            return row.unreadCount == ticket.previous.unreadCount
        }
    }

    private func restoreLocally(_ ticket: UndoEntry) {
        autoSelectedAt = nil
        switch ticket.kind {
        case .removed:
            // N-P2a: selection and the open thread must not point at different
            // rows. While a thread is open — typically the neighbour that
            // opened when the archived thread was open — it keeps the
            // selection, and the restored thread only reappears in the list.
            // With nothing open the restored thread is selected (and opened
            // again if it was open before the action).
            if let open = expandedId {
                selectedId = open
            } else {
                selectedId = ticket.threadId
                if ticket.wasExpanded { expand(ticket.threadId) }
            }
            lastRemovedId = nil
            PerfLog.shared.write("undo_restored sel=\(selectedId ?? -1) open=\(expandedId ?? -1)")
        case .star:
            guard let i = index(of: ticket.threadId) else { return }
            threads[i].isStarred = ticket.previous.isStarred
        case .readState:
            guard let i = index(of: ticket.threadId) else { return }
            threads[i].unreadCount = ticket.previous.unreadCount
        }
    }

    // MARK: Search

    public func runSearch() {
        userNavigation = true
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { endSearch(); return }
        searchQuery = query
        expandedId = nil
        inlineCompose = nil
        threads = []
        Task { await reload() }
    }

    public func endSearch() {
        guard searchQuery != nil || !searchText.isEmpty else { return }
        searchText = ""
        if searchQuery != nil {
            searchQuery = nil
            resetAndReload()
        }
    }

    /// "Bilder laden" for every message of the open thread (button, menu, palette).
    public func loadImagesInExpanded() {
        guard let id = expandedId, let detail = details[id] else { return }
        for message in detail.messages { remoteImageOverride.insert(message.id) }
    }

    // MARK: Attachments

    public func openAttachment(_ attachment: AttachmentMeta) {
        guard let client else { return }
        Task { do { try await client.openAttachment(attachment.id) } catch { toasts.error(error) } }
    }

    public func saveAttachment(_ attachment: AttachmentMeta) {
        guard let client else { return }
        // The panel itself is the platform's business (`MacPlatformServices`);
        // the store only asks for a destination.
        Task { @MainActor in
            guard let path = await platform.chooseSaveLocation(
                suggestedName: attachment.filename ?? Strings.attachmentFallback
            ) else { return }
            do {
                try await client.saveAttachment(attachment.id, to: path)
                toasts.show("\(URL(fileURLWithPath: path).lastPathComponent) gespeichert")
            } catch { toasts.error(error) }
        }
    }
}
