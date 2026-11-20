import AppKit
import Foundation
import RabeKit

/// Every M1 action, reached the same way from a key, the menu bar or the palette.
enum AppAction: Hashable {
    case next, previous, toggle, close
    case pageDown, pageUp, first, last, openAttachment
    case archive, trash, snoozeTomorrow, snooze(presetID: String), star, unread, undo
    case reply, replyAll, forward, compose
    case search, palette, shortcuts, nextTab, previousTab
    case view(MailView), account(Int64?)
    case theme(ThemeID), perfOverlay, addAccount, loadImages
    case calendarToggle, calendarClose, calendarToday, calendarMode(CalendarStore.Mode), calendarNewEvent
    case calendarSidebar, joinNextMeeting
    case aiWrite, aiAsk, aiProofread, aiSearchFilter, aiSettings
    case unsubscribe, copyVerificationCode
    // M2.5
    case selectAll, extendDown, extendUp
    case move, label, unarchive, spam, permanentDelete
    case viewFromSender, splitBySender, relabelAuto, syncNow
    case quoteSelection, sendDone, sendLater, instantSend, attachFiles, insertSnippet
    case previewAttachments

    /// Palette title and key hint (mockup sheet).
    @MainActor var title: String {
        switch self {
        case .next: AppModel.shared.mailbox.expandedId == nil ? "Nächster Thread" : "Weiter in der Nachricht / nächste Nachricht"
        case .previous: AppModel.shared.mailbox.expandedId == nil ? "Voriger Thread" : "Zurück in der Nachricht / vorige Nachricht"
        case .toggle: "Thread auf- / zuklappen"
        case .close: "Zuklappen / Entwurf verwerfen"
        case .pageDown: "Eine Seite weiter"
        case .pageUp: "Eine Seite zurück"
        case .first: AppModel.shared.mailbox.expandedId == nil ? "Erster Thread" : "Erste Nachricht"
        case .last: AppModel.shared.mailbox.expandedId == nil ? "Letzter Thread" : "Letzte Nachricht"
        case .openAttachment: "Ersten Anhang öffnen"
        case .archive: "Erledigt"
        case .trash: "In den Papierkorb verschieben"   // commands:title.moveToTrash
        case .snoozeTomorrow: "Später (morgen 8:00)"
        case .snooze(let id): "Zurückstellen: " + (Format.snoozePresets().first { $0.id == id }?.name ?? id)
        case .star: "Markieren / Markierung entfernen" // commands:title.starUnstar
        case .unread: "Als gelesen / ungelesen markieren" // commands:title.markReadUnread
        case .undo: Strings.undo
        case .reply: Strings.reply
        case .replyAll: Strings.replyAll
        case .forward: Strings.forward
        case .compose: Strings.newMail
        case .search: "Suche"                          // commands:title.search
        case .palette: "Befehlspalette"
        case .shortcuts: Strings.shortcuts
        case .nextTab: "Nächster Tab"
        case .previousTab: "Voriger Tab"
        case .view(let v): "Gehe zu " + Strings.view(v)
        case .account(let id): id == nil ? "Alle Konten" : "Konto: " + (AppModel.shared.mailbox.accounts.first { $0.id == id }?.label ?? "")
        case .theme(let t): "Darstellung: " + t.title
        case .perfOverlay: "Leistungs-Overlay"
        case .addAccount: "Konto hinzufügen …"
        case .loadImages: Strings.loadImages
        case .calendarToggle: AppModel.shared.calendarOpen ? "Kalender schließen" : "Kalender öffnen"
        case .calendarClose: "Zurück zum Postfach"
        case .calendarToday: "Kalender: Heute"
        case .calendarMode(let mode): "Kalender: \(mode.title)"
        case .calendarNewEvent: "Neuer Termin"
        case .calendarSidebar: AppModel.shared.calendar.sidebarVisible
            ? "Kalender-Seitenleiste ausblenden" : "Kalender-Seitenleiste einblenden"
        case .joinNextMeeting: "Nächstem Meeting beitreten"
        case .aiWrite:
            AppModel.shared.mailbox.inlineCompose != nil || !AppModel.shared.composeDrafts.isEmpty
                ? "Mit KI schreiben" : "Zusammenfassen"
        case .aiAsk: "Fragen an das Postfach"
        case .aiProofread: "Korrekturlesen"
        case .aiSearchFilter: "KI-Filter für die Suche"
        case .aiSettings: "Intelligenz …"
        case .unsubscribe: "Abmelden"
        case .copyVerificationCode: "Bestätigungscode kopieren"
        case .selectAll: AppModel.shared.mailbox.selectedIds.count > 1 ? "Auswahl aufheben" : "Alles auswählen"
        case .extendDown: "Auswahl nach unten erweitern"
        case .extendUp: "Auswahl nach oben erweitern"
        case .move: "Verschieben …"
        case .label: "Label …"
        case .unarchive: "Zurück in den Posteingang"
        case .spam: AppModel.shared.mailbox.view == .spam ? "Kein Spam" : "Als Spam markieren"
        case .permanentDelete: "Endgültig löschen"
        case .viewFromSender: "Alle von diesem Absender"
        case .splitBySender: "Split nach Absender …"
        case .relabelAuto: "Auto-Labels neu vergeben"
        case .syncNow: "Jetzt synchronisieren"
        case .quoteSelection: "Mit der Auswahl zitieren"
        case .sendDone: "Senden und erledigen"
        case .sendLater: "Später senden …"
        case .instantSend: "Sofort senden"
        case .attachFiles: "Dateien anhängen …"
        case .insertSnippet: "Textbaustein einfügen …"
        case .previewAttachments: "Anhänge ansehen"
        }
    }

    var keyHint: String {
        switch self {
        case .next: "↓"
        case .previous: "↑"
        case .toggle: "↵"
        case .close: "Esc"
        case .pageDown: "Bild↓"
        case .pageUp: "Bild↑"
        case .first: "Pos1"
        case .last: "Ende"
        case .openAttachment: "O"
        case .archive: "E"
        case .trash: "#"
        case .snoozeTomorrow: "H"
        case .star: "S"
        case .unread: "U"
        case .undo: "Z"
        case .reply: "A"
        case .replyAll: "⇧A"
        case .forward: "W"
        case .compose: "C"
        case .search: "/"
        case .palette: "⌘K"
        case .shortcuts: "?"
        case .nextTab: "Tab"
        case .previousTab: "⇧Tab"
        case .calendarToggle: "2"
        case .calendarMode(.day): "D"
        case .calendarMode(.week): "W"
        case .calendarMode(.month): "M"
        case .calendarToday: "T"
        case .calendarNewEvent: "B"
        case .calendarSidebar: "\\"
        case .joinNextMeeting: "meeting"
        case .aiWrite: "⌘J"
        case .aiAsk: "⌘⇧K"
        case .aiProofread: "⌘⇧P"
        case .aiSearchFilter: "⌘O"
        case .aiSettings: ""
        case .unsubscribe: "⌘U"
        case .copyVerificationCode: ""
        case .selectAll: "⌘A"
        case .extendDown: "⇧↓"
        case .extendUp: "⇧↑"
        case .move: "V"
        case .label: "L"
        case .unarchive: "⇧E"
        case .spam: "!"
        case .permanentDelete: "#"
        case .viewFromSender: ""
        case .splitBySender: ""
        case .relabelAuto: ""
        case .syncNow: ""
        case .quoteSelection: "⇧R"
        case .sendDone: "⌘⇧↵"
        case .sendLater: "⌘⇧L"
        case .instantSend: "⌘⇧Z"
        case .attachFiles: "⌘⇧A"
        case .insertSnippet: "⌘;"
        case .previewAttachments: "Leertaste"
        case .perfOverlay: "⌥⌘P"
        default: ""
        }
    }
}

@MainActor
enum ActionDispatcher {
    /// Actions that hit the thread the selection points at.
    private static func targetsSelectedThread(_ action: AppAction) -> Bool {
        switch action {
        case .archive, .trash, .snoozeTomorrow, .snooze, .star, .unread, .toggle,
             .reply, .replyAll, .forward, .openAttachment, .unsubscribe,
             .move, .label, .unarchive, .spam, .permanentDelete, .viewFromSender,
             .splitBySender, .previewAttachments:
            return true
        default:
            return false
        }
    }

    static func perform(_ action: AppAction) {
        let model = AppModel.shared
        let box = model.mailbox
        // W3: right after a list update moved the selection by itself, the first
        // action key would hit a thread the user never saw — ignore it once.
        if targetsSelectedThread(action), box.shouldIgnoreActionOnAutoSelection() { return }
        switch action {
        case .next: if box.expandedId != nil { ThreadNavigation.step(1, page: false) } else { box.step(1) }
        case .previous: if box.expandedId != nil { ThreadNavigation.step(-1, page: false) } else { box.step(-1) }
        case .pageDown: if box.expandedId != nil { ThreadNavigation.step(1, page: true) } else { box.pageList(1) }
        case .pageUp: if box.expandedId != nil { ThreadNavigation.step(-1, page: true) } else { box.pageList(-1) }
        case .first: if box.expandedId != nil { ThreadNavigation.edge(first: true) } else { box.selectEdge(first: true) }
        case .last: if box.expandedId != nil { ThreadNavigation.edge(first: false) } else { box.selectEdge(first: false) }
        case .openAttachment: ThreadNavigation.openAttachment()
        case .toggle: box.toggle()
        case .close:
            if box.inlineCompose != nil { model.discardInlineDraft() }
            else if box.expandedId != nil { box.collapse() }
            else if box.searchQuery != nil { box.endSearch() }
        case .archive: box.archive()
        case .trash: box.trash()
        case .snoozeTomorrow: box.snooze()
        case .snooze(let id):
            if let preset = Format.snoozePresets().first(where: { $0.id == id }) {
                box.snooze(until: preset.at, label: "Zurückgestellt: \(preset.name)")
            }
        case .star: box.toggleStar()
        case .unread: box.toggleUnread()
        case .undo:
            // A pending send's toast owns Z first (Undo-Send), then undo_last.
            if model.toasts.current?.action != nil,
               [Strings.sent, "Entwurf verworfen"].contains(model.toasts.current?.text ?? "") { model.toasts.runAction() }
            else { box.undo() }
        case .reply: model.reply(.reply)
        case .replyAll: model.reply(.replyAll)
        case .forward: model.reply(.forward)
        case .compose: model.composeNew()
        case .search: model.searchFocusRequest += 1
        case .palette: model.paletteOpen = true
        case .shortcuts: model.shortcutsOpen.toggle()
        case .nextTab: box.cycleTab(1)
        case .previousTab: box.cycleTab(-1)
        case .view(let v): box.setView(v)
        case .account(let id): box.setAccount(id)
        case .theme(let t): model.settings.set("theme", t.rawValue)
        case .perfOverlay: model.perfOverlay.toggle()
        case .addAccount: model.accountSheetOpen = true
        case .loadImages: box.loadImagesInExpanded()
        case .calendarToggle:
            model.calendarOpen.toggle()
            if model.calendarOpen {
                model.calendar.settings = model.settings
                Task {
                    await model.calendar.loadCalendars()
                    await model.calendar.refresh()
                }
            } else {
                model.mailbox.focusList()
            }
        case .calendarClose:
            model.calendarOpen = false
            model.mailbox.focusList()
        case .calendarToday: model.calendar.jumpToToday()
        case .calendarMode(let mode): model.calendar.setMode(mode)
        case .calendarNewEvent: NotificationCenter.default.post(name: .rabeCalendarNewEvent, object: nil)
        case .calendarSidebar: model.calendar.sidebarVisible.toggle()
        case .joinNextMeeting: model.joinNextMeeting()
        case .aiWrite:
            // Context, as in Tauri: ⌘J drafts in the composer, summarizes in the
            // thread. The compose view ignores the note unless it holds the key
            // window.
            if box.inlineCompose != nil || !model.composeDrafts.isEmpty {
                NotificationCenter.default.post(name: .rabeComposeAI, object: "draft")
            } else if box.expandedId != nil {
                model.summarizeOpenThread()
            } else {
                model.toasts.show("Öffne zuerst einen Thread")
            }
        case .aiProofread:
            if box.inlineCompose != nil || !model.composeDrafts.isEmpty {
                NotificationCenter.default.post(name: .rabeComposeAI, object: "proofread")
            } else {
                model.toasts.show("Korrekturlesen gibt es nur im Entwurf")
            }
        case .aiAsk: model.askOpen = true
        case .aiSearchFilter: model.searchAIRequest += 1
        case .aiSettings: SettingsNavigation.request(.intelligence)
        case .unsubscribe:
            // Tauri: the open thread, else the selection (`hasTargets`).
            if let id = box.expandedId ?? box.selectedId {
                model.unsubscribeThread(id)
            } else {
                model.toasts.show("Wähle zuerst einen Thread")
            }
        case .copyVerificationCode: model.copyLatestVerificationCode()
        // MARK: M2.5
        case .selectAll: box.selectAllVisible()
        case .extendDown: box.extendSelection(1)
        case .extendUp: box.extendSelection(-1)
        case .move: model.openMovePopover()
        case .label: model.openLabelPopover()
        case .unarchive: box.unarchive()
        case .spam: box.spam()
        case .permanentDelete:
            // In the trash the key deletes for good, everywhere else it trashes.
            if box.view == .trash { model.confirmPermanentDelete() } else { box.trash() }
        case .viewFromSender: model.viewFromSender()
        case .splitBySender: model.openSplitPopover()
        case .relabelAuto: model.relabelAutoLabels()
        case .syncNow: box.syncNow()
        case .quoteSelection: model.quoteSelection()
        case .sendDone: model.composeCommand("send_done")
        case .sendLater: model.composeCommand("send_later")
        case .instantSend: model.composeCommand("instant_send")
        case .attachFiles: model.composeCommand("attach")
        case .insertSnippet: model.composeCommand("snippet")
        case .previewAttachments: model.previewAttachments()
        }
    }

    /// Single-key shortcuts (TASTATUR.md). The open/closed state of the thread
    /// decides what a key means. Returns false when the key is not ours.
    static func handleListKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // M2.5: `⌘A` selects every loaded row. The command modifier is otherwise
        // the menu bar's business, so nothing else is taken here.
        if flags == .command, event.keyCode == 0 {
            perform(.selectAll)
            return true
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        let shift = flags.contains(.shift)
        let open = AppModel.shared.mailbox.expandedId != nil
        // `g` sequences (M2.5, Tauri's "g i" …): the second key picks the view.
        if let pending = pendingGo {
            pendingGo = nil
            if let view = Self.goViews[event.charactersIgnoringModifiers?.lowercased() ?? ""] {
                perform(.view(view))
                return true
            }
        }
        switch event.keyCode {
        case 125:
            perform(shift ? .extendDown : .next); return true   // ↓ / ⇧↓
        case 126:
            perform(shift ? .extendUp : .previous); return true // ↑ / ⇧↑
        case 121: perform(.pageDown); return true         // Bild↓
        case 116: perform(.pageUp); return true           // Bild↑
        case 115: perform(.first); return true            // Pos1
        case 119: perform(.last); return true             // Ende
        case 36, 76: perform(.toggle); return true        // ↵
        case 49:
            // Space: state A opens the thread, state B previews its attachments.
            if open { perform(.previewAttachments) } else { perform(.toggle) }
            return true
        case 53: perform(.close); return true             // Esc
        case 48: perform(shift ? .previousTab : .nextTab); return true // Tab
        case 51, 117: perform(.trash); return true        // ⌫ / Entf
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), let c = chars.first else { return false }
        let typed = event.characters ?? ""
        if typed == "#" { perform(.permanentDelete); return true }
        if typed == "?" { perform(.shortcuts); return true }
        if typed == "/" { perform(.search); return true }
        if typed == "!" { perform(.spam); return true }
        if typed == "2" { perform(.calendarToggle); return true }
        switch c {
        case "j": perform(.next)
        case "k": perform(.previous)
        case "o": perform(open ? .openAttachment : .toggle)
        case "e": perform(shift ? .unarchive : .archive)
        case "h": perform(.snoozeTomorrow)
        case "s": perform(.star)
        case "u": perform(.unread)
        case "z": perform(.undo)
        // ⇧R quotes the marked passage; without one Tauri falls through to
        // reply-all, so `quoteSelection` does exactly that.
        case "r": perform(shift ? .quoteSelection : .reply)
        case "a": perform(shift ? .replyAll : .reply)
        case "w", "f": perform(.forward)
        case "c": perform(.compose)
        case "m": perform(.calendarToggle)
        case "v": perform(.move)
        case "l": perform(.label)
        case "g":
            // Start of a "g i"/"g e" sequence; the next key picks the view.
            pendingGo = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let at = pendingGo, CFAbsoluteTimeGetCurrent() - at >= 1.1 { pendingGo = nil }
            }
        default: return false
        }
        return true
    }

    /// Start of a `g` sequence; cleared by the next key or after 1.2 s.
    private static var pendingGo: CFAbsoluteTime?
    /// Tauri's "go to" keys (`src/keyboard/commands.tsx`).
    private static let goViews: [String: MailView] = [
        "i": .inbox, "s": .starred, "d": .drafts, "t": .sent, "e": .done,
        "h": .snoozed, "#": .trash, "!": .spam, "a": .all,
    ]

    /// Everything the palette offers.
    static var paletteActions: [AppAction] {
        var list: [AppAction] = [.reply, .replyAll, .forward, .compose, .archive, .trash, .snoozeTomorrow]
        if AppModel.shared.mailbox.expandedId != nil { list += [.openAttachment, .loadImages] }
        list += [.toggle, .first, .last]
        list += Format.snoozePresets().map { .snooze(presetID: $0.id) }
        list += [.star, .unread, .undo, .search, .nextTab, .previousTab, .shortcuts]
        list += MailView.allCases.map { .view($0) }
        let accounts = AppModel.shared.mailbox.accounts
        if accounts.count > 1 { list.append(.account(nil)); list += accounts.map { .account($0.id) } }
        list += ThemeID.allCases.map { .theme($0) }
        list += [.addAccount, .perfOverlay, .calendarToggle, .calendarToday, .calendarNewEvent,
                 .calendarSidebar, .joinNextMeeting]
        list += [.aiWrite, .aiAsk, .aiProofread, .aiSearchFilter, .aiSettings]
        list += [.unsubscribe, .copyVerificationCode]
        // M2.5
        list += [.selectAll, .extendDown, .extendUp, .move, .label, .unarchive, .spam]
        if AppModel.shared.mailbox.view == .trash { list.append(.permanentDelete) }
        list += [.previewAttachments, .viewFromSender, .splitBySender, .relabelAuto, .syncNow]
        if AppModel.shared.mailbox.inlineCompose != nil || !AppModel.shared.composeDrafts.isEmpty {
            list += [.attachFiles, .insertSnippet, .sendDone, .sendLater, .instantSend, .quoteSelection]
        }
        list += CalendarStore.Mode.allCases.map { .calendarMode($0) }
        return list
    }
}
