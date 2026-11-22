import AppKit
import CoraxKit
import SwiftUI

/// The expanded thread inside its card (mockup `.thread`): title, actions,
/// messages (older ones folded), attachments, reply field.
struct ThreadDetailView: View {
    static let space = "coraxDetail"
    let threadId: Int64
    let onHeight: (CGFloat) -> Void
    @Environment(\.theme) private var theme

    private var box: MailboxStore { AppModel.shared.mailbox }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeight($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail = box.details[threadId] {
                let shown = visibleMessages(detail)
                let focusedId = box.focusedMessage(in: detail)?.id
                header(detail, count: shown.count)
                    .onAppear { box.noteDetailVisible(threadId, hasHTML: shown.last?.htmlBody?.isEmpty == false) }
                // M2.3: the AI summary sits above the messages (⌘J).
                AISummaryBlock(threadId: threadId,
                               onUseReply: { AppModel.shared.useAIProposedReply($0, threadId: threadId) },
                               onCreateEvent: { AppModel.shared.createEventFromSuggestion($0) })
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                    MessageView(message: message, threadId: threadId,
                                folded: index < shown.count - 1 && message.id != focusedId && !box.unfoldedMessages.contains(message.id),
                                recipientLabel: recipientLabel(message, detail),
                                focused: shown.count > 1 && message.id == focusedId)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { frame in
                            box.messageFrames[message.id] = frame
                        }
                    Rectangle().fill(theme.line.color).frame(height: 0.5)
                }
                replyArea(detail)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lädt …").foregroundStyle(theme.ink3.color)
                }
                .padding(.vertical, 24)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 14 + 64, bottom: 22, trailing: 14 + 28))
        .foregroundStyle(theme.ink.color)
    }

    /// The draft being edited inline is shown as the composer, not as a message.
    private func visibleMessages(_ detail: ThreadDetail) -> [MessageDetail] {
        detail.messages.filter { !($0.isDraft && $0.sendState == nil) || $0.id == -1 }
    }

    /// Subject of the conversation, not of a newer reply/draft ("Re: …").
    private func threadSubject(_ detail: ThreadDetail) -> String {
        detail.messages.first(where: { !$0.isDraft })?.subject ?? detail.thread.subject
    }

    private func header(_ detail: ThreadDetail, count: Int) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(threadSubject(detail).isEmpty ? "(kein Betreff)" : threadSubject(detail))
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(-0.3)
                    .textSelection(.enabled)
                // M2.18m: alle Labels des Threads als Chips unter dem Betreff.
                // Ohne Label bleibt die Zeile weg.
                let chips = threadLabels(detail)
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips) { label in labelChip(label) }
                    }
                    .padding(.top, 1)
                }
                Text("\(count) Nachricht\(count == 1 ? "" : "en") · \(senderEmail(detail))")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3.color)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                PillButton(title: nil, symbol: "sparkles", key: "⌘J", label: "Zusammenfassen") {
                    AppModel.shared.summarizeOpenThread()
                }
                PillButton(title: Strings.reply, symbol: "arrowshape.turn.up.left", key: "A") { ActionDispatcher.perform(.reply) }
                // M2.4: Tauri's thread header button, only for a thread whose
                // messages carry a List-Unsubscribe header.
                if detail.messages.contains(where: \.canUnsubscribe) {
                    PillButton(title: nil, symbol: "bell.slash", key: "⌘U", label: "Abmelden") {
                        ActionDispatcher.perform(.unsubscribe)
                    }
                }
                PillButton(title: nil, symbol: "archivebox", key: "E", label: "Archivieren") { ActionDispatcher.perform(.archive) }
                PillButton(title: nil, symbol: "clock", key: "H", label: "Später") { ActionDispatcher.perform(.snoozeTomorrow) }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 0.5) }
    }

    /// M2.18n: alle Labels des Threads — eigene zuerst, automatische danach mit
    /// Funkeln. Die Regel steht in `MailLabelDisplay`, damit Liste und Mail
    /// nicht auseinanderlaufen.
    private func threadLabels(_ detail: ThreadDetail) -> [CoraxKit.Label] {
        MailLabelDisplay.ordered(ids: detail.thread.labels, labels: box.labels)
    }

    private func labelChip(_ label: CoraxKit.Label) -> some View {
        Button { box.selectLabel(label.id) } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(CalendarChrome.hex(label.color) ?? theme.accent.color)
                    .frame(width: 7, height: 7)
                Text(label.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(1)
                // M2.18n: das Funkeln unterscheidet die automatischen
                // Kategorien von den eigenen Labels.
                if label.isAuto == true {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.ink3.color)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(theme.hover.color))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label.isAuto == true
              ? "Automatische Kategorie „\(label.name)“ — Liste filtern"
              : "Nach „\(label.name)“ filtern")
        .accessibilityLabel(label.isAuto == true
                            ? "Automatische Kategorie \(label.name), Liste filtern"
                            : "Label \(label.name), Liste filtern")
    }

    @ViewBuilder private func replyArea(_ detail: ThreadDetail) -> some View {
        Group {
            if let draft = box.inlineCompose {
                ComposeView(draft: draft, presentation: .inline)
            } else {
                Button { ActionDispatcher.perform(.reply) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrowshape.turn.up.left")
                        Text("Antworten an \(replyName(detail)) …")
                        Spacer()
                        KeyCap("A")
                    }
                    .foregroundStyle(theme.ink3.color)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 640, minHeight: 40, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line.color, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Antworten an \(replyName(detail))")
            }
        }
        .padding(.top, 16)
        .padding(.leading, 40)
    }

    private func senderEmail(_ detail: ThreadDetail) -> String {
        let me = AppModel.shared.selfEmails
        return detail.messages.last(where: { !me.contains($0.from.email.lowercased()) })?.from.email ?? detail.thread.accountEmail
    }

    private func replyName(_ detail: ThreadDetail) -> String {
        let me = AppModel.shared.selfEmails
        let focused = box.focusedMessage(in: detail)
        let other = focused.flatMap { m in me.contains(m.from.email.lowercased()) || m.isOutgoing ? m.to.first : m.from }
            ?? detail.messages.last(where: { !me.contains($0.from.email.lowercased()) })?.from
        guard let other else { return detail.thread.participants.first?.displayName ?? "" }
        // Mockup: people by first name, organisations by full name.
        if let name = other.name, name.contains(",") { return name.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? name }
        return other.displayName
    }

    private func recipientLabel(_ message: MessageDetail, _ detail: ThreadDetail) -> String {
        let me = AppModel.shared.selfEmails
        if message.isOutgoing || me.contains(message.from.email.lowercased()) {
            return "an " + (message.to.first?.displayName ?? "")
        }
        return "an mich"
    }
}

/// One message: folded to a single line, or full with body and attachments.
struct MessageView: View {
    let message: MessageDetail
    let threadId: Int64
    let folded: Bool
    let recipientLabel: String
    var focused = false
    @Environment(\.theme) private var theme
    @State private var htmlHeight: CGFloat?

    private var box: MailboxStore { AppModel.shared.mailbox }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AvatarView(address: message.from, size: 30)
                Text(message.from.displayName).fontWeight(.semibold)
                if folded {
                    Text(message.snippet).foregroundStyle(theme.ink3.color).lineLimit(1)
                } else {
                    Text(recipientLabel).font(.system(size: 12)).foregroundStyle(theme.ink3.color)
                }
                Spacer(minLength: 8)
                Text(Format.messageTime(message.dateValue)).font(.system(size: 12)).foregroundStyle(theme.ink3.color)
            }
            .contentShape(Rectangle())
            .onTapGesture { if folded { unfold() } }
            if !folded {
                // M2.2: an invite carried by this message, above its body.
                CalendarInviteCard(messageId: message.id)
                    .padding(.top, 12)
                    .padding(.leading, 40)
                bodyView
                    .padding(.top, 12)
                    .padding(.leading, 40)
                if !message.attachments.filter({ !$0.isInline }).isEmpty {
                    AttachmentStrip(attachments: message.attachments.filter { !$0.isInline }, threadId: threadId)
                        .padding(.top, 14)
                        .padding(.leading, 40)
                }
            }
        }
        .padding(.vertical, folded ? 10 : 16)
        // Focused message (TASTATUR.md, state B): accent bar left of the avatar.
        .background(alignment: .leading) {
            if focused {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accent.color.opacity(0.85))
                    .frame(width: 3)
                    .padding(.vertical, 12)
                    .offset(x: -14)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: folded ? .combine : .contain)
        .accessibilityAddTraits(focused ? .isSelected : [])
        .accessibilityLabel(folded ? "Nachricht von \(message.from.displayName), eingeklappt" : "")
        .accessibilityAddTraits(folded ? .isButton : [])
    }

    private func unfold() {
        withAnimation(Motion.animation) { _ = box.unfoldedMessages.insert(message.id) }
        if message.bodyState != "cached" { box.loadBody(messageId: message.id, threadId: threadId) }
    }

    @ViewBuilder private var bodyView: some View {
        if let html = message.htmlBody, !html.isEmpty, let client = AppModel.shared.client {
            let settings = AppModel.shared.settings
            let remote = settings.loadRemoteImages || box.remoteImageOverride.contains(message.id)
            let blocked = !remote && client.hasRemoteImages(html)
            VStack(alignment: .leading, spacing: 8) {
                if blocked {
                    HStack(spacing: 10) {
                        Image(systemName: "photo")
                        Text(Strings.imagesHidden)
                        Button(Strings.loadImages) { box.remoteImageOverride.insert(message.id) }
                            .buttonStyle(.link)
                            .foregroundStyle(theme.accent.color)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink2.color)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.hover.color))
                }
                HTMLMessageView(
                    html: client.htmlForDisplay(html, theme: theme.displayTheme, loadRemoteImages: remote),
                    darkMode: theme.isDark,
                    remoteAllowed: remote,
                    onHeight: { h in
                        if h >= 1, abs((htmlHeight ?? 0) - h) > 0.5 { htmlHeight = h }
                        if h >= 1 { box.noteHTMLMeasured(threadId) }
                    }
                )
                .id("\(message.id)-\(remote)")
                .frame(maxWidth: 680, alignment: .leading)
                .frame(height: htmlHeight ?? estimate(html))
            }
        } else if let text = message.textBody {
            QuotedText(text: text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .frame(maxWidth: 640, alignment: .leading)
                .textSelection(.enabled)
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Inhalt wird geladen …") }
                .foregroundStyle(theme.ink3.color)
                .onAppear { box.loadBody(messageId: message.id, threadId: threadId) }
        }
    }

    /// Placeholder height from text length until the page has been measured.
    private func estimate(_ html: String) -> CGFloat {
        let plain = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return min(900, max(48, CGFloat(plain.count) / 85 * 24 + 24))
    }
}

/// Plain-text body with the quoted tail folded (simplified `src/lib/quotes.ts`).
struct QuotedText: View {
    let text: String
    @State private var showQuote = false
    @Environment(\.theme) private var theme

    var body: some View {
        let (main, quote) = Self.split(text)
        VStack(alignment: .leading, spacing: 6) {
            Text(main)
            if let quote {
                Button(showQuote ? "Zitat ausblenden" : "•••") { withAnimation(Motion.animation) { showQuote.toggle() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.ink3.color)
                    .accessibilityLabel(showQuote ? "Zitat ausblenden" : "Zitat anzeigen")
                if showQuote { Text(quote).foregroundStyle(theme.ink2.color) }
            }
        }
    }

    /// Splits at the first attribution line ("Am … schrieb", "On … wrote:") or
    /// at the first run of "> " lines.
    static func split(_ text: String) -> (String, String?) {
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let attribution = (line.hasPrefix("Am ") && line.hasSuffix("schrieb:")) || (line.hasPrefix("On ") && line.hasSuffix("wrote:"))
                || line.hasPrefix("-----Original") || line.hasPrefix("---------- Weitergeleitete") || line.hasPrefix("---------- Forwarded")
            let quoted = line.hasPrefix(">") && lines[i...].allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            if (attribution || quoted), i > 0 {
                let main = lines[..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return (main, lines[i...].joined(separator: "\n"))
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
}

/// Attachments of one message. M2.5: a click opens the system Quick Look
/// preview (one viewer instead of nine); "Öffnen mit App" and "Sichern unter"
/// stay in the context menu.
struct AttachmentStrip: View {
    let attachments: [AttachmentMeta]
    let threadId: Int64
    @Environment(\.theme) private var theme

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { index, a in
                Button { preview(index: index) } label: {
                    HStack(spacing: 10) {
                        Text(Format.fileBadge(a))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 7).fill(badgeColor(a)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.filename ?? Strings.attachmentFallback).lineLimit(1)
                            Text("\(Format.fileBadge(a)) · \(Format.size(a.size))").font(.system(size: 11)).foregroundStyle(theme.ink3.color)
                        }
                    }
                    .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 12))
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.win.color))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line.color, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Vorschau") { preview(index: index) }
                    Button("Öffnen mit App") { AppModel.shared.mailbox.openAttachment(a) }
                    Button("Sichern unter …") { AppModel.shared.mailbox.saveAttachment(a) }
                }
                .accessibilityLabel("Anhang \(a.filename ?? Strings.attachmentFallback), \(Format.size(a.size))")
                .accessibilityAction(named: "Sichern unter") { AppModel.shared.mailbox.saveAttachment(a) }
            }
        }
    }

    private func preview(index: Int) {
        AttachmentPreview.shared.show(attachments: attachments, startAt: index, threadId: threadId)
        PerfLog.shared.write("attachment_click index=\(index) thread=\(threadId)")
    }

    private func badgeColor(_ a: AttachmentMeta) -> Color {
        let mime = a.mimeType ?? ""
        if mime.hasPrefix("image/") { return Color(red: 0.486, green: 0.361, blue: 1) }   // #7c5cff
        return Color(red: 0.898, green: 0.282, blue: 0.302)                               // #e5484d
    }
}

// MARK: Small building blocks

/// Round sender avatar: the sender's picture when "Absenderfotos" is on and the
/// core has one (`sender_avatar`, M2.4), else the initials in the address colour.
struct AvatarView: View {
    let address: Address
    var size: CGFloat = 26

    private var photosOn: Bool { AppModel.shared.settings.showSenderPhotos }

    var body: some View {
        let image = photosOn ? AvatarImages.image(for: address.email) : nil
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Color(nsColor: AvatarColor.color(for: address.email)))
                Text(AvatarColor.initials(address))
                    .font(.system(size: size * 0.37, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear {
            if photosOn { AppModel.shared.avatars.request(address.email) }
        }
        .accessibilityHidden(true)
    }
}

struct KeyCap: View {
    let key: String
    @Environment(\.theme) private var theme
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(theme.ink2.color)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.kbd.color))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line.color, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct PillButton: View {
    let title: String?
    let symbol: String
    let key: String
    var label: String? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13))
                if let title { Text(title).fontWeight(.medium).lineLimit(1) }
                KeyCap(key)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(hover ? theme.ink.color : theme.ink2.color)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? theme.hover.color : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line.color, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title ?? label ?? "")
        .help("\(title ?? label ?? "") (\(key))")
    }
}

/// Wrapping row layout for attachment chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
