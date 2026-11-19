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
             .reply, .replyAll, .forward, .openAttachment:
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
        }
    }

    /// Single-key shortcuts (TASTATUR.md). The open/closed state of the thread
    /// decides what a key means. Returns false when the key is not ours.
    static func handleListKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        let shift = flags.contains(.shift)
        let open = AppModel.shared.mailbox.expandedId != nil
        switch event.keyCode {
        case 125: perform(.next); return true             // ↓
        case 126: perform(.previous); return true         // ↑
        case 121: perform(.pageDown); return true         // Bild↓
        case 116: perform(.pageUp); return true           // Bild↑
        case 115: perform(.first); return true            // Pos1
        case 119: perform(.last); return true             // Ende
        case 36, 76: perform(.toggle); return true        // ↵
        case 49: if !open { perform(.toggle) }; return true // Space (state A only)
        case 53: perform(.close); return true             // Esc
        case 48: perform(shift ? .previousTab : .nextTab); return true // Tab
        case 51, 117: perform(.trash); return true        // ⌫ / Entf
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), let c = chars.first else { return false }
        let typed = event.characters ?? ""
        if typed == "#" { perform(.trash); return true }
        if typed == "?" { perform(.shortcuts); return true }
        if typed == "/" { perform(.search); return true }
        switch c {
        case "j": perform(.next)
        case "k": perform(.previous)
        case "o": perform(open ? .openAttachment : .toggle)
        case "e": perform(.archive)
        case "h": perform(.snoozeTomorrow)
        case "s": perform(.star)
        case "u": perform(.unread)
        case "z": perform(.undo)
        case "a", "r": perform(shift ? .replyAll : .reply)
        case "w", "f": perform(.forward)
        case "c": perform(.compose)
        default: return false
        }
        return true
    }

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
        list += [.addAccount, .perfOverlay]
        return list
    }
}
