import AppKit
import RabeKit

/// State B of TASTATUR.md: moving through the open thread. The detail row has
/// no scroll area of its own, so every step scrolls the list; message frames
/// come from SwiftUI geometry (`MailboxStore.messageFrames`).
@MainActor
enum ThreadNavigation {
    /// ≈ 3 rows per arrow step.
    static let lineStep: CGFloat = 3 * RowMetrics.threadHeight
    /// Space kept above/below a message edge when it is revealed.
    static let margin: CGFloat = 12

    private static var box: MailboxStore { AppModel.shared.mailbox }

    private static func context() -> (id: Int64, messages: [MessageDetail], focused: MessageDetail, nav: ListNavigating)? {
        guard let id = box.expandedId, let detail = box.details[id], let nav = box.navigator,
              let focused = box.focusedMessage(in: detail) else { return nil }
        let messages = detail.messages.filter { !($0.isDraft && $0.sendState == nil) }
        return (id, messages, focused, nav)
    }

    /// `↓`/`↑` (page: `Bild↓`/`Bild↑`).
    static func step(_ direction: Int, page: Bool) {
        guard let c = context(), let visible = c.nav.visibleDetailRange(c.id) else { return }
        let height = visible.upperBound - visible.lowerBound
        let amount = page ? max(lineStep, height - RowMetrics.threadHeight) : lineStep
        let frame = box.messageFrames[c.focused.id]
        if direction > 0 {
            if let frame, frame.maxY > visible.upperBound + 1 {
                // Rest of the focused message first; stop at its end.
                c.nav.scrollList(by: min(amount, frame.maxY - visible.upperBound + margin))
                return
            }
            guard let i = c.messages.firstIndex(where: { $0.id == c.focused.id }), i + 1 < c.messages.count else { return }
            focus(c.messages[i + 1], in: c.id, reveal: .top)
        } else {
            if let frame, frame.minY < visible.lowerBound - 1 {
                c.nav.scrollList(by: -min(amount, visible.lowerBound - frame.minY + margin))
                return
            }
            guard let i = c.messages.firstIndex(where: { $0.id == c.focused.id }), i > 0 else { return }
            focus(c.messages[i - 1], in: c.id, reveal: .bottom)
        }
    }

    /// `Pos1`/`Ende`: first/last message.
    static func edge(first: Bool) {
        guard let c = context(), let target = first ? c.messages.first : c.messages.last else { return }
        focus(target, in: c.id, reveal: .top)
    }

    /// `O`: first attachment of the focused message (`open_attachment`).
    static func openAttachment() {
        guard let c = context() else { return }
        guard let attachment = c.focused.attachments.first(where: { !$0.isInline }) else {
            AppModel.shared.toasts.show("Diese Nachricht hat keinen Anhang")
            return
        }
        box.openAttachment(attachment)
    }

    enum Reveal { case top, bottom }

    /// Focus a message (unfolds it) and bring its start (or end) into view once
    /// SwiftUI has laid it out.
    static func focus(_ message: MessageDetail, in threadId: Int64, reveal: Reveal) {
        box.focusedMessageId = message.id
        if !box.unfoldedMessages.contains(message.id) {
            box.unfoldedMessages.insert(message.id)
            if message.bodyState != "cached" { box.loadBody(messageId: message.id, threadId: threadId) }
        }
        PerfLog.shared.write("focus_message id=\(message.id) reveal=\(reveal)")
        // Unfolding changes heights; wait for the next layout (row height follows).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { revealNow(message.id, threadId, reveal) }
    }

    private static func revealNow(_ messageId: Int64, _ threadId: Int64, _ reveal: Reveal) {
        guard box.expandedId == threadId, let nav = box.navigator, let frame = box.messageFrames[messageId],
              let visible = nav.visibleDetailRange(threadId) else { return }
        let height = visible.upperBound - visible.lowerBound
        switch reveal {
        case .top:
            // Start visible with some room below it; otherwise put it at the top.
            if frame.minY < visible.lowerBound || frame.minY > visible.upperBound - min(120, height / 3) {
                nav.scrollDetail(threadId, toTop: frame.minY - margin)
            }
        case .bottom:
            if frame.maxY > visible.upperBound || frame.maxY < visible.lowerBound + min(120, height / 3) {
                nav.scrollDetail(threadId, toTop: frame.maxY + margin - height)
            }
        }
    }
}
