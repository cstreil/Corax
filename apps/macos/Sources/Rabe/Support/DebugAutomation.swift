import AppKit
import Foundation
import RabeKit

// Compiled only into debug builds, or release builds made with
// `RABE_TEST_HOOKS=1 scripts/build-app.sh` (acceptance walkthrough).
#if DEBUG || RABE_TEST_HOOKS

/// Test hook, active only with `RABE_DEBUG_AUTOMATION=1`: replays key presses
/// sent as distributed notifications through `NSApp.sendEvent`, i.e. the same
/// path a physical keystroke takes (menu key equivalents, first responder,
/// `keyDown` of the list). Lets the acceptance walkthrough run without taking
/// the user's foreground or pointer.
///
///   name:   <AppIdentity.current>.debug
///   object: "key:j" | "key:r:shift" | "key:return:cmd" | "key:k:cmd" | "type:Hallo" | "log:<text>"
@MainActor
enum DebugAutomation {
    static var enabled: Bool { ProcessInfo.processInfo.environment["RABE_DEBUG_AUTOMATION"] == "1" }

    static func install() {
        guard enabled else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: AppIdentity.notification("debug"), object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command) }
        }
        PerfLog.shared.write("debug_automation installed")
        AIWalkthrough.install()
    }

    /// Die Kürzel der Menüleiste ins Log: eine Zeile je Punkt mit Kürzel.
    private static func dumpMenus() {
        guard let main = NSApp.mainMenu else { return }
        for menu in main.items {
            guard let sub = menu.submenu else { continue }
            // M2.17: **alle** Punkte, nicht nur die mit Kürzel — ein dauerhaft
            // ausgegrauter Punkt ohne Kürzel wäre sonst unsichtbar.
            for item in sub.items {
                guard !item.isSeparatorItem else { continue }
                var mask = ""
                if item.keyEquivalentModifierMask.contains(.command) { mask += "cmd+" }
                if item.keyEquivalentModifierMask.contains(.shift) { mask += "shift+" }
                if item.keyEquivalentModifierMask.contains(.option) { mask += "opt+" }
                if item.keyEquivalentModifierMask.contains(.control) { mask += "ctrl+" }
                let specials: [String: String] = [
                    "\u{7f}": "delete", "\u{8}": "backspace",
                    String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "downarrow",
                    String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "uparrow",
                    "\t": "tab",
                ]
                let raw = item.keyEquivalent
                let key = specials[raw] ?? (raw.isEmpty ? "-" : raw)
                PerfLog.shared.write("menu \(menu.title) / \(item.title) key=\(mask)\(key)"
                                     + " enabled=\(item.isEnabled ? 1 : 0)"
                                     + (item.submenu != nil ? " submenu=1" : ""))
            }
        }
    }

    /// Hook-Befehle für das Verfassen-Panel (M2.9 Stufe B). Alles läuft über
    /// dieselben Methoden wie `C`, `⌘⇧M` und die Knöpfe im Panel-Kopf.
    private static func dock(_ argument: String) {
        let model = AppModel.shared
        let dock = model.compose
        let spec = argument.split(separator: ":").map(String.init)
        switch spec.first ?? "state" {
        case "new":
            ActionDispatcher.perform(.compose)
        case "newwin":
            ActionDispatcher.perform(.composeInWindow)
        case "seed":
            let count = max(1, Int(spec.count > 1 ? spec[1] : "2") ?? 2)
            let subjects = ["Angebot 47 – Rückfrage zum Termin", "Rechnung 2026-118 offen",
                            "Wochenbericht KW 47", "Kurz: passt Freitag?"]
            for index in 0..<count {
                model.composeNew(to: [Address(name: "Kunde \(index + 1)", email: "kunde\(index + 1)@example.com")],
                                 subject: subjects[index % subjects.count],
                                 body: "Hallo,\n\nkurze Rückfrage zum Termin am Freitag: passt 17 Uhr?\n\nViele Grüße")
            }
        case "toggle":
            // Derselbe Weg wie `⌘⇧M` (Menüpunkt „Entwurf minimieren").
            model.toggleComposeDock()
        case "minimize":
            if let id = dock.openId { dock.minimize(id); dock.focusList() }
        case "maximize":
            if let id = dock.openId { dock.maximize(id) }
        case "open":
            let index = Int(spec.count > 1 ? spec[1] : "0") ?? 0
            let bars = dock.barIds
            if bars.indices.contains(index) { dock.open(bars[index]) }
        case "cycle":
            model.cycleDraftFocus()
        case "cycleback":
            model.cycleDraftFocus(backward: true)
        case "discard":
            model.discardOpenDraft()
        case "close":
            if let id = dock.openId { model.closeDockedDraft(id) }
        case "closeall":
            for id in dock.order { model.composeDrafts[id] = nil; dock.remove(id) }
        case "detach":
            model.detachInlineDraft()
        case "state":
            break
        default:
            break
        }
        let titles = dock.order.map { id -> String in
            let title = model.composeDrafts[id]?.panelTitle ?? "-"
            return "\(dock.state(id)?.rawValue ?? "?")=\(title)"
        }
        PerfLog.shared.write("walkthrough dock open=\(dock.openId == nil ? "-" : "1")"
                             + " openTitle=\(dock.openId.flatMap { model.composeDrafts[$0]?.panelTitle } ?? "-")"
                             + " bars=\(dock.barIds.count) drafts=\(dock.count)"
                             + " focus=\(dock.hasDraftFocus ? "draft" : "list")"
                             + " order=[\(titles.joined(separator: "; "))]")
    }

    private static let keyCodes: [String: UInt16] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "down": 125, "up": 126, "left": 123, "right": 124,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "/": 44, "#": 42, "?": 44, ",": 43,
        "pagedown": 121, "pageup": 116, "home": 115, "end": 119,
    ]

    private static func run(_ command: String) {
        PerfLog.shared.write("debug_cmd \(command)")
        // M2.5: commands without an argument (`contextmenu`, `folders`) are valid.
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        guard !parts.isEmpty, !parts[0].isEmpty else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "key":
            let spec = parts[1].split(separator: ":").map(String.init)
            var flags: NSEvent.ModifierFlags = []
            for mod in spec.dropFirst() {
                switch mod {
                case "shift": flags.insert(.shift)
                case "cmd": flags.insert(.command)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            press(spec[0], flags: flags)
        case "type":
            for ch in parts[1] { press(String(ch), flags: ch.isUppercase ? [.shift] : [], literal: true) }
        case "postkey":
            // Same key, but through the event queue instead of `sendEvent`, so
            // local monitors see it (M2.8b: Escape while a card is open).
            post(key: parts[1])
        case "scrollrun":
            ScrollRun.start(seconds: Double(parts[1]) ?? 20)
        case "theme":   // theme:paper|carbon|system (writes the setting; sandbox only)
            if let id = ThemeID(rawValue: parts[1]) { ActionDispatcher.perform(.theme(id)) }
        case "view":    // view:inbox|all|… (navigation only, read-only)
            if let v = MailView(rawValue: parts[1]) { ActionDispatcher.perform(.view(v)) }
        case "winsize":  // winsize:1100x620 (main window content size, for screenshots)
            let wh = parts[1].split(separator: "x").compactMap { Double($0) }
            if wh.count == 2, let w = NSApp.windows.first(where: { $0.title == Instance.title }) {
                var f = w.frame; f.origin.y += f.height - wh[1]; f.size = NSSize(width: wh[0], height: wh[1])
                w.setFrame(f, display: true)
            }
        case "winpos":
            // winpos:x,y,w,h — fixes the main window, so a screen capture for a
            // menu or the Quick Look panel covers exactly this app (M2.5).
            let values = parts[1].split(separator: ",").compactMap { Double($0) }
            if values.count == 4, let w = NSApp.windows.first(where: { $0.title == Instance.title }) {
                w.setFrame(NSRect(x: values[0], y: values[1], width: values[2], height: values[3]), display: true)
                PerfLog.shared.write("winpos \(Int(values[0])),\(Int(values[1])) \(Int(values[2]))x\(Int(values[3]))")
            }
        case "focuswin":
            // focuswin:<title> — makes that window the key window of this app
            // without activating it, so `key:`/`type:` land in the right place
            // (the compose window is not key when it appears while the app is
            // in the background).
            if let w = NSApp.windows.first(where: { $0.title == parts[1] && $0.isVisible }) {
                w.makeKeyAndOrderFront(nil)
                PerfLog.shared.write("focuswin title=\(parts[1]) id=\(w.windowNumber) "
                                     + "key=\(NSApp.keyWindow === w ? 1 : 0) "
                                     + "responder=\(String(describing: w.firstResponder.map { type(of: $0) }))")
            } else {
                PerfLog.shared.write("focuswin missing=\(parts[1])")
            }
        case "focuslist":
            AppModel.shared.mailbox.focusList()
        case "sidebar":
            // sidebar:toggle | sidebar:on | sidebar:off — M2.9, ohne Klick.
            let state = AppModel.shared.sidebar
            switch parts.count > 1 ? parts[1] : "toggle" {
            case "on": if !state.isVisible { state.toggle() }
            case "off": if state.isVisible { state.toggle() }
            default: state.toggle()
            }
            PerfLog.shared.write("walkthrough sidebar visible=\(state.isVisible ? 1 : 0) "
                                 + "width=\(Int(state.windowWidth)) wants=\(state.userWantsVisible ? 1 : 0)")
        case "sidebarview":
            // sidebarview:mail|calendar — derselbe Hook-Umweg wie `1`/`2`.
            if parts.count > 1 {
                let open = parts[1] == "calendar"
                if AppModel.shared.calendarOpen != open {
                    ActionDispatcher.perform(open ? .calendarToggle : .calendarClose)
                }
            }
            PerfLog.shared.write("walkthrough sidebarview calendar=\(AppModel.shared.calendarOpen ? 1 : 0)")
        case "menu":
            // menu:dump — welche Menüpunkte tragen welches Kürzel? Beleg dafür,
            // dass ⌘⇧M und ⌘⇧⌫ wirklich am Menü hängen: einen echten
            // Tastendruck kann ein Hook nicht auslösen (Menü-Kürzel laufen
            // nicht über `sendEvent`).
            dumpMenus()
        case "dock":
            // M2.9 Stufe B, ohne Klick:
            //   dock:seed:<n> | new | newwin | minimize | maximize | open:<i>
            //   | cycle | cycleback | discard | close | closeall | detach | state
            dock(argument)
        case "droplist":
            // A list update that drops the selected thread (W3): sync removed it
            // elsewhere. Uses the production `applyThreads` path.
            let box = AppModel.shared.mailbox
            let fresh = box.threads.filter { $0.id != box.selectedId }
            box.applyThreads(fresh, cursor: box.nextCursor)
        case "savedialog":
            // "Sichern unter …" for the first attachment of the open thread (R1).
            let box = AppModel.shared.mailbox
            if let id = box.expandedId, let detail = box.details[id],
               let attachment = detail.messages.flatMap(\.attachments).first(where: { !$0.isInline }) {
                PerfLog.shared.write("savedialog attachment=\(attachment.id)")
                box.saveAttachment(attachment)
            } else {
                PerfLog.shared.write("savedialog no_attachment")
            }
        case "chrome":
            // chrome:notoolbar | chrome:toolbar — Experiment: ohne `NSToolbar`
            // liegt die Titelbar nicht mehr über dem Band (M2.15 1.1).
            if let window = mainWindow {
                if argument == "notoolbar" {
                    window.toolbar = nil
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                }
                let titlebar = window.contentView?.superview?.subviews.first { String(describing: type(of: $0)).contains("Titlebar") }
                PerfLog.shared.write("chrome arg=\(argument) toolbar=\(window.toolbar == nil ? "nil" : "yes") "
                                     + "titlebar=\(titlebar.map { "\(type(of: $0)) h=\(Int($0.frame.height)) y=\(Int($0.frame.minY))" } ?? "-") "
                                     + "content=\(window.contentView.map { "h=\(Int($0.frame.height)) y=\(Int($0.frame.minY))" } ?? "-") "
                                     + "insets=\(window.contentLayoutRect)")
            }
        case "hittest":
            // hittest:<x>x<y> — welcher AppKit-View bekommt den Klick an dieser
            // Fensterstelle (y von oben)? Der Theme-Frame entscheidet über
            // Titelbar und Werkzeugleiste; `contentView.hitTest` sähe das nicht,
            // weil die Titelbar über dem Inhalt liegt.
            if let spec = clickPoint(parts), let window = mainWindow {
                let point = NSPoint(x: CGFloat(spec.x), y: window.frame.height - CGFloat(spec.y))
                var chain: [String] = []
                var view = window.contentView?.superview?.hitTest(point)
                while let v = view, chain.count < 10 {
                    chain.append(String(describing: type(of: v)))
                    view = v.superview
                }
                PerfLog.shared.write("hittest x=\(spec.x) y=\(spec.y) h=\(Int(window.frame.height)) "
                                     + "toolbar=\(window.toolbar.map { String(describing: type(of: $0)) } ?? "-") "
                                     + "hit=" + (chain.first ?? "nil") + " chain=" + chain.joined(separator: "<"))
            }
        case "click":
            // click:<x>x<y> — ein echter Mausklick durch `NSApp.sendEvent`, also
            // mit Hit-Test wie ein Zeigerklick (y von oben). Ersatz, wenn CUA
            // das Fenster gerade nicht erreicht.
            if let spec = clickPoint(parts), let window = mainWindow {
                let point = NSPoint(x: CGFloat(spec.x), y: window.frame.height - CGFloat(spec.y))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point,
                                                      modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.sendEvent(event)
                    }
                }
                PerfLog.shared.write("debug_click x=\(spec.x) y=\(spec.y)")
            }
        case "windowid":
            // windowid — logs every visible window with its number, title and
            // size, so a walkthrough can screenshot the right one.
            PerfLog.shared.write("windows total=\(NSApp.windows.count) active=\(NSApp.isActive)")
            for w in NSApp.windows where w.isVisible {
                PerfLog.shared.write("window id=\(w.windowNumber) title=\(w.title) size=\(Int(w.frame.width))x\(Int(w.frame.height)) "
                                     + "origin=\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y))")
            }
        case "settings":
            // settings:<page> — opens ⌘, on that page (M2.1 walkthrough);
            // settings:scenario — create/change/delete per editor;
            // settings:signout — removes the first sandbox account.
            if parts[1] == "scenario" {
                Task { await SettingsWalkthrough.run() }
            } else if parts[1] == "signout" {
                Task { await SettingsWalkthrough.signOutFirstAccount() }
            } else if parts[1].hasPrefix("language:") {
                let choice = String(parts[1].dropFirst("language:".count))
                Task { await SettingsWalkthrough.setLanguage(choice) }
            } else if let page = SettingsPage(rawValue: parts[1]) {
                SettingsWalkthrough.open(page)
            }
        case "calendar":
            // calendar:open | close | mode:<day|week|month> | today | page:<n>
            // | scenario | perf | state — the M2.2 walkthrough (sandbox only).
            let spec = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            switch spec.first ?? "" {
            case "open": CalendarWalkthrough.open()
            case "close":
                AppModel.shared.calendarOpen = false
                AppModel.shared.mailbox.focusList()
            case "mode": if spec.count == 2 { CalendarWalkthrough.setMode(spec[1]) }
            case "today": CalendarWalkthrough.today()
            case "page": if spec.count == 2 { CalendarWalkthrough.page(Int(spec[1]) ?? 1) }
            case "scenario": Task { await CalendarWalkthrough.runScenario() }
            case "perf": Task { await CalendarWalkthrough.runPerf() }
            case "seedday": Task { await CalendarWalkthrough.seedDay(count: Int(spec.count > 1 ? spec[1] : "6") ?? 6) }
            // M2.12: Seed über zwei Wochen, der Verbindungsweg und die
            // Statuszeile der Einstellungen (gleiche Methoden wie die UI).
            case "seedm212": Task { await CalendarWalkthrough.seedM212() }
            case "connect": Task { await CalendarWalkthrough.connect(argument) }
            case "connectstate": CalendarWalkthrough.connectState()
            case "syncnow": Task { await CalendarWalkthrough.syncNow() }
            case "join": Task { await CalendarWalkthrough.join(dry: spec.count > 1 && spec[1] == "dry") }
            case "sidebar": CalendarWalkthrough.sidebar()
            case "daylist":
                if spec.count > 1, spec[1] == "close" {
                    NotificationCenter.default.post(name: .rabeCalendarDayList, object: nil,
                                                    userInfo: ["day": Int64(-1)])
                } else {
                    CalendarWalkthrough.dayList(spec.count > 1 ? spec[1] : "")
                }
            case "state": CalendarWalkthrough.state()
            case "dump": CalendarWalkthrough.dump()
            case "click":
                // M2.8b: one click (click:<id>) or a double click (click2:<id>)
                // through the grid's own handler; then the popover state.
                let id = Int64(spec.count > 1 ? spec[1] : "0") ?? 0
                CalendarWalkthrough.click(id: id, times: 1)
            case "click2":
                let id = Int64(spec.count > 1 ? spec[1] : "0") ?? 0
                CalendarWalkthrough.click(id: id, times: 2)
            case "editorstate": CalendarWalkthrough.editorState()
            case "card": CalendarWalkthrough.card(argument)
            default: PerfLog.shared.write("calendar_cmd unknown=\(parts[1])")
            }
        case "ai":
            // ai:status | summary | ask:<Frage> | draft:<Anweisung> | proofread
            // | undo | filter:<Text> | palette:<Text> | settings | state — the
            // M2.3 walkthrough (sandbox only, hook builds only).
            let spec = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            let argument = spec.count > 1 ? spec[1] : ""
            switch spec.first ?? "" {
            case "status": Task { await AIWalkthrough.status() }
            case "summary": Task { await AIWalkthrough.summarize() }
            case "ask": Task { await AIWalkthrough.ask(argument) }
            case "draft": Task { await AIWalkthrough.draft(argument) }
            case "draftwin": Task { await AIWalkthrough.draftWindow(argument) }
            case "accept": Task { await AIWalkthrough.acceptProofread() }
            case "proofread": Task { await AIWalkthrough.proofread() }
            case "undo": Task { await AIWalkthrough.undo() }
            case "filter": Task { await AIWalkthrough.filter(argument) }
            case "palette": Task { await AIWalkthrough.palette(argument) }
            case "settings": AIWalkthrough.settingsPage()
            case "state": AIWalkthrough.state()
            case "stream": AIWalkthrough.stream(argument)
            default: PerfLog.shared.write("ai_cmd unknown=\(parts[1])")
            }
        case "statusprobe":
            // M2.4: a plain AppKit status item next to the SwiftUI one, to tell
            // "the MenuBarExtra scene never ran" from "no status item renders".
            MenuBarProbe.install()
        case "mailto":
            // M2.4: the same parser/composer as `onOpenURL`, without asking
            // LaunchServices which app owns the scheme (it could be the real
            // instance or Tauri).
            // The dispatcher splits at the first ":", so the scheme is gone.
            AIWalkthrough.mailto("mailto:" + parts[1])
        case "mail":
            // mail:code — copy a one-time code; mail:unsubscribe — the ⌘U path
            // for the open/selected thread.
            switch parts[1] {
            case "code":
                AppModel.shared.copyLatestVerificationCode()
                PerfLog.shared.write("mail code requested")
            case "unsubscribe":
                guard let id = AppModel.shared.mailbox.expandedId ?? AppModel.shared.mailbox.selectedId else {
                    PerfLog.shared.write("mail unsubscribe no_thread")
                    return
                }
                AppModel.shared.unsubscribeThread(id)
                PerfLog.shared.write("mail unsubscribe thread=\(id)")
            default:
                PerfLog.shared.write("mail unknown=\(parts[1])")
            }
        case "avatars":
            AIWalkthrough.avatars(parts[1])
        case "window":
            AIWalkthrough.window(parts[1])
        case "reminder":
            AIWalkthrough.reminder()
        case "writegate":
            // writegate:off|on — shows the real instance's read-only state in
            // the sandbox (P2g screenshots). Policy stays keyed on the process
            // identifier, so the sandbox itself keeps writing.
            AppModel.shared.writeAccess.debugPresentAsReal(readOnly: parts[1] == "off")
        case "menu":
            // menu:Postfach — opens a main-menu submenu at a fixed point so a
            // screenshot can show its items (P2g). Dismiss with Escape.
            guard let item = NSApp.mainMenu?.items.first(where: { $0.title == parts[1] }),
                  let submenu = item.submenu,
                  let window = NSApp.windows.first(where: { $0.title == Instance.title }) else {
                PerfLog.shared.write("menu_open missing=\(parts[1])")
                return
            }
            DispatchQueue.main.async {
                PerfLog.shared.write("menu_open title=\(parts[1])")
                submenu.popUp(positioning: nil, at: NSPoint(x: 140, y: window.frame.height - 140),
                              in: window.contentView)
            }
        case "select":
            // M2.5: Mehrfachauswahl (all|down|up|toggle:<id>|range:<id>|none).
            MailWalkthrough.selection(parts[1])
        case "action":
            // M2.5: Gruppenaktionen auf der Auswahl (archive, move:<id>, …).
            MailWalkthrough.action(parts[1])
        case "compose":
            // M2.5: Anhänge, Textbausteine, Zitat, Senden-Varianten.
            MailWalkthrough.compose(parts[1])
        case "preview":
            // M2.5: Quick Look (preview:attachments[:n] | preview:close).
            if parts[1] == "close" { MailWalkthrough.closePreview() }
            else if parts[1] == "index" { MailWalkthrough.previewIndex() }
            else { MailWalkthrough.preview(parts[1]) }
        case "picker":
            // M2.5: Verschieben-/Label-/Split-Popover öffnen oder schließen.
            MailWalkthrough.picker(parts[1])
        case "snippet":
            // M2.5: einen Test-Textbaustein sicherstellen (Sandbox).
            MailWalkthrough.ensureSnippet()
        case "contextmenu":
            // M2.5: das Kontextmenü der Liste für einen Screenshot aufklappen.
            MailWalkthrough.contextMenu()
        case "folders":
            MailWalkthrough.folds()
        case "singles":
            // singles:on|off — derselbe Schreibweg wie der Schalter in den
            // Einstellungen (M2.14). Beleg: mit „off" darf `e` nur Text sein.
            AppModel.shared.settings.set("singleKeyShortcuts", parts.count > 1 && parts[1] != "off")
            PerfLog.shared.write("walkthrough singles on=\(AppModel.shared.settings.singleKeyShortcuts ? 1 : 0)")
        case "actionfail":
            // actionfail:<kind>[:<reason>] — exactly the `action:failed` line the
            // host sends (M2.16), handed to the production `receive` path.
            let args = (parts.count > 1 ? parts[1] : "move").split(separator: ":").map(String.init)
            let kind = args.first ?? "move"
            let reason = args.count > 1 ? args[1] : "source_missing"
            AppModel.shared.receiveDebugEvent(
                "{\"name\":\"action:failed\",\"payload\":{\"actionId\":7,\"kind\":\"\(kind)\",\"reason\":\"\(reason)\",\"error\":\"hook\"}}")
            PerfLog.shared.write("walkthrough actionfail kind=\(kind) reason=\(reason)")
        case "update":
            // M3.2: derselbe Weg wie der Menüpunkt „Nach Updates suchen …".
            // Den Feed gibt in Sandbox/Hook-Builds nur CORAX_UPDATER_TEST_FEED
            // frei (UpdaterPolicy); sonst ist der Updater aus.
            PerfLog.shared.write("walkthrough update check available=\(Updater.shared.available ? 1 : 0) reason=\(Updater.shared.disabledReason ?? "-")")
            Updater.shared.checkForUpdates()
        case "log":
            PerfLog.shared.write("debug_log \(parts[1])")
        case "state":
            let box = AppModel.shared.mailbox
            let w = NSApp.keyWindow ?? NSApp.mainWindow
            PerfLog.shared.write("debug_state view=\(box.view.rawValue) title=\(w?.title ?? "-") key=\(NSApp.keyWindow != nil) active=\(NSApp.isActive) responder=\(String(describing: w?.firstResponder.map { type(of: $0) })) sel=\(box.selectedId ?? -1) seln=\(box.selectedIds.count) targets=\(box.targetIds.count) open=\(box.expandedId ?? -1) threads=\(box.threads.count) compose=\(box.inlineCompose != nil) focus=\(box.expandedId.flatMap { box.details[$0] }.flatMap { box.focusedMessage(in: $0)?.id } ?? -1) vis=\(box.expandedId.flatMap { box.navigator?.visibleDetailRange($0) }.map { "\(Int($0.lowerBound))-\(Int($0.upperBound))" } ?? "-") frames=\(box.messageFrames.sorted { $0.value.minY < $1.value.minY }.map { "\($0.key):\(Int($0.value.minY))-\(Int($0.value.maxY))" }.joined(separator: ",")) toast=\(AppModel.shared.toasts.current?.text ?? "-") writes=\(AppModel.shared.writeAccess.allowed)")
        default:
            break
        }
    }

    /// Das sichtbare Hauptfenster (im Hintergrund-Lauf ohne `keyWindow`).
    private static var mainWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.title == Instance.title }
    }

    /// `hittest:300x20` → (300, 20). Das `x` trennt die Achsen, damit es sich
    /// nicht mit dem Doppelpunkt der Unterbefehle beißt.
    private static func clickPoint(_ parts: [String]) -> (x: Int, y: Int)? {
        guard parts.count > 1 else { return nil }
        let rest = parts.dropFirst().joined(separator: ":")
        let spec = rest.split(separator: "x").compactMap { Int($0) }
        guard spec.count == 2 else { return nil }
        return (spec[0], spec[1])
    }

    /// Posts one key through the app's event queue (`NSApp.postEvent`), which
    /// is what a physical key does before `sendEvent` — monitors included.
    private static func post(key: String) {
        // M2.12: in einem Hintergrund-Lauf (der Nutzer arbeitet) ist die
        // Sandbox-Instanz nicht die aktive App; dann gibt es weder `keyWindow`
        // noch `mainWindow` und der Beleg-Lauf lief stumm ins Leere. Wie
        // `press` auf das sichtbare Hauptfenster zurückfallen.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.title == Instance.title }) else { return }
        let lower = key.lowercased()
        let chars: String = switch lower {
        case "escape": "\u{1b}"
        case "delete": "\u{7f}"
        case "return": "\r"
        default: lower
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCodes[lower] ?? 0)
        else { return }
        NSApp.postEvent(event, atStart: false)
        PerfLog.shared.write("debug_postkey \(lower)")
    }

    private static func press(_ key: String, flags: NSEvent.ModifierFlags, literal: Bool = false) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        let lower = key.lowercased()
        let code = keyCodes[lower] ?? 0
        var chars: String
        switch lower {
        case "return": chars = "\r"
        case "tab": chars = "\t"
        case "space": chars = " "
        case "escape": chars = "\u{1b}"
        case "delete": chars = "\u{7f}"
        case "down": chars = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case "up": chars = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case "pagedown": chars = String(Character(UnicodeScalar(NSPageDownFunctionKey)!))
        case "pageup": chars = String(Character(UnicodeScalar(NSPageUpFunctionKey)!))
        case "home": chars = String(Character(UnicodeScalar(NSHomeFunctionKey)!))
        case "end": chars = String(Character(UnicodeScalar(NSEndFunctionKey)!))
        default: chars = literal ? key : (flags.contains(.shift) ? key.uppercased() : key)
        }
        if key == "?" { chars = "?" }
        if key == "#" { chars = "#" }
        let ignoring = (lower.count == 1) ? lower : chars
        PerfLog.shared.write("debug_press key=\(lower) code=\(code) flags=\(flags.rawValue) "
                             + "window=\(window.windowNumber) key=\(NSApp.keyWindow?.windowNumber ?? -1) "
                             + "responder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) else {
                PerfLog.shared.write("debug_press event_nil type=\(type.rawValue)")
                continue
            }
            // The real route: key equivalents (menu bar) first, then the key window.
            NSApp.sendEvent(event)
        }
    }
}

/// Scrolls the list from top to bottom at a steady speed, one step per display
/// frame, while `FrameMonitor` counts frames over budget (Anforderung 13).
@MainActor
enum ScrollRun {
    private static var timer: Timer?

    static func start(seconds: Double) {
        guard let window = NSApp.windows.first(where: { $0.title == Instance.title }),
              let table = findTable(in: window.contentView) , let scroll = table.enclosingScrollView else {
            PerfLog.shared.write("scrollrun no_table"); return
        }
        if let host = window.contentView { FrameMonitor.shared.attach(to: host) }
        FrameMonitor.shared.reset()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        let started = Date()
        let speed: CGFloat = 1400 // points per second, a brisk trackpad fling
        var last = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                let dy = speed * CGFloat(now.timeIntervalSince(last))
                last = now
                let maxY = table.bounds.height - scroll.contentView.bounds.height
                var origin = scroll.contentView.bounds.origin
                origin.y = min(maxY, origin.y + dy)
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                let done = now.timeIntervalSince(started) > seconds || (origin.y >= maxY - 1 && AppModel.shared.mailbox.isLoading == false && now.timeIntervalSince(started) > 2 && !AppModel.shared.mailbox.hasMore)
                if done {
                    ScrollRun.timer?.invalidate()
                    FrameMonitor.shared.logSummary("scrollrun rows=\(table.numberOfRows) threads=\(AppModel.shared.mailbox.threads.count) secs=\(String(format: "%.1f", now.timeIntervalSince(started)))")
                }
            }
        }
    }

    private static func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = findTable(in: sub) { return t } }
        return nil
    }
}
#else
@MainActor
enum DebugAutomation {
    static var enabled: Bool { false }
    static func install() {}
}
#endif
