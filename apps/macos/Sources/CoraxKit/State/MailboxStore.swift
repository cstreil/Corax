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
    /// M2.9: die Seitenleiste filtert die Liste auf ein Label oder einen Ordner
    /// (Tauri `selectLabel`/`selectFolder`). Beides schließt sich aus.
    public private(set) var filterLabelId: Int64?
    public private(set) var filterFolderId: Int64?
    /// Name des gefilterten Ordners (der Titel zeigt ihn, auch bevor die
    /// Ordnerliste geladen ist).
    public private(set) var filterFolderName: String?
    private(set) var tabID: String = "important"
    public private(set) var accountId: Int64?
    public private(set) var accounts: [Account] = []
    private(set) var splits: [SplitRule] = []
    public private(set) var labels: [Int64: Label] = [:]
    public private(set) var unread: UnreadCounts?
    /// Called whenever the counts were refreshed (M2.4: Dock badge).
    public var onUnreadCounts: (@MainActor (UnreadCounts) -> Void)?
    /// A mailbox, account, tab or search the user picked by hand (M2.8b): the
    /// calendar screen closes on it, so the choice is visible.
    public var onUserNavigation: (@MainActor () -> Void)?

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
    /// M2.5: the multi-selection (Tauri's `selection`). `selectedId` stays the
    /// cursor; every action runs on `targetIds` — the selection when it holds
    /// more than the cursor row, else the cursor.
    public private(set) var selectedIds: Set<Int64> = []
    /// Anchor of a ⇧-range (Tauri's `selectAnchorId`).
    public private(set) var selectAnchorId: Int64?
    /// IMAP folders of the account, for "Verschieben" (`V`).
    public private(set) var folders: [FolderInfo] = []

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
    /// M2.9: der Thread wird zugeklappt oder gewechselt und der Inline-Entwurf
    /// ist nicht leer. Statt ihn still wegzuwerfen, gibt die Liste ihn ab; die
    /// App macht daraus eine Leiste im Verfassen-Panel (§3.7).
    public var onInlineDraftAbandoned: ((ComposeDraft) -> Void)?
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
    private static let signposter = OSSignposter(subsystem: AppIdentity.bundleID, category: "ui")
    public private(set) var firstListMs: Int?

    public init(toasts: ToastCenter, settings: SettingsStore, writeAccess: WriteAccess,
                platform: any PlatformServices) {
        self.toasts = toasts
        self.settings = settings
        self.writeAccess = writeAccess
        self.platform = platform
    }

    /// The selected row closest to `index` (by list position), or nil.
    private func closestSelection(to index: Int?, in fresh: [ThreadSummary]) -> Int64? {
        guard let index, !selectedIds.isEmpty else { return nil }
        var best: (id: Int64, distance: Int)?
        for (i, thread) in fresh.enumerated() where selectedIds.contains(thread.id) {
            let distance = abs(i - index)
            if best == nil || distance < best!.distance { best = (thread.id, distance) }
        }
        return best?.id
    }

    // MARK: Derived

    public var title: String {
        if let query = searchQuery { return "Suche: \(query)" }
        if let id = filterLabelId, let label = labels[id] { return label.name }
        if filterFolderId != nil, let name = filterFolderName { return name }
        return Strings.view(view)
    }

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

    /// M2.9: der Zähler neben einer Ansicht in der Seitenleiste. Was der Kern
    /// nicht zählt (Gesendet, Erledigt, Papierkorb, Alle), bleibt ohne Zahl.
    public func badge(for view: MailView) -> Int64 {
        guard let unread else { return 0 }
        switch view {
        case .inbox: return unread.inbox
        case .starred: return unread.views["starred"] ?? 0
        case .snoozed: return unread.views["snoozed"] ?? 0
        case .drafts: return unread.views["drafts"] ?? 0
        case .spam: return unread.views["spam"] ?? 0
        case .sent, .done, .trash, .all: return 0
        }
    }

    /// Ungelesene eines Labels (der Kern zählt je Label-ID).
    public func labelBadge(_ id: Int64) -> Int64 { unread?.labels[String(id)] ?? 0 }

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

    public func refreshAccounts() async {
        guard let client else { return }
        if let list = try? await client.accounts() { accounts = list }
    }

    /// Settings → Konten: changes the display name (the address stays).
    @discardableResult
    public func renameAccount(_ id: Int64, to name: String) async -> Bool {
        guard let client else { return false }
        do {
            let updated = try await client.setAccountDisplayName(accountId: id, name: name)
            if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index] = updated }
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// Settings → Konten: removes the account from Corax — credentials, account
    /// row, local mail cache and attachments. The server mailbox is untouched.
    @discardableResult
    public func removeAccount(_ id: Int64) async -> Bool {
        guard let client else { return false }
        do {
            try await client.removeAccount(id)
            accounts.removeAll { $0.id == id }
            if accountId == id { setAccount(nil, byUser: false) }
            PerfLog.shared.write("account_removed id=\(id)")
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// `byUser: false` is for calls the app makes itself (restoring a view,
    /// clearing the account after it was removed); only a choice the user made
    /// closes the calendar screen.
    public func setView(_ newView: MailView, byUser: Bool = true) {
        // M2.8c: the calendar closes on *every* choice of a view, also when it
        // is the one that was set before the calendar opened (Inbox → Kalender
        // → Inbox). The unchanged-guard therefore comes after the callback.
        if byUser { onUserNavigation?() }
        // A label or folder filter belongs to the line it was picked on; picking
        // another view drops it (also when it is the view already set).
        if filterLabelId != nil || filterFolderId != nil {
            filterLabelId = nil
            filterFolderId = nil
            filterFolderName = nil
            view = newView
            searchQuery = nil
            searchText = ""
            tabID = tabs.first?.id ?? "important"
            resetAndReload()
            return
        }
        guard newView != view || searchQuery != nil else { return }
        view = newView
        searchQuery = nil
        searchText = ""
        tabID = tabs.first?.id ?? "important"
        resetAndReload()
    }

    public func setAccount(_ id: Int64?, byUser: Bool = true) {
        if byUser { onUserNavigation?() }
        guard id != accountId else { return }
        accountId = id
        filterLabelId = nil
        filterFolderId = nil
        filterFolderName = nil
        resetAndReload()
        refreshUnread()
    }

    /// M2.9: Seitenleiste → Label. Die Ansicht bleibt „Alle E-Mails", der Kern
    /// filtert über `label_id`; ein Ordnerfilter fällt dabei weg.
    public func selectLabel(_ id: Int64?) {
        guard filterLabelId != id || filterFolderId != nil || view != .all else { return }
        onUserNavigation?()
        filterLabelId = id
        filterFolderId = nil
        filterFolderName = nil
        view = .all
        searchQuery = nil
        searchText = ""
        expandedId = nil
        resetAndReload()
        PerfLog.shared.write("list_filter label=\(id.map(String.init) ?? "-")")
    }

    /// M2.9: Seitenleiste → Ordner (`folder_id`). Wie Tauri `selectFolder`.
    public func selectFolder(_ folder: FolderInfo) {
        guard filterFolderId != folder.id else { return }
        onUserNavigation?()
        filterFolderId = folder.id
        filterFolderName = folderName(folder)
        filterLabelId = nil
        view = .all
        searchQuery = nil
        searchText = ""
        expandedId = nil
        resetAndReload()
        PerfLog.shared.write("list_filter folder=\(folder.id)")
    }

    public func setTab(_ id: String) {
        // The tab is picked by hand only (MainView, ⌃Tab, palette); picking the
        // current tab while the calendar is open still leaves the calendar.
        onUserNavigation?()
        guard id != tabID || filterLabelId != nil || filterFolderId != nil else { return }
        tabID = id
        filterLabelId = nil
        filterFolderId = nil
        filterFolderName = nil
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
                let page = try await client.listThreads(view: view, splitId: currentSplitId, accountId: accountId,
                                                labelId: filterLabelId, folderId: filterFolderId,
                                                cursor: nil, limit: pageSize)
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
            selectedIds = selectedId.map { [$0] } ?? []
            selectAnchorId = selectedId
        } else {
            // M2.5: rows that left the list leave the selection too.
            let visible = Set(fresh.map(\.id))
            let oldCursor = selectedId
            selectedIds.formIntersection(visible)
            if let cursor = selectedId, !visible.contains(cursor) {
                // W3: the thread vanished (e.g. archived on another device). Keep
                // the selection the user chose: the closest surviving selected
                // row, else the neighbour at the old position.
                let survivor = closestSelection(to: oldIndex, in: fresh)
                let neighbour = survivor ?? oldIndex.flatMap { i in
                    fresh.indices.contains(i) ? fresh[i].id : fresh.last?.id
                }
                selectedId = neighbour
                if let neighbour { selectedIds.insert(neighbour) }
                selectAnchorId = neighbour
                // Only a change nobody asked for arms the "ignore the next
                // action" guard; after a view switch the user knows where it is.
                if neighbour != nil, !userNavigation, survivor == nil {
                    autoSelectedAt = CFAbsoluteTimeGetCurrent()
                }
            }
            // The cursor row stays selected, so every action key has a visible target.
            if let cursor = selectedId, selectedIds.isEmpty { selectedIds = [cursor] }
            if let anchor = selectAnchorId, !visible.contains(anchor) {
                selectAnchorId = selectedId
            }
            _ = oldCursor
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
                let page = try await client.listThreads(view: view, splitId: currentSplitId, accountId: accountId,
                                                labelId: filterLabelId, folderId: filterFolderId,
                                                cursor: cursor, limit: pageSize)
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
        Task {
            if let counts = try? await client.unreadCounts() {
                self.unread = counts
                self.onUnreadCounts?(counts)
            }
        }
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

    /// Reloads the current page and the counts (after `relabel_auto`, M2.5).
    public func refresh() {
        Task {
            await reloadKeepingPosition()
            refreshUnread()
        }
    }

    private func reloadKeepingPosition() async {
        guard let client, searchQuery == nil else { return }
        guard let page = try? await client.listThreads(view: view, splitId: currentSplitId, accountId: accountId,
                                         labelId: filterLabelId, folderId: filterFolderId,
                                         cursor: nil, limit: max(pageSize, threads.count)) else { return }
        applyThreads(page.threads, cursor: page.nextCursor)
    }

    // MARK: Selection and expansion

    /// A plain click or a jump: the cursor row is the whole selection again.
    public func select(_ id: Int64?) {
        selectedId = id
        selectedIds = id.map { [$0] } ?? []
        selectAnchorId = id
        autoSelectedAt = nil
    }

    /// The rows an action runs on, in list order: the multi-selection, else the
    /// cursor row. Tauri's `currentTargets`.
    public var targetIds: [Int64] {
        guard !selectedIds.isEmpty else { return selectedId.map { [$0] } ?? [] }
        var out: [Int64] = []
        out.reserveCapacity(selectedIds.count)
        for thread in threads where selectedIds.contains(thread.id) { out.append(thread.id) }
        if out.isEmpty, let id = selectedId { return [id] }
        return out
    }

    public var targetCount: Int { targetIds.count }

    /// A row is highlighted when it is selected or holds the cursor. The cursor
    /// is always visible, so no action key can hit a row the user does not see.
    public func isSelected(_ id: Int64) -> Bool { selectedIds.contains(id) || id == selectedId }

    /// `⌘A`: every loaded row, and back to the cursor row when everything is
    /// already selected (Tauri's toggle).
    public func selectAllVisible() {
        guard !threads.isEmpty else { return }
        autoSelectedAt = nil
        if selectedIds.count >= threads.count, selectedIds.isSuperset(of: threads.map(\.id)) {
            selectedIds = selectedId.map { [$0] } ?? []
            selectAnchorId = selectedId
            PerfLog.shared.write("select_all off sel=\(selectedIds.count)")
            return
        }
        selectedIds = Set(threads.map(\.id))
        selectAnchorId = selectedId ?? threads.first?.id
        PerfLog.shared.write("select_all on sel=\(selectedIds.count)")
    }

    /// `⌘`-click: adds or removes one row and makes it the anchor.
    public func toggleSelect(_ id: Int64) {
        autoSelectedAt = nil
        selectAnchorId = id
        if selectedIds.contains(id) {
            // The cursor never leaves the selection: it moves to the closest
            // remaining selected row, and the last selected row stays.
            if selectedId == id, let next = neighbourInSelection(of: id) { selectedId = next }
            selectedIds.remove(id)
            if selectedIds.isEmpty { selectedIds = [id] }
            if selectedId == id, let first = selectedIds.first, selectedId != first { selectedId = first }
        } else {
            selectedIds.insert(id)
            selectedId = id
        }
        PerfLog.shared.write("select_toggle id=\(id) sel=\(selectedIds.count)")
    }

    /// The selected row closest to `id` in the list (else nil).
    private func neighbourInSelection(of id: Int64) -> Int64? {
        guard let i = index(of: id) else { return nil }
        for offset in 1..<max(threads.count, 2) {
            if i - offset >= 0, selectedIds.contains(threads[i - offset].id), threads[i - offset].id != id {
                return threads[i - offset].id
            }
            if i + offset < threads.count, selectedIds.contains(threads[i + offset].id), threads[i + offset].id != id {
                return threads[i + offset].id
            }
            if i - offset < 0, i + offset >= threads.count { break }
        }
        return nil
    }

    /// `⇧`-click: the range from the anchor to `target`.
    public func selectRange(_ target: Int64, additive: Bool = true) {
        guard let ti = index(of: target) else {
            toggleSelect(target)
            return
        }
        autoSelectedAt = nil
        let anchorIndex = selectAnchorId.flatMap { index(of: $0) } ?? selectedId.flatMap { index(of: $0) } ?? ti
        let anchorId = threads[anchorIndex].id
        let range = min(anchorIndex, ti)...max(anchorIndex, ti)
        let ids = Set(range.map { threads[$0].id })
        selectedIds = additive ? selectedIds.union(ids) : ids
        selectedId = target
        selectAnchorId = anchorId
        PerfLog.shared.write("select_range anchor=\(anchorId) target=\(target) sel=\(selectedIds.count)")
    }

    /// `⇧↓`/`⇧↑`: moves the cursor and selects the range from the anchor.
    public func extendSelection(_ delta: Int) {
        guard !threads.isEmpty else { return }
        autoSelectedAt = nil
        let cursorIndex = selectedId.flatMap { index(of: $0) } ?? -1
        let base = cursorIndex < 0 ? 0 : cursorIndex
        let anchorIndex = selectAnchorId.flatMap { index(of: $0) } ?? base
        let next = max(0, min(threads.count - 1, base + delta))
        let range = min(anchorIndex, next)...max(anchorIndex, next)
        selectedIds = Set(range.map { threads[$0].id })
        selectedId = threads[next].id
        selectAnchorId = threads[anchorIndex].id
        if next >= threads.count - 60 { loadMoreIfNeeded() }
        PerfLog.shared.write("select_extend anchor=\(anchorIndex) next=\(next) sel=\(selectedIds.count)")
    }

    /// Back to a single selected row (after an action, after a jump).
    public func collapseSelection() {
        selectedIds = selectedId.map { [$0] } ?? []
        selectAnchorId = selectedId
    }

    public func step(_ delta: Int) {
        guard !threads.isEmpty else { return }
        autoSelectedAt = nil
        let current = selectedId.flatMap { index(of: $0) } ?? -1
        let next = max(0, min(threads.count - 1, current + delta))
        let id = threads[next].id
        selectedId = id
        selectedIds = [id]
        selectAnchorId = id
        if expandedId != nil, expandedId != id {
            expand(id)
        }
        if next >= threads.count - 60 { loadMoreIfNeeded() }
    }

    /// `Bild↓`/`Bild↑` in state A.
    public func pageList(_ direction: Int) {
        guard let id = navigator?.pageList(direction, selected: selectedId) else { return }
        autoSelectedAt = nil
        select(id)
        if let i = index(of: id), i >= threads.count - 60 { loadMoreIfNeeded() }
    }

    /// `Pos1`/`Ende` in state A; `Ende` loads every remaining page first.
    public func selectEdge(first: Bool) {
        autoSelectedAt = nil
        if first { select(threads.first?.id); return }
        guard nextCursor != nil, searchQuery == nil, let client else {
            select(threads.last?.id)
            return
        }
        let generation = listGeneration
        Task {
            while generation == listGeneration, let cursor = nextCursor {
                guard let page = try? await client.listThreads(view: view, splitId: currentSplitId, accountId: accountId,
                                                               labelId: filterLabelId, folderId: filterFolderId,
                                                               cursor: cursor, limit: 500) else { break }
                guard generation == listGeneration else { return }
                let known = Set(threads.map(\.id))
                appendingThreads += 1
                threads.append(contentsOf: page.threads.filter { !known.contains($0.id) })
                appendingThreads -= 1
                nextCursor = page.nextCursor
            }
            select(threads.last?.id)
        }
    }

    public func toggle(_ id: Int64? = nil) {
        guard let id = id ?? selectedId else { return }
        autoSelectedAt = nil
        select(id)
        if expandedId == id { collapse() } else { expand(id) }
    }

    public func collapse() {
        releaseInlineDraft()
        expandedId = nil
    }

    /// Ein Inline-Entwurf, der den Thread verlässt: leer = weg wie bisher,
    /// gefüllt = an das Panel abgeben (M2.9).
    private func releaseInlineDraft() {
        guard let draft = inlineCompose else { return }
        inlineCompose = nil
        guard !draft.isEmpty else { return }
        onInlineDraftAbandoned?(draft)
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
        releaseInlineDraft()
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

    // MARK: Actions (optimistic, `E # H S U Z`, M2.5 groups)

    /// A row a removing action took out, with the place it had.
    private struct RemovedRow { let thread: ThreadSummary; let index: Int }
    /// The thread the last removing action took out, to select it again after undo.
    private var lastRemovedId: Int64?

    // MARK: Undo ticket (W1) and deferred auto-mark-read

    /// The action the visible undo toast belongs to. While it stands, the
    /// automatic `mark_read` of an opened thread is only shown locally and sent
    /// when the toast goes away: `undo_last` undoes the *newest* core action
    /// (`db/repo/actions.rs: last_undoable`), so an early `mark_read` would
    /// swallow the undo.
    ///
    /// M2.5: one ticket covers the whole selection. The core undoes a *gesture*
    /// — same kind, created within 150 ms — and a group action sends its ids in
    /// one `perform_action`, so `undo_last` brings back exactly that group.
    private struct UndoEntry {
        enum Kind { case removed, star, readState, label }
        /// Tells two tickets apart, for the label window that has no toast to
        /// close it (W6).
        let token = UUID()
        let kind: Kind
        /// Every row the action touched, in list order.
        let threadIds: [Int64]
        /// The rows as they were before the action, to restore and to verify.
        let previous: [ThreadSummary]
        /// Only for `.removed`: the open thread was among them, undo opens it again.
        var wasExpanded = false
    }
    private var undoTicket: UndoEntry?
    /// Writes this UI sent after the ticket's own action; then `undo_last` would
    /// not hit the ticket's action any more (R2 c, own actions only).
    private var coreActionsAfterTicket = 0
    /// Auto `mark_read` held back while an undo toast stands.
    private var pendingMarkRead: [Int64: ThreadSummary] = [:]
    /// Ends the label undo window after 30 s (W6).
    private var labelExpiryTask: Task<Void, Never>?
    /// Serializes every write to the core, so a deferred `mark_read` can never
    /// land after the action it was meant to precede.
    private var writeChain: Task<Void, Never>?
    /// Selection that changed without the user (list update, W3).
    private var autoSelectedAt: CFAbsoluteTime?
    /// The next `apply` belongs to a view/tab/search switch the user asked for.
    private var userNavigation = false

    /// Tests: waits until every queued write has run (the chain keeps chaining).
    func waitForPendingWrites() async { await writeChain?.value }

    /// How long quitting waits for the deferred reads (N2). The host's own
    /// shutdown grace is 500 ms; this is the outer bound for the whole flush.
    static var terminationGrace: TimeInterval = 2

    /// N2 aus dem Audit M2: a label action holds `mark_read` back for up to
    /// 30 s (W6). Quitting inside that window would leave the opened mails
    /// unread on the server, so `applicationShouldTerminate` calls this and
    /// waits — at most `terminationGrace` — until the reads reached the core.
    public func flushBeforeTermination() async {
        labelExpiryTask?.cancel()
        labelExpiryTask = nil
        flushPendingMarkRead()
        guard let chain = writeChain else { return }
        // Race the chain against the deadline: `withTaskGroup` would wait for
        // the chain even after the timeout fired.
        let grace = Self.terminationGrace
        let done = AsyncStream<Void> { continuation in
            Task {
                await chain.value
                continuation.yield()
                continuation.finish()
            }
            Task {
                try? await Task.sleep(for: .seconds(grace))
                continuation.finish()
            }
        }
        for await _ in done { break }
    }

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

    // MARK: Targets of a group action

    /// The rows an explicitly targeted action hits (a toast action, a send-done),
    /// or the selection when no id is given.
    private func rows(for id: Int64?) -> [ThreadSummary] {
        if let id { return thread(id).map { [$0] } ?? [] }
        let ids = Set(targetIds)
        return threads.filter { ids.contains($0.id) }
    }

    /// The rows of a target list that was fixed earlier (W3: a dialog or a
    /// popover keeps the selection it was opened on). Rows that left the list
    /// meanwhile are simply not there, so nothing happens for them.
    private func rows(forIds ids: [Int64]) -> [ThreadSummary] {
        let wanted = Set(ids)
        return threads.filter { wanted.contains($0.id) }
    }

    /// "Archiviert" / "Archiviert (3)" — Tauri labels a group with its count.
    private func groupLabel(_ label: String, count: Int) -> String {
        count > 1 ? "\(label) (\(count))" : label
    }

    /// W7 aus dem Audit M2: above `GroupActionLimit.maxThreads` the core's
    /// 150 ms undo window no longer covers the whole gesture, so the action is
    /// refused before anything reaches the core — no partial run, no undo that
    /// silently brings back only part of the group.
    private func withinGroupLimit(_ hits: [ThreadSummary]) -> Bool {
        guard !GroupActionLimit.allows(hits.count) else { return true }
        PerfLog.shared.write("group_action_refused reason=limit n=\(hits.count) max=\(GroupActionLimit.maxThreads)")
        toasts.show(GroupActionLimit.message)
        return false
    }

    /// One toast with one undo for the whole group (`undo_last` reverts the
    /// gesture, see `UndoEntry`).
    private func showUndoToast(_ text: String) {
        toasts.show(text, actionTitle: Strings.undo,
                    action: { [weak self] in self?.undo() },
                    onClose: { [weak self] in self?.endUndoWindow() })
    }

    // MARK: Removing actions (archive, trash, snooze, spam, unarchive, move)

    public func archive(_ id: Int64? = nil) { removeGroup(.archive, label: Strings.archived, ids: id) }
    public func trash(_ id: Int64? = nil) { removeGroup(.trash, label: Strings.trashed, ids: id) }
    public func unarchive(_ id: Int64? = nil) {
        removeGroup(.unarchive, label: "Zurück in den Posteingang", ids: id)
    }
    /// `not_spam`: takes the selection out of the junk folder (spam view).
    public func notSpam(_ id: Int64? = nil) { removeGroup(.notSpam, label: "Kein Spam", ids: id) }

    /// In the spam view the same key takes a thread back out of it.
    public func spam(_ id: Int64? = nil) {
        if view == .spam { removeGroup(.notSpam, label: "Kein Spam", ids: id) }
        else { removeGroup(.spam, label: "Als Spam markiert", ids: id) }
    }
    public func snooze(_ id: Int64? = nil, until date: Date = Format.tomorrowMorning(),
                       label: String = Strings.snoozedUntilTomorrow) {
        removeGroup(.snooze, label: label, ids: id,
                    params: ActionParams(wakeAt: Int64(date.timeIntervalSince1970 * 1000)))
    }
    /// `V`: moves every target into `folder`; undo brings the group back.
    public func moveToFolder(_ folder: FolderInfo, ids: Int64? = nil, targets: [Int64]? = nil) {
        removeGroup(.move, label: "Verschoben nach \(folderName(folder))", ids: ids,
                    targets: targets, params: ActionParams(targetFolderId: folder.id))
    }

    /// The name Tauri shows: the IMAP name without the Gmail prefix.
    public func folderName(_ folder: FolderInfo) -> String { Pickers.folderName(folder) }

    /// `undo_last` knows archive, trash, snooze, spam and move — those get the
    /// undo toast. It does **not** know `unarchive` and `not_spam`; a toast with
    /// an undo button there would take back whatever action is the newest
    /// instead (W2 aus dem Audit M2). Those get a plain toast.
    private static func coreCanUndo(_ kind: ActionKind) -> Bool {
        switch kind {
        case .unarchive, .notSpam, .unsnooze: return false
        default: return true
        }
    }

    private func removeGroup(_ kind: ActionKind, label: String, ids: Int64? = nil,
                             targets: [Int64]? = nil, params: ActionParams? = nil) {
        guard let client else { return }
        let hits = targets.map { rows(forIds: $0) } ?? rows(for: ids)
        guard !hits.isEmpty, withinGroupLimit(hits) else { return }
        let removedIds = hits.map(\.id)
        let removedSet = Set(removedIds)
        let places = hits.compactMap { thread in index(of: thread.id).map { RemovedRow(thread: thread, index: $0) } }
        let firstIndex = places.map(\.index).min() ?? 0
        let wasExpanded = expandedId.map { removedSet.contains($0) } ?? false
        beginUserAction()
        if Self.coreCanUndo(kind) {
            undoTicket = UndoEntry(kind: .removed, threadIds: removedIds, previous: hits, wasExpanded: wasExpanded)
        }
        lastRemovedId = removedIds.first
        // Same frame: the rows go, the cursor moves to the row that slid up.
        threads.removeAll { removedSet.contains($0.id) }
        if wasExpanded { expandedId = nil; inlineCompose = nil }
        let next = threads.indices.contains(firstIndex) ? threads[firstIndex].id : threads.last?.id
        selectedId = next
        selectedIds = next.map { [$0] } ?? []
        selectAnchorId = next
        // M2.8c: "Automatisch weiter" decides whether the neighbour opens. Off
        // (Tauri: `autoAdvance === false`) the removal returns to the list and
        // the cursor stands on the neighbour, collapsed.
        if wasExpanded, settings.autoAdvance, let next { expand(next) }
        if Self.coreCanUndo(kind) {
            showUndoToast(groupLabel(label, count: removedIds.count))
        } else {
            toasts.show(groupLabel(label, count: removedIds.count))
        }
        PerfLog.shared.write("group_action kind=\(kind.rawValue) n=\(removedIds.count) ids=\(removedIds.map(String.init).joined(separator: ","))")
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.performAction(kind, threadIds: removedIds, params: params)
                self.refreshUnread()
            } catch {
                self.restore(places)
                self.toasts.error(error)
            }
        }
    }

    /// Puts rows the core refused back where they were (same order as before:
    /// the page is sorted by date, so the old index is right).
    private func restore(_ places: [RemovedRow]) {
        guard !places.isEmpty else { return }
        for place in places.sorted(by: { $0.index < $1.index }) where index(of: place.thread.id) == nil {
            threads.insert(place.thread, at: min(place.index, threads.count))
        }
        // Same rule as the undo path (N-P2a): an open thread keeps the selection.
        selectedId = expandedId ?? places.first?.thread.id
        if let id = selectedId, !selectedIds.isEmpty { selectedIds = [id] }
        selectAnchorId = selectedId
    }

    // MARK: Star and read state

    public func toggleStar(_ id: Int64? = nil) {
        guard let client else { return }
        let hits = rows(for: id)
        guard !hits.isEmpty, withinGroupLimit(hits) else { return }
        let makeStarred = !hits[0].isStarred
        let kind: ActionKind = makeStarred ? .star : .unstar
        let ids = Set(hits.map(\.id))
        beginUserAction()
        for i in threads.indices where ids.contains(threads[i].id) { threads[i].isStarred = makeStarred }
        undoTicket = UndoEntry(kind: .star, threadIds: hits.map(\.id), previous: hits)
        showUndoToast(groupLabel(makeStarred ? Strings.starred : Strings.unstarred, count: hits.count))
        PerfLog.shared.write("group_action kind=\(kind.rawValue) n=\(hits.count)")
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do { _ = try await client.performAction(kind, threadIds: hits.map(\.id)); self.refreshUnread() } catch {
                for row in hits { if let j = self.index(of: row.id) { self.threads[j].isStarred = row.isStarred } }
                self.toasts.error(error)
            }
        }
    }

    public func toggleUnread(_ id: Int64? = nil) {
        guard let client else { return }
        let hits = rows(for: id)
        guard !hits.isEmpty, withinGroupLimit(hits) else { return }
        // The first target decides the direction (Tauri's `toggleRead`).
        let makeUnread = !hits[0].isUnread
        let kind: ActionKind = makeUnread ? .markUnread : .markRead
        let ids = Set(hits.map(\.id))
        beginUserAction()
        for i in threads.indices where ids.contains(threads[i].id) {
            threads[i].unreadCount = makeUnread ? max(1, threads[i].messageCount > 0 ? 1 : 1) : 0
        }
        if makeUnread, let open = expandedId, ids.contains(open) { collapse() }
        undoTicket = UndoEntry(kind: .readState, threadIds: hits.map(\.id), previous: hits)
        showUndoToast(groupLabel(makeUnread ? Strings.markedUnread : Strings.markedRead, count: hits.count))
        PerfLog.shared.write("group_action kind=\(kind.rawValue) n=\(hits.count)")
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do { _ = try await client.performAction(kind, threadIds: hits.map(\.id)); self.refreshUnread() } catch {
                for row in hits { if let j = self.index(of: row.id) { self.threads[j].unreadCount = row.unreadCount } }
                self.toasts.error(error)
            }
        }
    }

    // MARK: Labels (`L`)

    /// `add_label`/`remove_label` for every target. No toast: the row's label
    /// chip is the feedback (as in Tauri); `Z` still takes the group back while
    /// it is the newest core action.
    public func setLabel(_ labelId: Int64, applied: Bool, targets: [Int64]? = nil) {
        guard let client else { return }
        let hits = targets.map { rows(forIds: $0) } ?? rows(for: nil)
        guard !hits.isEmpty, withinGroupLimit(hits) else { return }
        let kind: ActionKind = applied ? .addLabel : .removeLabel
        let ids = Set(hits.map(\.id))
        beginUserAction()
        for i in threads.indices where ids.contains(threads[i].id) {
            if applied, !threads[i].labels.contains(labelId) { threads[i].labels.append(labelId) }
            if !applied { threads[i].labels.removeAll { $0 == labelId } }
        }
        let ticket = UndoEntry(kind: .label, threadIds: hits.map(\.id), previous: hits)
        undoTicket = ticket
        scheduleLabelTicketExpiry(ticketToken: ticket.token)
        PerfLog.shared.write("group_action kind=\(kind.rawValue) label=\(labelId) n=\(hits.count)")
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.performAction(kind, threadIds: hits.map(\.id),
                                                   params: ActionParams(labelId: labelId))
            } catch {
                for row in hits { if let j = self.index(of: row.id) { self.threads[j].labels = row.labels } }
                self.toasts.error(error)
            }
        }
    }

    /// True when every target carries the label (the popover's checkmark).
    public func allTargetsHaveLabel(_ labelId: Int64, targets: [Int64]? = nil) -> Bool {
        let hits = targets.map { rows(forIds: $0) } ?? rows(for: nil)
        return !hits.isEmpty && hits.allSatisfy { $0.labels.contains(labelId) }
    }

    // MARK: Permanent delete (Papierkorb, no undo)

    /// `#` in the Papierkorb view: the confirmation dialog runs this with the
    /// target list it was opened on (W3 aus dem Audit M2). It never reads the
    /// live selection: a row that vanished while the dialog stood (sync, another
    /// device) would hand the neighbour into an irreversible delete.
    public func deletePermanently(ids: [Int64]) {
        guard let client else { return }
        let hits = rows(forIds: ids)
        guard !hits.isEmpty, withinGroupLimit(hits) else { return }
        let removedIds = hits.map(\.id)
        let removedSet = Set(removedIds)
        let places = hits.compactMap { thread in index(of: thread.id).map { RemovedRow(thread: thread, index: $0) } }
        let firstIndex = places.map(\.index).min() ?? 0
        beginUserAction()
        undoTicket = nil
        threads.removeAll { removedSet.contains($0.id) }
        if let open = expandedId, removedSet.contains(open) { expandedId = nil; inlineCompose = nil }
        let next = threads.indices.contains(firstIndex) ? threads[firstIndex].id : threads.last?.id
        selectedId = next
        selectedIds = next.map { [$0] } ?? []
        selectAnchorId = next
        toasts.show(groupLabel("Endgültig gelöscht", count: removedIds.count))
        PerfLog.shared.write("permanent_delete n=\(removedIds.count) ids=\(removedIds.map(String.init).joined(separator: ","))")
        enqueueWrite(countsAsOtherAction: false) { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.performAction(.deletePermanently, threadIds: removedIds)
                self.refreshUnread()
            } catch {
                self.restore(places)
                self.toasts.error(error)
            }
        }
    }

    // MARK: Folders and sync (M2.5)

    private func accountOfTargets() -> Int64? {
        if let accountId { return accountId }
        let ids = Set(targetIds)
        return threads.first { ids.contains($0.id) }?.accountId
    }

    /// Loads the IMAP folders of the accounts the current selection belongs to
    /// (for the move popover and the sidebar). Called when the popover opens and
    /// whenever the sidebar sees a new account list.
    public func loadFolders() async {
        guard let client else {
            PerfLog.shared.write("folders_skipped reason=no_client")
            return
        }
        var accounts = Set<Int64>()
        if let account = accountOfTargets() { accounts.insert(account) }
        if accounts.isEmpty { accounts.formUnion(self.accounts.map(\.id)) }
        guard !accounts.isEmpty else {
            PerfLog.shared.write("folders_skipped reason=no_accounts")
            return
        }
        var loaded: [FolderInfo] = []
        for account in accounts.sorted() {
            // M2.15 1.3: kein `try?` — ein fehlgeschlagenes `list_folders` sah
            // sonst wie „keine Ordner“ aus.
            do {
                loaded += try await client.listFolders(accountId: account)
            } catch {
                PerfLog.shared.write("folders_failed account=\(account) error=\(error)")
            }
        }
        folders = loaded.sorted { folderName($0).localizedCaseInsensitiveCompare(folderName($1)) == .orderedAscending }
        PerfLog.shared.write("folders_loaded n=\(folders.count) own=\(folders.filter { $0.role == nil }.count) "
                             + "accounts=\(accounts.count)")
    }

    /// "Jetzt synchronisieren" (`sync_now`).
    public func syncNow() {
        guard let client else { return }
        let account = accountOfTargets()
        toasts.show("Synchronisiere …")
        Task {
            do {
                try await client.syncNow(accountId: account)
                self.refreshUnread()
                PerfLog.shared.write("sync_now account=\(account ?? -1)")
            } catch { self.toasts.error(error) }
        }
    }

    // MARK: Auto mark-read

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

    /// How long a label action stays undoable without a toast (the core's
    /// `undo_last` window). Tests shorten it.
    static var labelUndoWindow: TimeInterval = 30

    /// W6 aus dem Audit M2: a label action shows no toast, so nothing closes its
    /// undo window — and `mark_read` stays local for as long as a ticket stands.
    /// The window is the core's 30 s; then the deferred reads go out.
    private func scheduleLabelTicketExpiry(ticketToken: UUID) {
        labelExpiryTask?.cancel()
        let seconds = Self.labelUndoWindow
        labelExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.undoTicket?.token == ticketToken else { return }
            self.endUndoWindow()
            PerfLog.shared.write("label_undo_window expired")
        }
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
                    PerfLog.shared.write("undo_group n=\(ticket.threadIds.count) ok=1")
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
            // Every row of the group is back in the list the user is looking at.
            return ticket.threadIds.allSatisfy { index(of: $0) != nil }
        case .star:
            return ticket.previous.allSatisfy { row in
                thread(row.id).map { $0.isStarred == row.isStarred } ?? false
            }
        case .readState:
            return ticket.previous.allSatisfy { row in
                thread(row.id).map { $0.unreadCount == row.unreadCount } ?? false
            }
        case .label:
            return ticket.previous.allSatisfy { row in
                thread(row.id).map { Set($0.labels) == Set(row.labels) } ?? false
            }
        }
    }

    private func restoreLocally(_ ticket: UndoEntry) {
        autoSelectedAt = nil
        switch ticket.kind {
        case .removed:
            // N-P2a: selection and the open thread must not point at different
            // rows. While a thread is open — typically the neighbour that
            // opened when the archived thread was open — it keeps the
            // selection, and the restored rows only reappear in the list.
            // With nothing open the first restored thread is selected.
            let restored = ticket.threadIds.first { index(of: $0) != nil }
            if let open = expandedId {
                selectedId = open
            } else {
                selectedId = restored
                if ticket.wasExpanded, let restored { expand(restored) }
            }
            selectedIds = selectedId.map { [$0] } ?? []
            selectAnchorId = selectedId
            lastRemovedId = nil
            PerfLog.shared.write("undo_restored sel=\(selectedId ?? -1) open=\(expandedId ?? -1) n=\(ticket.threadIds.count)")
        case .star:
            for row in ticket.previous { if let i = index(of: row.id) { threads[i].isStarred = row.isStarred } }
        case .readState:
            for row in ticket.previous { if let i = index(of: row.id) { threads[i].unreadCount = row.unreadCount } }
        case .label:
            for row in ticket.previous { if let i = index(of: row.id) { threads[i].labels = row.labels } }
        }
    }

    // MARK: Search

    public func runSearch() {
        userNavigation = true
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { endSearch(); return }
        onUserNavigation?()
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

    /// M2.5: Quick Look needs a file on disk. The core extracts the attachment
    /// into `directory/<id>/<name>` through `save_attachment` (the audited read
    /// path); the folder is removed when the app quits.
    public func stageAttachment(_ attachment: AttachmentMeta, into directory: URL) async -> URL? {
        guard let client else { return nil }
        let name = (attachment.filename?.isEmpty == false ? attachment.filename! : "Anhang")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let folder = directory.appendingPathComponent(String(attachment.id), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(name, isDirectory: false)
            try await client.saveAttachment(attachment.id, to: target.path)
            return FileManager.default.fileExists(atPath: target.path) ? target : nil
        } catch {
            PerfLog.shared.write("attachment_stage_failed id=\(attachment.id)")
            return nil
        }
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
