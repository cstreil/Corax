import AppKit
import Foundation
import CoraxKit

/// Every M1 action, reached the same way from a key, the menu bar or the palette.
enum AppAction: Hashable {
    case next, previous, toggle, close
    case pageDown, pageUp, first, last, openAttachment
    case archive, trash, snoozeTomorrow, snooze(presetID: String), star, unread, undo
    case reply, replyAll, forward, compose, composeInWindow
    // M2.9 Stufe B: das Verfassen-Panel
    case toggleDock, discardDraft
    case search, palette, shortcuts, nextTab, previousTab
    case view(MailView), account(Int64?)
    case theme(ThemeID), perfOverlay, addAccount, loadImages
    case calendarToggle, calendarClose, calendarToday, calendarMode(CalendarStore.Mode), calendarNewEvent
    case calendarSidebar, joinNextMeeting
    case toggleSidebar
    /// M2.18m: „Gehe zu Ordner/Label …“ — der Picker und seine Ziele. Die
    /// Ziele stehen auch in der Palette (`⌘K`), deshalb sind sie Aktionen.
    case goToPicker, goToFolder(Int64), goToLabel(Int64)
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
        case .composeInWindow: "Neue E-Mail im eigenen Fenster"
        case .toggleDock: AppModel.shared.compose.openId != nil
            ? "Entwurf minimieren" : "Entwurf öffnen"
        case .discardDraft: "Entwurf verwerfen"
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
        case .calendarSidebar: AppModel.shared.sidebar.isVisible
            ? "Seitenleiste ausblenden" : "Seitenleiste einblenden"
        case .toggleSidebar: AppModel.shared.sidebar.isVisible
            ? "Seitenleiste ausblenden" : "Seitenleiste einblenden"
        case .goToPicker: "Gehe zu Ordner/Label …"
        case .goToFolder(let id):
            ActionDispatcher.goToEntries
                .first { $0.kind == .folder && $0.targetId == id }
                .map { "Gehe zu Ordner: " + ($0.detail ?? $0.title) } ?? "Gehe zu Ordner"
        case .goToLabel(let id):
            ActionDispatcher.goToEntries
                .first { $0.kind == .label && $0.targetId == id }
                .map { "Gehe zu Label: " + $0.title } ?? "Gehe zu Label"
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
        case .reply: "R"
        case .replyAll: "⇧R"
        case .forward: "F"
        case .compose: "C"
        case .composeInWindow: "⌥C"
        case .toggleDock: "⌘⇧M"
        case .discardDraft: "⌘⇧⌫"
        case .search: "/"
        case .palette: "⌘K"
        case .shortcuts: "?"
        case .nextTab: "Tab"
        case .previousTab: "⇧Tab"
        case .calendarToggle: "⌥⌘2"
        case .calendarMode(.day): "D"
        case .calendarMode(.week): "W"
        case .calendarMode(.month): "M"
        case .calendarToday: "T"
        case .calendarNewEvent: "B"
        case .calendarSidebar: "\\"
        case .toggleSidebar: "\\"
        case .goToPicker: "G O"
        case .goToFolder: "G O"
        case .goToLabel: "G O"
        case .joinNextMeeting: "meeting"
        case .aiWrite: "I"
        case .aiAsk: "⇧I"
        case .aiProofread: "⌥⌘;"
        case .aiSearchFilter: "⌥⌘K"
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
        case .quoteSelection: ""
        case .sendDone: "⌥⇧⌘D"
        case .sendLater: "⌃⌘D"
        case .instantSend: "⌃⌥⌘D"
        case .attachFiles: "⌘⇧A"
        case .insertSnippet: "⌃⌘K"
        case .previewAttachments: "Y"
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
        // M2.8b: while the calendar covers the mail list, a thread action must
        // not run on whatever the list still has selected. Found in the sandbox:
        // `⌫` in the calendar went to the list and trashed a mail.
        if model.calendarOpen, targetsSelectedThread(action) {
            PerfLog.shared.write("action_refused_in_calendar \(action)")
            return
        }
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
        case .composeInWindow: model.composeNew(docked: false)
        case .toggleDock: model.toggleComposeDock()
        case .discardDraft: model.discardOpenDraft()
        case .search: model.searchFocusRequest += 1
        case .palette: model.paletteOpen = true
        case .goToPicker: model.goToOpen = true
        case .goToFolder(let id):
            // Nur ein echter Ordner aus der Liste: ein Zwischenknoten des Baums
            // hat eine negative Kennung und steht hier nie drin.
            model.goToOpen = false
            guard let folder = box.folders.first(where: { $0.id == id }) else { return }
            box.selectFolder(folder)
            box.focusList()
            PerfLog.shared.write("go_to kind=folder id=\(id)")
        case .goToLabel(let id):
            model.goToOpen = false
            guard let label = box.labels[id] else { return }
            box.selectLabel(id)
            box.focusList()
            PerfLog.shared.write("go_to kind=label id=\(id) name=\(label.name)")
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
        case .calendarNewEvent: NotificationCenter.default.post(name: .coraxCalendarNewEvent, object: nil)
        case .calendarSidebar: model.calendar.sidebarVisible.toggle()
        case .toggleSidebar: model.sidebar.toggle()
        case .joinNextMeeting: model.joinNextMeeting()
        case .aiWrite:
            // Context, as in Tauri: ⌘J drafts in the composer, summarizes in the
            // thread. The compose view ignores the note unless it holds the key
            // window.
            if box.inlineCompose != nil || !model.composeDrafts.isEmpty {
                NotificationCenter.default.post(name: .coraxComposeAI, object: "draft",
                                                userInfo: model.composeCommandTarget)
            } else if box.expandedId != nil {
                model.summarizeOpenThread()
            } else {
                model.toasts.show("Öffne zuerst einen Thread")
            }
        case .aiProofread:
            if box.inlineCompose != nil || !model.composeDrafts.isEmpty {
                NotificationCenter.default.post(name: .coraxComposeAI, object: "proofread",
                                                userInfo: model.composeCommandTarget)
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
        // M2.15: liegt der Kalender über der Liste, gehören die Tasten dem
        // Kalender — auch wenn die Tabelle noch den Fokus hat. Sonst wirkten
        // `R` (öffnete einen Entwurf), `X` und `G` weiter auf Mails (Audit).
        if AppModel.shared.calendarOpen { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // M2.9: `⌥C` legt den Entwurf im eigenen Fenster an (der einzige Weg,
        // der nicht im Panel landet). Muss vor der Modifikator-Sperre stehen.
        if let action = modifiedListAction(flags: flags, keyCode: event.keyCode) {
            perform(action)
            return true
        }
        // §3.6.1: hat ein Entwurf im Panel die Tastatur, lösen die
        // Listenkürzel nichts aus.
        guard listKeysEnabled(hasDraftFocus: AppModel.shared.compose.hasDraftFocus) else { return false }
        // M2.5: `⌘A` selects every loaded row. The command modifier is otherwise
        // the menu bar's business, so nothing else is taken here.
        if flags == .command, event.keyCode == 0 {
            perform(.selectAll)
            return true
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        // M2.14/M2.17: „Einzeltasten-Kürzel" in den Einstellungen schaltet nur
        // die Buchstaben- und Zeichenkürzel ab. Pfeile, Tab, Esc, ⌫ und ↵
        // bleiben Bedienung. Vorher las diesen Schalter niemand — er war
        // wirkungslos (im Prüflauf archivierte `E` trotz „aus").
        let singles = AppModel.shared.settings.singleKeyShortcuts
        let shift = flags.contains(.shift)
        let open = AppModel.shared.mailbox.expandedId != nil
        // M2.18n: `G` meldet sich mit einem Hinweis in der Statuszeile; die
        // zweite Taste kommt aus derselben Tabelle wie der Hinweis
        // (`GoSequence.targets`), damit beide nicht auseinanderlaufen.
        if AppModel.shared.goSequenceActive {
            // `Esc` schließt nur den Hinweis, nicht zusätzlich den offenen
            // Thread (der Hinweis ist der letzte sichtbare Zustand).
            if event.keyCode == 53 {
                AppModel.shared.endGoSequence(reason: "escape")
                return true
            }
            let second = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if singles, let target = GoSequence.target(for: second) {
                AppModel.shared.endGoSequence()
                PerfLog.shared.write("key_go second=\(second) target=\(target.key)")
                perform(target.view.map { .view($0) } ?? .goToPicker)
                return true
            }
            // Keine passende zweite Taste: die Folge endet, die Taste geht
            // ihren normalen Weg (Tauri verhält sich genauso).
            AppModel.shared.endGoSequence(reason: "other second=\(second)")
        }
        if !singles, event.charactersIgnoringModifiers?.lowercased() == "g" {
            // Ein Beleg für die echte Instanz: `G` kommt an, die Einzeltasten
            // sind aber aus (Einstellungen → Allgemein).
            PerfLog.shared.write("key_go blocked singles=0")
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
            // M2.14 §6: im offenen Thread blättert die Leertaste, in der Liste
            // klappt sie den Thread auf (wie bisher).
            if open { perform(.pageDown) } else { perform(.toggle) }
            return true
        case 53:
            AppModel.shared.endGoSequence(reason: "escape")
            perform(.close)
            return true                                       // Esc
        case 48: perform(shift ? .previousTab : .nextTab); return true // Tab
        case 51, 117: perform(.trash); return true        // ⌫ / Entf
        default: break
        }
        guard singles,
              let chars = event.charactersIgnoringModifiers?.lowercased(),
              let c = chars.first else { return false }
        let typed = event.characters ?? ""
        // M2.14 §3: verglichen wird das erzeugte Zeichen, nicht der keyCode.
        // Damit wirken # ! ? / \ auch auf der deutschen Tastatur.
        switch typed {
        case "#": perform(AppModel.shared.mailbox.view == .trash ? .permanentDelete : .trash); return true
        case "?": perform(.shortcuts); return true
        case "/": perform(.search); return true
        case "!": perform(.spam); return true
        case "\\": perform(.toggleSidebar); return true
        default: break
        }
        switch c {
        case "j": perform(.next)
        case "k": perform(.previous)
        case "o": perform(open ? .openAttachment : .toggle)
        case "e": perform(shift ? .unarchive : .archive)
        case "h": perform(.snoozeTomorrow)
        case "s": perform(.star)
        case "u": perform(.unread)
        case "z": perform(.undo)
        case "v": perform(.move)
        case "l": perform(.label)
        case "a": perform(.selectAll)
        case "x":
            // „Zeile zur Auswahl“ (M2.14 §6): die Cursor-Zeile umschalten.
            if let id = AppModel.shared.mailbox.selectedId { AppModel.shared.mailbox.toggleSelect(id) }
        case "r":
            // Markierter Text: nur die Auswahl zitieren, sonst Antworten (R)
            // bzw. Allen antworten (⇧R).
            AppModel.shared.quoteSelection(fallback: shift ? .replyAll : .reply)
        case "f": perform(.forward)
        case "c": perform(.compose)
        case "i": perform(shift ? .aiAsk : .aiWrite)
        case "y": perform(.previewAttachments)
        case "g":
            // M2.18n: Start der Folge; der Hinweis in der Statuszeile zeigt
            // jetzt sofort, was zur Wahl steht.
            AppModel.shared.beginGoSequence()
        default: return false
        }
        return true
    }

    /// §3.6.1: die Listenkürzel gelten nur, wenn die Liste die Tastatur hat.
    /// Steht der Fokus im Verfassen-Panel, bleibt die Taste dort.
    static func listKeysEnabled(hasDraftFocus: Bool) -> Bool { !hasDraftFocus }

    /// Die eine Einzeltaste mit Modifikator, die die Liste doch nimmt: `⌥C`
    /// legt den Entwurf im eigenen Fenster an (M2.9 §3.5).
    static func modifiedListAction(flags: NSEvent.ModifierFlags, keyCode: UInt16) -> AppAction? {
        if flags == .option, keyCode == 8 { return .composeInWindow }
        return nil
    }

    /// M2.18m: Ordner und Labels als Ziele — einmal für Titel, Palette und Picker.
    @MainActor static var goToEntries: [GoToEntry] {
        let box = AppModel.shared.mailbox
        return GoToEntries.make(folders: box.folders,
                                labels: Array(box.labels.values),
                                accounts: Dictionary(uniqueKeysWithValues: box.accounts.map { ($0.id, $0.label) }),
                                showsAccount: box.accounts.count > 1)
    }

    /// Everything the palette offers.
    static var paletteActions: [AppAction] {
        var list: [AppAction] = [.reply, .replyAll, .forward, .compose, .composeInWindow,
                                 .toggleDock, .archive, .trash, .snoozeTomorrow]
        if AppModel.shared.mailbox.expandedId != nil { list += [.openAttachment, .loadImages] }
        list += [.toggle, .first, .last]
        list += Format.snoozePresets().map { .snooze(presetID: $0.id) }
        list += [.star, .unread, .undo, .search, .nextTab, .previousTab, .shortcuts]
        // M2.18m: dieselben Ziele wie `G` `O` — Ordner und Labels.
        list.append(.goToPicker)
        list += goToEntries.map {
            $0.kind == .folder ? .goToFolder($0.targetId) : .goToLabel($0.targetId)
        }
        list += MailView.allCases.map { .view($0) }
        let accounts = AppModel.shared.mailbox.accounts
        if accounts.count > 1 { list.append(.account(nil)); list += accounts.map { .account($0.id) } }
        list += ThemeID.allCases.map { .theme($0) }
        list += [.addAccount, .perfOverlay, .calendarToggle, .calendarToday, .calendarNewEvent,
                 .calendarSidebar, .toggleSidebar, .joinNextMeeting]
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

extension KeyPress {
    /// Aus dem echten Tastenereignis; nur Corax kennt AppKit.
    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(characters: event.characters ?? "",
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                  command: flags.contains(.command),
                  option: flags.contains(.option),
                  control: flags.contains(.control),
                  shift: flags.contains(.shift))
    }
}

/// M2.14b: die Kombis, deren Menüpunkt auf deutscher Tastatur nicht trifft.
///
/// SwiftUI legt das Satzzeichen physisch ab, der Menüpunkt liegt dann auf der
/// US-Position (`⌘/` auf der Taste, die hier `ß` schreibt). Diese vier laufen
/// deshalb zusätzlich über den Tastenmonitor. Bewusst nur diese vier: alles
/// andere bleibt beim Menü, sonst gäbe es zwei Wege für dieselbe Taste.
@MainActor
enum MonitorKeys {
    struct Binding {
        let combo: String
        let action: AppAction
        /// Im Textfeld ist dieselbe Tastenkombi etwas anderes: `⌘/` ist dort
        /// `⇧⌘7`, die nummerierte Liste. Dort fängt der Editor sie ab.
        let outsideTextOnly: Bool
    }

    static let bindings: [Binding] = [
        Binding(combo: "⌘/", action: .shortcuts, outsideTextOnly: true),
        Binding(combo: "⌥⌘;", action: .aiProofread, outsideTextOnly: false),
        Binding(combo: "⌥⇧⌘C", action: .copyVerificationCode, outsideTextOnly: false),
    ]

    static func handle(_ press: KeyPress, inText: Bool) -> AppAction? {
        for binding in bindings where !(binding.outsideTextOnly && inText) {
            if ShortcutMap.matches(binding.combo, press) { return binding.action }
        }
        return nil
    }
}
