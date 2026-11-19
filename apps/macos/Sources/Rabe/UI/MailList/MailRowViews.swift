import AppKit
import RabeKit

/// Geometry from the mockup (`.row`, `.head`, `.grp h3`, `.row.open`).
enum RowMetrics {
    static let threadHeight: CGFloat = 42
    static let headerHeight: CGFloat = 32
    static let sideInset: CGFloat = 10          // .row margin 0 10px
    static let openSideInset: CGFloat = 14      // .row.open margin 8px 14px 14px
    static let openTop: CGFloat = 8
    static let openBottom: CGFloat = 14
    static let radius: CGFloat = 10
}

/// Row background: hover, selection (accent bar + tint) and the open card.
final class MailRowView: NSTableRowView {
    var theme: Theme = .paper { didSet { needsDisplay = true } }
    var isSelectedThread = false { didSet { if oldValue != isSelectedThread { needsDisplay = true } } }
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    var cardPart: CardPart = .none { didSet { if oldValue != cardPart { needsDisplay = true } } }

    enum CardPart { case none, top, bottom }

    override var isOpaque: Bool { false }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {
        switch cardPart {
        case .top:
            let rect = NSRect(x: RowMetrics.openSideInset, y: RowMetrics.openTop,
                              width: bounds.width - 2 * RowMetrics.openSideInset, height: bounds.height - RowMetrics.openTop)
            let path = NSBezierPath.topRounded(rect, radius: RowMetrics.radius, flipped: isFlipped)
            theme.surface.ns.setFill()
            path.fill()
            theme.line.ns.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        case .bottom:
            let rect = NSRect(x: RowMetrics.openSideInset, y: 0,
                              width: bounds.width - 2 * RowMetrics.openSideInset, height: max(0, bounds.height - RowMetrics.openBottom))
            let path = NSBezierPath.bottomRounded(rect, radius: RowMetrics.radius, flipped: isFlipped)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(theme.isDark ? 0.45 : 0.12)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.set()
            theme.surface.ns.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            theme.line.ns.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        case .none:
            guard isSelectedThread || isHovered else { return }
            let rect = bounds.insetBy(dx: RowMetrics.sideInset, dy: 0)
            let path = NSBezierPath(roundedRect: rect, xRadius: RowMetrics.radius, yRadius: RowMetrics.radius)
            (isSelectedThread ? theme.sel : theme.hover).ns.setFill()
            path.fill()
            if isSelectedThread {
                // `.row.sel::before`: 3 px accent bar at the left edge.
                let bar = NSRect(x: 0, y: (bounds.height - 24) / 2, width: 3, height: 24)
                theme.accent.ns.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
}

/// Date group header: uppercase, 11 pt semibold, `--ink3`, indented to the text column.
final class HeaderCellView: NSView {
    var label = "" { didSet { needsDisplay = true } }
    var theme: Theme = .paper { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.ink3.ns, .kern: 0.66]
        let text = NSAttributedString(string: label.uppercased(with: Format.locale), attributes: attributes)
        text.draw(at: NSPoint(x: 76, y: bounds.height - 6 - font.ascender + font.descender - 1))
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { label }
    override func isAccessibilityElement() -> Bool { true }
}

/// One thread row, drawn directly (no subviews): dot, avatar, sender, subject,
/// preview, tag, attachment/star, date; hover/selection actions on the right.
final class ThreadCellView: NSView {
    var thread: ThreadSummary? { didSet { needsDisplay = true } }
    var labelInfo: (name: String, color: NSColor)? { didSet { needsDisplay = true } }
    var theme: Theme = .paper { didSet { needsDisplay = true } }
    var isOpen = false { didSet { needsDisplay = true } }
    var showActions = false { didSet { if oldValue != showActions { needsDisplay = true } } }
    var onAction: ((AppAction) -> Void)?

    override var isFlipped: Bool { true }
    private var actionRects: [(AppAction, NSRect)] = []

    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
    }
    private static let archiveImage = symbol("archivebox")
    private static let clockImage = symbol("clock")
    private static let starImage = symbol("star")
    private static let starFill = symbol("star.fill")
    private static let clipImage = symbol("paperclip")

    override func draw(_ dirtyRect: NSRect) {
        guard let thread else { return }
        let top: CGFloat = isOpen ? RowMetrics.openTop : 0
        let h = RowMetrics.threadHeight
        let midY = top + h / 2
        // Grid: 10 dot | 28 avatar | 170 from | 1fr line | auto meta, gap 12, padding 0 14 0 12, margin 10.
        var x = RowMetrics.sideInset + 12 + (isOpen ? RowMetrics.openSideInset - RowMetrics.sideInset : 0)
        let right = bounds.width - RowMetrics.sideInset - 14 - (isOpen ? RowMetrics.openSideInset - RowMetrics.sideInset : 0)
        let unread = thread.isUnread

        // Unread dot
        if unread {
            theme.accent.ns.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 1.5, y: midY - 3.5, width: 7, height: 7)).fill()
        }
        x += 10 + 12

        // Avatar
        let sender = primarySender(thread)
        let avatarRect = NSRect(x: x + 1, y: midY - 13, width: 26, height: 26)
        AvatarColor.color(for: sender.email).setFill()
        NSBezierPath(ovalIn: avatarRect).fill()
        let initials = NSAttributedString(string: AvatarColor.initials(sender), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white, .kern: 0.2,
        ])
        let isz = initials.size()
        initials.draw(at: NSPoint(x: avatarRect.midX - isz.width / 2, y: avatarRect.midY - isz.height / 2))
        x += 28 + 12

        // Meta (right side) first, so the line knows its width.
        let metaFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let date = NSAttributedString(string: Format.relative(thread.date), attributes: [.font: metaFont, .foregroundColor: theme.ink3.ns])
        let dsz = date.size()
        var metaLeft = right - max(dsz.width, 0)
        actionRects = []
        if showActions && !isOpen {
            // `.acts`: archive, snooze, star on hover/selection, replacing date and star.
            let items: [(AppAction, NSImage?)] = [(.archive, Self.archiveImage), (.snoozeTomorrow, Self.clockImage), (.star, Self.starImage)]
            var ax = right - CGFloat(items.count) * 28 + 2
            metaLeft = ax - 8
            for (action, image) in items {
                let rect = NSRect(x: ax, y: midY - 13, width: 26, height: 26)
                actionRects.append((action, rect))
                image?.tinted(theme.ink2.ns).draw(in: rect.insetBy(dx: 6, dy: 6))
                ax += 28
            }
        } else {
            date.draw(at: NSPoint(x: right - dsz.width, y: midY - dsz.height / 2))
            metaLeft -= 8
            if thread.isStarred, let star = Self.starFill?.tinted(NSColor(srgbRed: 0.906, green: 0.647, blue: 0.043, alpha: 1)) {
                let r = NSRect(x: metaLeft - 14, y: midY - 7, width: 14, height: 14)
                star.draw(in: r)
                metaLeft -= 22
            }
            if thread.hasAttachments, let clip = Self.clipImage?.tinted(theme.ink3.ns) {
                let r = NSRect(x: metaLeft - 13, y: midY - 7, width: 13, height: 14)
                clip.draw(in: r)
                metaLeft -= 21
            }
            // `.meta{min-width:76px}`: the text line always ends at the same column.
            metaLeft = min(metaLeft, right - 76 - 4)
        }

        // Sender (170 pt column), with message count
        let fromFont = NSFont.systemFont(ofSize: 13, weight: unread ? .bold : .medium)
        let fromRect = NSRect(x: x, y: midY - 9, width: 170, height: 18)
        let from = NSMutableAttributedString(string: senderLabel(thread), attributes: [.font: fromFont, .foregroundColor: theme.ink.ns])
        if thread.messageCount > 1 {
            from.append(NSAttributedString(string: "  \(thread.messageCount)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: theme.ink3.ns,
            ]))
        }
        from.draw(with: fromRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        x += 170 + 12

        // Line: tag, subject, preview (subject/preview fade out when open)
        guard !isOpen else { return }
        var lx = x
        let lineRight = metaLeft - 4
        if let labelInfo, lineRight - lx > 80 {
            let tagFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            let tag = NSAttributedString(string: labelInfo.name, attributes: [.font: tagFont, .foregroundColor: labelInfo.color])
            let tsz = tag.size()
            let tagRect = NSRect(x: lx, y: midY - 9, width: tsz.width + 12, height: 18)
            labelInfo.color.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: tagRect, xRadius: 5, yRadius: 5).fill()
            tag.draw(at: NSPoint(x: lx + 6, y: midY - tsz.height / 2))
            lx += tagRect.width + 10
        }
        let subjectFont = NSFont.systemFont(ofSize: 13, weight: unread ? .semibold : .regular)
        let subject = NSAttributedString(string: thread.subject.isEmpty ? "(kein Betreff)" : thread.subject,
                                         attributes: [.font: subjectFont, .foregroundColor: theme.ink.ns])
        let available = max(0, lineRight - lx)
        let subjectWidth = min(subject.size().width, available * 0.6)
        subject.draw(with: NSRect(x: lx, y: midY - 9, width: subjectWidth + 1, height: 18),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        lx += subjectWidth + 10
        if lineRight - lx > 20 {
            let preview = NSAttributedString(string: thread.snippet, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.ink3.ns,
            ])
            preview.draw(with: NSRect(x: lx, y: midY - 9, width: lineRight - lx, height: 18),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }

    func action(at point: NSPoint) -> AppAction? {
        actionRects.first { $0.1.insetBy(dx: -2, dy: -4).contains(point) }?.0
    }

    private func primarySender(_ thread: ThreadSummary) -> Address {
        let selfEmails = AppModel.shared.selfEmails
        return thread.participants.first { !selfEmails.contains($0.email.lowercased()) } ?? thread.participants.first
            ?? Address(name: nil, email: "?")
    }

    /// `participantSummary` in `src/lib/format.ts`.
    private func senderLabel(_ thread: ThreadSummary) -> String {
        let selfEmails = AppModel.shared.selfEmails
        let others = thread.participants.filter { !selfEmails.contains($0.email.lowercased()) }
        let shown = Array((others.isEmpty ? thread.participants : others).prefix(3))
        let names = shown.enumerated().map { i, p in shown.count > 1 || i > 0 ? p.firstName : p.displayName }
        let extra = max(0, (others.isEmpty ? thread.participants.count : others.count) - shown.count)
        return names.joined(separator: ", ") + (extra > 0 ? " +\(extra)" : "")
    }

    // VoiceOver
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilityLabel() -> String? {
        guard let thread else { return nil }
        var parts = [senderLabel(thread), thread.subject, Format.relative(thread.date)]
        if thread.isUnread { parts.insert("Ungelesen", at: 0) }
        if thread.isStarred { parts.append("markiert") }
        if thread.hasAttachments { parts.append("mit Anhang") }
        if thread.messageCount > 1 { parts.append("\(thread.messageCount) Nachrichten") }
        return parts.joined(separator: ", ")
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

extension NSBezierPath {
    /// Rounded top corners only. `flipped` = y grows downwards.
    static func topRounded(_ r: NSRect, radius: CGFloat, flipped: Bool) -> NSBezierPath {
        roundedCorners(r, radius: radius, top: true, flipped: flipped)
    }
    static func bottomRounded(_ r: NSRect, radius: CGFloat, flipped: Bool) -> NSBezierPath {
        roundedCorners(r, radius: radius, top: false, flipped: flipped)
    }
    private static func roundedCorners(_ r: NSRect, radius: CGFloat, top: Bool, flipped: Bool) -> NSBezierPath {
        // In a flipped view "top" is minY.
        let roundMin = (top == flipped)
        let path = NSBezierPath()
        let rad = min(radius, r.height / 2, r.width / 2)
        if roundMin {
            path.move(to: NSPoint(x: r.minX, y: r.maxY))
            path.line(to: NSPoint(x: r.minX, y: r.minY + rad))
            path.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.minY + rad), radius: rad, startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: r.maxX - rad, y: r.minY))
            path.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.minY + rad), radius: rad, startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: r.maxX, y: r.maxY))
        } else {
            path.move(to: NSPoint(x: r.minX, y: r.minY))
            path.line(to: NSPoint(x: r.minX, y: r.maxY - rad))
            path.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad, startAngle: 180, endAngle: 90, clockwise: true)
            path.line(to: NSPoint(x: r.maxX - rad, y: r.maxY))
            path.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: r.maxX, y: r.minY))
        }
        return path
    }
}
