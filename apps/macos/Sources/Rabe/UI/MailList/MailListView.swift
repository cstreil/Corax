import AppKit
import RabeKit
import SwiftUI
import os

/// The table: single-key shortcuts go to the dispatcher, everything else to AppKit.
final class MailTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onHover: ((Int) -> Void)?
    /// M2.5: the right-click menu; the coordinator builds it for the row under
    /// the pointer (and makes that row the target when it is not in the selection).
    var onMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, row < numberOfRows else { return nil }
        return onMenu?(row)
    }
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { onHover?(-1) }

    // The detail row hosts SwiftUI; let it handle its own clicks.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

/// Clips the detail row so the card reveals itself while the row grows.
final class DetailCellView: NSView {
    let hosting: NSHostingView<AnyView>
    /// Set from SwiftUI's geometry callback, i.e. while the hosting view lays
    /// out; AppKit can drop a `needsLayout` set then (first expand after launch
    /// rendered only the estimated height). So the frame is applied directly,
    /// on the next turn of the run loop.
    var contentHeight: CGFloat = 0 {
        didSet {
            guard oldValue != contentHeight else { return }
            DispatchQueue.main.async { [weak self] in self?.applyFrame() }
        }
    }

    init(root: AnyView) {
        hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true
        addSubview(hosting)
    }

    private func applyFrame() {
        let frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(contentHeight, 1))
        if hosting.frame != frame { hosting.frame = frame }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Content keeps its full height; the row (this view) clips it.
        applyFrame()
    }
}

/// `NSViewRepresentable` around the list (ARCHITEKTUR E3).
struct MailListView: NSViewRepresentable {
    let rows: [ListRow]
    let selectedId: Int64?
    /// M2.5: the multi-selection; the cursor row is always part of it.
    let selectedIds: Set<Int64>
    let expandedId: Int64?
    let theme: Theme
    /// Changes when a visible thread's content changed (flags, snippet).
    let contentStamp: Int
    /// Changes when the list should take keyboard focus again.
    let focusStamp: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = MailTableView()
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.style = .plain
        table.gridStyleMask = []
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("E-Mails")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 24, right: 0)
        scroll.automaticallyAdjustsContentInsets = false

        let c = context.coordinator
        c.table = table
        c.scroll = scroll
        AppModel.shared.mailbox.navigator = c
        table.delegate = c
        table.dataSource = c
        table.onKey = { event in ActionDispatcher.handleListKey(event) }
        table.onHover = { [weak c] row in c?.setHover(row) }
        table.onMenu = { [weak c] row in c?.contextMenu(row: row) }
        table.target = c
        table.action = #selector(Coordinator.clicked(_:))
        c.apply(self, animated: false)
        DispatchQueue.main.async { table.window?.makeFirstResponder(table) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let t0 = CACurrentMediaTime()
        context.coordinator.apply(self, animated: true)
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 8 { PerfLog.shared.write("slow_list_update ms=\(Int(ms)) rows=\(rows.count)") }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, ListNavigating {
        weak var table: MailTableView?
        weak var scroll: NSScrollView?
        private var rows: [ListRow] = []
        private var selectedId: Int64?
        private var selectedIds: Set<Int64> = []
        private var expandedId: Int64?
        private var theme: Theme = .paper
        private var stamp = -1
        private var focusStamp = 0
        private var hoverRow = -1
        /// Row heights of detail rows (animated), and the content height they grow to.
        private var detailHeights: [Int64: CGFloat] = [:]
        private var detailContent: [Int64: CGFloat] = [:]
        private var detailViews: [Int64: DetailCellView] = [:]
        /// Detail rows on their way out (collapse animation running).
        private var closing: Set<Int64> = []
        private static let signposter = OSSignposter(subsystem: "de.streil.rabe.native", category: "ui")

        // MARK: Reconcile

        func apply(_ view: MailListView, animated: Bool) {
            guard let table else { return }
            // M2.4: a sender picture that arrived while the list is up repaints
            // the visible rows (the avatar cache is not part of the view state).
            AppModel.shared.avatars.onChange = { [weak self] in self?.refreshVisible() }
            if view.focusStamp != focusStamp {
                focusStamp = view.focusStamp
                DispatchQueue.main.async { table.window?.makeFirstResponder(table) }
            }
            let themeChanged = view.theme != theme
            theme = view.theme
            let oldSelected = selectedId
            let oldSelectedIds = selectedIds
            selectedId = view.selectedId
            selectedIds = view.selectedIds
            let oldExpanded = expandedId
            expandedId = view.expandedId

            // Paging fast path: same rows plus new ones at the end; only insertRows.
            if oldExpanded == expandedId, closing.isEmpty, !rows.isEmpty, view.rows.count > rows.count,
               !themeChanged, view.rows[rows.count - 1] == rows[rows.count - 1],
               view.rows[..<rows.count].elementsEqual(rows) {
                let t0 = CACurrentMediaTime()
                let range = rows.count..<view.rows.count
                rows = view.rows
                stamp = view.contentStamp
                table.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
                PerfLog.shared.write(String(format: "page_insert rows=%d added=%d ms=%.2f", rows.count, range.count,
                                            (CACurrentMediaTime() - t0) * 1000))
                if oldSelected != selectedId || oldSelectedIds != selectedIds {
                    refreshRows(for: Array(oldSelectedIds.union(selectedIds)) + [oldSelected, selectedId].compactMap { $0 })
                }
                return
            }

            if let old = oldExpanded, old != expandedId, rows.contains(.detail(old)),
               view.rows.contains(.thread(old)), animated, !Motion.reduce {
                closing.insert(old)
            }

            // Keep collapsing detail rows in place until their animation ends.
            var target = view.rows
            for id in closing where !target.contains(.detail(id)) {
                if let i = target.firstIndex(of: .thread(id)) { target.insert(.detail(id), at: i + 1) }
            }

            if target != rows {
                // At the very top, new mail must not push the list out of view.
                let wasAtTop = (scroll?.contentView.bounds.origin.y ?? 0) <= -(scroll?.contentInsets.top ?? 0) + 1
                defer {
                    if wasAtTop, let scroll {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
                if !rows.isEmpty, target.count > rows.count, target.starts(with: rows) {
                    // Paging: rows only appended at the end.
                    let range = rows.count..<target.count
                    rows = target
                    table.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
                } else if let diff = Optional(target.difference(from: rows)), !animated || diff.count > 60 || rows.isEmpty {
                    rows = target
                    table.reloadData()
                } else {
                    let diff = target.difference(from: rows)
                    table.beginUpdates()
                    for change in diff.removals.reversed() {
                        if case .remove(let offset, _, _) = change {
                            table.removeRows(at: IndexSet(integer: offset), withAnimation: Motion.reduce ? [] : [.effectFade])
                        }
                    }
                    rows = target
                    for change in diff.insertions {
                        if case .insert(let offset, let element, _) = change {
                            let animation: NSTableView.AnimationOptions = (Motion.reduce || element.threadID == nil) ? [] : (isDetail(element) ? [] : [.effectFade])
                            table.insertRows(at: IndexSet(integer: offset), withAnimation: animation)
                        }
                    }
                    table.endUpdates()
                }
            }

            if oldExpanded != expandedId {
                if let old = oldExpanded, old != expandedId { collapseDetail(old) }
                if let new = expandedId { expandDetail(new) }
                refreshCardRows([oldExpanded, expandedId].compactMap { $0 })
            }
            if themeChanged || view.contentStamp != stamp {
                stamp = view.contentStamp
                refreshVisible()
            } else if oldSelected != selectedId || oldSelectedIds != selectedIds {
                var touched = Array(oldSelectedIds.union(selectedIds))
                touched.append(contentsOf: [oldSelected, selectedId].compactMap { $0 })
                refreshRows(for: touched)
            }
            if oldSelected != selectedId, let id = selectedId, let row = rows.firstIndex(of: .thread(id)) {
                if expandedId != id { table.scrollRowToVisible(row) }
            }
        }

        private func isDetail(_ row: ListRow) -> Bool { if case .detail = row { true } else { false } }

        // MARK: Expand / collapse (noteHeightOfRows inside NSAnimationContext)

        private func expandDetail(_ id: Int64) {
            closing.remove(id)
            if detailHeights[id] == nil { detailHeights[id] = 1 }
            let estimate = detailContent[id] ?? 220
            detailContent[id] = estimate
            // The detail row was just inserted at 1 pt in this update; growing it
            // in the same pass jumps to the end height. Start on the next turn,
            // when the row exists at 1 pt, and scroll in the same animation.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.expandedId == id else { return }
                self.animateHeight(id, to: self.detailContent[id] ?? estimate, scrollToFit: true)
            }
        }

        private func collapseDetail(_ id: Int64) {
            guard rows.contains(.detail(id)) else {
                detailHeights[id] = nil
                detailViews[id] = nil
                return
            }
            closing.insert(id)
            animateHeight(id, to: 1) { [weak self] in
                guard let self, self.closing.contains(id), let table = self.table else { return }
                self.closing.remove(id)
                if let row = self.rows.firstIndex(of: .detail(id)) {
                    self.rows.remove(at: row)
                    table.removeRows(at: IndexSet(integer: row), withAnimation: [])
                }
                self.detailHeights[id] = nil
                self.detailViews[id] = nil
            }
        }

        /// Called by the SwiftUI content when its natural height changes
        /// (body loaded, HTML measured, reply field opened).
        func contentHeightChanged(_ id: Int64, _ height: CGFloat) {
            let h = ceil(height) + RowMetrics.openBottom
            guard abs((detailContent[id] ?? 0) - h) > 0.5 else { return }
            detailContent[id] = h
            detailViews[id]?.contentHeight = h
            guard expandedId == id, !closing.contains(id) else { return }
            animateHeight(id, to: h)
        }

        /// Row height (and, when opening, the scroll offset) driven frame by
        /// frame with the mockup curve. `noteHeightOfRows` inside an implicit
        /// AppKit animation only animated sometimes (first open yes, second
        /// jumped) and let the content spill over the following rows while
        /// closing; setting the real height each frame keeps the clip exact.
        private struct HeightAnimation {
            var from: CGFloat, to: CGFloat, start: CFTimeInterval
            var scrollFrom: CGFloat?, scrollTo: CGFloat?
            var completion: (@MainActor @Sendable () -> Void)?
        }
        private var heightAnimations: [Int64: HeightAnimation] = [:]
        private var displayLink: CADisplayLink?

        private func animateHeight(_ id: Int64, to height: CGFloat, scrollToFit: Bool = false,
                                   completion: (@MainActor @Sendable () -> Void)? = nil) {
            guard let table, rows.contains(.detail(id)) else { completion?(); return }
            let current = detailHeights[id] ?? 1
            let target = scrollToFit ? fitOrigin(id, detailHeight: height) : nil
            if Motion.reduce || abs(current - height) < 0.5 {
                detailHeights[id] = height
                noteHeight(id)
                if let target, let scroll { scroll.contentView.scroll(to: target); scroll.reflectScrolledClipView(scroll.contentView) }
                heightAnimations[id]?.completion?()
                heightAnimations[id] = nil
                completion?()
                return
            }
            let previous = heightAnimations[id]
            heightAnimations[id] = HeightAnimation(
                from: current, to: height, start: CACurrentMediaTime(),
                scrollFrom: target != nil ? scroll?.contentView.bounds.origin.y : previous?.scrollFrom,
                scrollTo: target?.y ?? previous?.scrollTo,
                completion: completion ?? previous?.completion)
            if displayLink == nil {
                let link = table.displayLink(target: self, selector: #selector(stepAnimations(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        }

        @objc private func stepAnimations(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            var finished: [(@MainActor @Sendable () -> Void)] = []
            for (id, anim) in heightAnimations {
                let t = min(1, (now - anim.start) / Motion.duration)
                let e = CGFloat(Motion.ease(t))
                detailHeights[id] = anim.from + (anim.to - anim.from) * e
                noteHeight(id)
                if let from = anim.scrollFrom, let to = anim.scrollTo, let scroll {
                    let maxY = max(-scroll.contentInsets.top, (table?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, from + (to - from) * e)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                if t >= 1 {
                    heightAnimations[id] = nil
                    if let c = anim.completion { finished.append(c) }
                }
            }
            if heightAnimations.isEmpty { displayLink?.invalidate(); displayLink = nil }
            finished.forEach { $0() }
        }

        private func noteHeight(_ id: Int64) {
            guard let table, let row = rows.firstIndex(of: .detail(id)) else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
        }

        /// Mockup: the opened row stays where it is; if the card will not fit,
        /// the list scrolls in the same animation (not afterwards).
        private func fitOrigin(_ id: Int64, detailHeight: CGFloat) -> NSPoint? {
            guard let table, let scroll, let row = rows.firstIndex(of: .thread(id)) else { return nil }
            let rowRect = table.rect(ofRow: row)
            let visible = scroll.contentView.documentVisibleRect
            let cardMaxY = rowRect.maxY + detailHeight
            guard cardMaxY > visible.maxY - 8 || rowRect.minY < visible.minY else { return nil }
            let contentHeight = table.bounds.height + detailHeight
            let y = max(-scroll.contentInsets.top, min(rowRect.minY - 4, contentHeight - visible.height))
            return NSPoint(x: 0, y: y)
        }

        // MARK: Keyboard navigation (TASTATUR.md)

        /// Visible document area below the toolbar inset.
        private var effectiveVisible: NSRect? {
            guard let scroll else { return nil }
            var r = scroll.contentView.bounds
            r.origin.y += scroll.contentInsets.top
            r.size.height -= scroll.contentInsets.top
            return r
        }

        func visibleDetailRange(_ id: Int64) -> ClosedRange<CGFloat>? {
            guard let table, let visible = effectiveVisible, let row = rows.firstIndex(of: .detail(id)) else { return nil }
            let top = table.rect(ofRow: row).minY
            return (visible.minY - top)...(visible.maxY - top)
        }

        func scrollDetail(_ id: Int64, toTop y: CGFloat) {
            guard let table, let row = rows.firstIndex(of: .detail(id)) else { return }
            scrollTo(table.rect(ofRow: row).minY + y)
        }

        func scrollList(by dy: CGFloat) {
            guard let visible = effectiveVisible else { return }
            scrollTo(visible.minY + dy)
        }

        /// `y` = document coordinate that should sit at the top of the visible area.
        private func scrollTo(_ y: CGFloat) {
            guard let table, let scroll else { return }
            let inset = scroll.contentInsets.top
            let maxOrigin = max(-inset, table.bounds.height + scroll.contentInsets.bottom - scroll.contentView.bounds.height)
            let origin = NSPoint(x: 0, y: max(-inset, min(maxOrigin, y - inset)))
            if Motion.reduce {
                scroll.contentView.scroll(to: origin)
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = Motion.timing
                    scroll.contentView.animator().setBoundsOrigin(origin)
                }
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func pageList(_ direction: Int, selected: Int64?) -> Int64? {
            guard let table, let visible = effectiveVisible else { return nil }
            let page = max(RowMetrics.threadHeight, visible.height - RowMetrics.threadHeight)
            // Window offset of the selection, else the first/last visible thread.
            var offset: CGFloat
            if let selected, let row = rows.firstIndex(of: .thread(selected)) {
                let r = table.rect(ofRow: row)
                offset = r.midY - visible.minY
                if offset < 0 || offset > visible.height { offset = direction > 0 ? RowMetrics.threadHeight / 2 : visible.height - RowMetrics.threadHeight / 2 }
            } else {
                offset = direction > 0 ? RowMetrics.threadHeight / 2 : visible.height - RowMetrics.threadHeight / 2
            }
            let newTop = max(0, min(table.bounds.height - visible.height, visible.minY + CGFloat(direction) * page))
            let scrolledTop = direction > 0 ? max(newTop, visible.minY) : min(newTop, visible.minY)
            if abs(scrolledTop - visible.minY) < 1 {
                // Nothing left to scroll: last (first) visible thread.
                offset = direction > 0 ? min(visible.height, table.bounds.height - visible.minY) - RowMetrics.threadHeight / 2
                                       : RowMetrics.threadHeight / 2
            }
            scrollTo(scrolledTop)
            // Thread at the same window position (skip headers/detail rows).
            var row = table.row(at: NSPoint(x: 1, y: scrolledTop + offset))
            if row < 0 { row = direction > 0 ? rows.count - 1 : 0 }
            var i = row
            while i >= 0, i < rows.count {
                if case .thread(let id) = rows[i] { return id }
                i += direction > 0 ? -1 : 1
                if i < 0 || i >= rows.count { break }
            }
            return rows.lazy.compactMap { if case .thread(let id) = $0 { id } else { nil } }.first
        }

        // MARK: Refresh

        private func refreshVisible() {
            guard let table else { return }
            let range = table.rows(in: table.visibleRect)
            for row in range.location..<(range.location + range.length) { configure(row: row) }
        }

        private func refreshRows(for ids: [Int64]) {
            for id in ids { if let row = rows.firstIndex(of: .thread(id)) { configure(row: row) } }
        }

        private func refreshCardRows(_ ids: [Int64]) {
            guard let table else { return }
            var set = IndexSet()
            for id in ids { if let r = rows.firstIndex(of: .thread(id)) { set.insert(r) } }
            if !set.isEmpty {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.effectiveDuration
                    ctx.timingFunction = Motion.timing
                    table.noteHeightOfRows(withIndexesChanged: set)
                }
            }
            for id in ids { refreshRows(for: [id]) }
        }

        private func configure(row: Int) {
            guard let table, row >= 0, row < rows.count else { return }
            if let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? MailRowView { style(rowView, row: row) }
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
                fill(cell, row: row)
            }
        }

        func setHover(_ row: Int) {
            guard row != hoverRow else { return }
            let old = hoverRow
            hoverRow = row
            configure(row: old)
            configure(row: row)
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rows[row] {
            case .header: return RowMetrics.headerHeight
            case .thread(let id): return id == expandedId ? RowMetrics.threadHeight + RowMetrics.openTop : RowMetrics.threadHeight
            case .detail(let id): return max(1, detailHeights[id] ?? 1)
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = (tableView.makeView(withIdentifier: .init("row"), owner: nil) as? MailRowView) ?? {
                let v = MailRowView()
                v.identifier = .init("row")
                return v
            }()
            style(view, row: row)
            return view
        }

        private func style(_ view: MailRowView, row: Int) {
            view.theme = theme
            switch rows[row] {
            case .thread(let id):
                view.cardPart = id == expandedId ? .top : .none
                // M2.5: every selected row carries the highlight; the cursor row
                // always does, so the action target is never invisible.
                view.isSelectedThread = (selectedIds.contains(id) || id == selectedId) && id != expandedId
                view.isHovered = row == hoverRow && id != expandedId
            case .detail:
                view.cardPart = .bottom
                view.isSelectedThread = false
                view.isHovered = false
            case .header:
                view.cardPart = .none
                view.isSelectedThread = false
                view.isHovered = false
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = rows[row]
            if case .thread = item, row > rows.count - 60 { AppModel.shared.mailbox.loadMoreIfNeeded() }
            switch item {
            case .header:
                let v = (tableView.makeView(withIdentifier: .init("header"), owner: nil) as? HeaderCellView) ?? {
                    let v = HeaderCellView(); v.identifier = .init("header"); return v
                }()
                fill(v, row: row)
                return v
            case .thread:
                let v = (tableView.makeView(withIdentifier: .init("thread"), owner: nil) as? ThreadCellView) ?? {
                    let v = ThreadCellView(); v.identifier = .init("thread"); return v
                }()
                fill(v, row: row)
                return v
            case .detail(let id):
                if let existing = detailViews[id] { return existing }
                let root = AnyView(
                    ThreadDetailView(threadId: id, onHeight: { [weak self] h in self?.contentHeightChanged(id, h) })
                        .environment(\.theme, theme)
                )
                let v = DetailCellView(root: root)
                v.contentHeight = detailContent[id] ?? 220
                detailViews[id] = v
                return v
            }
        }

        private func fill(_ view: NSView, row: Int) {
            switch rows[row] {
            case .header(_, let label):
                guard let v = view as? HeaderCellView else { return }
                v.theme = theme
                v.label = label
            case .thread(let id):
                guard let v = view as? ThreadCellView else { return }
                let box = AppModel.shared.mailbox
                v.theme = theme
                v.isOpen = id == expandedId
                v.thread = box.thread(id)
                if let labelId = box.thread(id)?.labels.first(where: { box.labels[$0]?.isAuto != true }), let label = box.labels[labelId] {
                    v.labelInfo = (label.name, NSColor(hex: label.color) ?? theme.ink3.ns)
                } else {
                    v.labelInfo = nil
                }
                v.showActions = (row == hoverRow || selectedIds.contains(id) || id == selectedId) && id != expandedId
            case .detail(let id):
                if let v = view as? DetailCellView {
                    v.hosting.rootView = AnyView(
                        ThreadDetailView(threadId: id, onHeight: { [weak self] h in self?.contentHeightChanged(id, h) })
                            .environment(\.theme, theme)
                    )
                }
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        @objc func clicked(_ sender: Any?) {
            guard let table else { return }
            let row = table.clickedRow
            guard row >= 0, row < rows.count, case .thread(let id) = rows[row] else { return }
            table.window?.makeFirstResponder(table)
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            let box = AppModel.shared.mailbox
            // M2.5: ⇧ picks a range, ⌘ toggles one row, a plain click opens.
            if flags.contains(.shift) {
                box.selectRange(id, additive: true)
                return
            }
            if flags.contains(.command) {
                box.toggleSelect(id)
                return
            }
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadCellView,
               let event = NSApp.currentEvent,
               let action = cell.action(at: cell.convert(event.locationInWindow, from: nil)) {
                box.select(id)
                ActionDispatcher.perform(action)
                return
            }
            box.toggle(id)
        }

        /// The right-click menu for `row`; a row outside the selection becomes
        /// the target, a row inside it keeps the whole selection (Tauri).
        func contextMenu(row: Int) -> NSMenu? {
            guard let table, row >= 0, row < rows.count, case .thread(let id) = rows[row] else { return nil }
            table.window?.makeFirstResponder(table)
            let box = AppModel.shared.mailbox
            if !box.selectedIds.contains(id) || box.selectedIds.count == 1 {
                box.select(id)
            }
            PerfLog.shared.write("context_menu row=\(row) targets=\(box.targetIds.count)")
            return ThreadContextMenu.build(forThreads: box.targetIds, view: box.view)
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
