import AppKit
import RabeKit
import SwiftUI

extension Notification.Name {
    /// M2.4: menu bar icon or Dock click asks for the main window (it may be
    /// closed; `openWindow` brings it back).
    static let rabeShowMainWindow = Notification.Name("de.streil.rabe.native.showMain")
}

/// SwiftUI entry (replaces the AppKit `main.swift` of P0). The host starts in
/// `init`, before any scene is built (`AppModel.shared`).
@main
struct RabeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model: AppModel

    init() {
        // M2.13 A: ein Hook-Build startet nur in der Sandbox (sonst exit 78).
        StartGuard.enforce()
        model = AppModel.shared
    }

    var body: some Scene {
        Window(Instance.title, id: "main") {
            MainView()
                .modifier(SettingsOpenHook())
                .modifier(WindowOpenHook())
                // M2.4: the bundle registers `mailto:`, so macOS hands a
                // "mailto:…" click to this scene (RFC 6068, parsed in RabeKit).
                .onOpenURL { url in model.composeMailto(url) }
        }
        .defaultSize(width: 1100, height: 780)
        .windowResizability(.contentMinSize)
        .commands { RabeCommands() }

        WindowGroup("Neue E-Mail", id: "compose", for: UUID.self) { $id in
            ComposeWindowView(draftID: id)
        }
        .defaultSize(width: 660, height: 620)

        Settings {
            SettingsView()
        }

        // M2.4: the menu bar icon, Tauri's tray. It shows the unread count of
        // the inbox and offers open, compose and quit; the app keeps running
        // when the window closes.
        // The canonical form (title + SF symbol): a custom `label:` view stayed
        // invisible on macOS 26 (status item 39 pt wide, nothing drawn). The
        // title carries the unread count; the system collapses it to the symbol
        // on a crowded menu bar, and the menu's first line always names the
        // count.
        MenuBarExtra(MenuBarLabel.title, systemImage: MenuBarLabel.symbol) {
            MenuBarMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Opens the Settings scene from code (`SettingsNavigation`). `NSApp`
/// selectors for that are deprecated and unreliable, the environment action is
/// the documented way.
struct SettingsOpenHook: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .rabeOpenSettings)) { _ in
            openSettings()
        }
    }
}

/// M2.4: `openWindow(id:)` only exists in a view, so the scene forwards the
/// "show the main window" request from the menu bar and from the Dock.
struct WindowOpenHook: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .rabeShowMainWindow)) { _ in
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

// MARK: - Menu bar (M2.4, requirement 2)

/// The icon plus the unread count. SwiftUI tracks the `@Observable` store, so
/// the number follows every list refresh.
/// The menu bar title: the unread count when there is one, else the app name.
/// `MenuBarExtra` sizes this text and the symbol itself; a custom `HStack`
/// label measured 0 pt high on macOS 26 and never became visible (M2.4).
/// The menu bar title: the unread count when there is one, else the app name.
@MainActor
enum MenuBarLabel {
    static var count: Int64 { AppModel.shared.unreadBadge }
    static var title: String { count > 0 ? "\(count)" : "Rabe" }
    static var symbol: String { count > 0 ? "envelope.badge" : "envelope" }
}

struct MenuBarMenu: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let count = model.unreadBadge
        Button(count > 0 ? "\(count) ungelesen" : "Keine ungelesenen Mails") {
            NotificationCenter.default.post(name: .rabeShowMainWindow, object: nil)
        }
        .disabled(true)
        Divider()
        Button("Rabe öffnen") {
            NotificationCenter.default.post(name: .rabeShowMainWindow, object: nil)
        }
        Button("Neue E-Mail") {
            NotificationCenter.default.post(name: .rabeShowMainWindow, object: nil)
            ActionDispatcher.perform(.compose)
        }
        Divider()
        Button("Rabe beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Menu bar. Single-key shortcuts are handled by the list (`keyDown`); here
/// they are only shown in the item titles, so typing in a field never triggers them.
struct RabeCommands: Commands {
    private var model: AppModel { AppModel.shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // M2.14 §6: ⌘N heißt je nach Modus „Neue Mail“ oder „Neuer Termin“.
            Button("Neue E-Mail\t C") {
                if model.calendarOpen { ActionDispatcher.perform(.calendarNewEvent) }
                else { ActionDispatcher.perform(.compose) }
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Neue E-Mail im eigenen Fenster\t ⌥C") { ActionDispatcher.perform(.composeInWindow) }
                .keyboardShortcut("c", modifiers: .option)
        }
        CommandMenu("Postfach") {
            // M2.14 §6: ⌘1…⌘9 sind im Mailmodus die Postfächer, im Kalender
            // Tag/Woche/Monat/Jahr/Liste — ein Punkt, der nach Modus verzweigt.
            ForEach(Array(MailView.allCases.enumerated()), id: \.element) { index, view in
                Button(Strings.view(view)) {
                    let modes = CalendarStore.Mode.allCases
                    if model.calendarOpen, index < modes.count {
                        ActionDispatcher.perform(.calendarMode(modes[index]))
                    } else {
                        ActionDispatcher.perform(.view(view))
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("Jetzt synchronisieren\t ⇧⌘N") { ActionDispatcher.perform(.syncNow) }
                .keyboardShortcut("n", modifiers: [.shift, .command])
            Divider()
            Button("Alle Konten") { ActionDispatcher.perform(.account(nil)) }
            ForEach(Array(model.mailbox.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button(account.label) { ActionDispatcher.perform(.account(account.id)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
            Divider()
            Button("Konto hinzufügen …") { ActionDispatcher.perform(.addAccount) }
            Divider()
            Button("Suchen\t ⌥⌘F") { ActionDispatcher.perform(.search) }
                .keyboardShortcut("f", modifiers: [.option, .command])
            Button("Befehlspalette\t ⌘K") { ActionDispatcher.perform(.palette) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            // P2g: no keyboard shortcut (the list owns the plain keys). In the
            // sandbox it is always on and disabled — the sandbox writes freely.
            Toggle("Änderungen erlauben", isOn: Binding(
                get: { model.writeAccess.allowed },
                set: { model.writeAccess.set($0) }
            ))
            .disabled(!model.writeAccess.canToggle)
        }
        CommandMenu("E-Mail") {
            Button("Antworten\t R") { ActionDispatcher.perform(.reply) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Allen antworten\t ⇧R") { ActionDispatcher.perform(.replyAll) }
                .keyboardShortcut("r", modifiers: [.shift, .command])
            Button("Weiterleiten\t F") { ActionDispatcher.perform(.forward) }
                .keyboardShortcut("f", modifiers: [.shift, .command])
            Divider()
            Button("Erledigt\t E") { ActionDispatcher.perform(.archive) }
                .keyboardShortcut("a", modifiers: [.control, .command])
            Button("Zurück in den Posteingang\t ⇧E") { ActionDispatcher.perform(.unarchive) }
                .keyboardShortcut("a", modifiers: [.shift, .control, .command])
            Button("In den Papierkorb\t #") { ActionDispatcher.perform(.trash) }
                .keyboardShortcut(.delete, modifiers: .command)
            Menu("Zurückstellen") {
                Button("Morgen, 8:00\t H") { ActionDispatcher.perform(.snoozeTomorrow) }
                    .keyboardShortcut("h", modifiers: [.control, .command])
                ForEach(Format.snoozePresets()) { preset in
                    Button(preset.name) { ActionDispatcher.perform(.snooze(presetID: preset.id)) }
                }
            }
            Button("Markieren\t S") { ActionDispatcher.perform(.star) }
                .keyboardShortcut("l", modifiers: [.shift, .command])
            Button("Gelesen / ungelesen\t U") { ActionDispatcher.perform(.unread) }
                .keyboardShortcut("u", modifiers: [.shift, .command])
            Button(Strings.loadImages) { ActionDispatcher.perform(.loadImages) }
                .keyboardShortcut("i", modifiers: [.shift, .command])
            Button("Spam / kein Spam\t !") { ActionDispatcher.perform(.spam) }
                .keyboardShortcut("j", modifiers: [.shift, .command])
            Divider()
            Button("Verschieben …\t V") { ActionDispatcher.perform(.move) }
                .keyboardShortcut("m", modifiers: [.control, .command])
            Button("Label …\t L") { ActionDispatcher.perform(.label) }
                .keyboardShortcut("l", modifiers: [.control, .command])
            Divider()
            // M2.4: Tauri's `unsubscribe` and `copy-verification-code`.
            Button("Abmelden\t ⌃⌘U") { ActionDispatcher.perform(.unsubscribe) }
                .keyboardShortcut("u", modifiers: [.control, .command])
            Button("Bestätigungscode kopieren\t ⌥⇧⌘C") { ActionDispatcher.perform(.copyVerificationCode) }
                .keyboardShortcut("c", modifiers: [.option, .shift, .command])
            Divider()
            Button("Ersten Anhang öffnen\t O") { ActionDispatcher.perform(.openAttachment) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Anhänge in Quick Look\t Y") { ActionDispatcher.perform(.previewAttachments) }
                .keyboardShortcut("y", modifiers: .command)
            Divider()
            Button("Rückgängig\t Z") { ActionDispatcher.perform(.undo) }
                .keyboardShortcut("z", modifiers: .command)
        }
        // M2.9 Stufe B: die Tasten des Verfassen-Panels. Als Menüpunkt, damit
        // sie auch aus dem Editor des Panels heraus greifen.
        // Feste Titel ohne `.disabled`: SwiftUI baut Commands beim Start aus und
        // wertet Zustand danach nicht neu aus (im Sandbox-Lauf blieben beide
        // Punkte dauerhaft ausgegraut, `menu … enabled=0`). Was nichts zu tun
        // hat, sagt das beim Klick.
        CommandMenu("Entwurf") {
            Button("Entwurf minimieren / öffnen\t ⇧⌘M") { ActionDispatcher.perform(.toggleDock) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Entwurf verwerfen\t ⇧⌘⌫") { ActionDispatcher.perform(.discardDraft) }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            Divider()
            Button("Nächster Entwurf / Liste\t ⌃Tab") { model.cycleDraftFocus() }
            Button("Neues Verfassen-Fenster\t ⌥C") { ActionDispatcher.perform(.composeInWindow) }
        }
        CommandMenu("Kalender") {
            // M2.14 §6: ⌥⌘2 öffnet den Kalender, ⌥⌘1 geht zurück zur Post.
            // M2.17: fester Titel. SwiftUI baut Commands beim Start aus und
            // wertet den Zustand danach nicht neu aus — „Kalender öffnen" stand
            // auch im Kalender da, obwohl der Punkt ihn schließt.
            Button("Kalender ein/aus\t ⌥⌘2") { ActionDispatcher.perform(.calendarToggle) }
                .keyboardShortcut("2", modifiers: [.option, .command])
            Button("Zurück zum Postfach\t ⌥⌘1") { ActionDispatcher.perform(.calendarClose) }
                .keyboardShortcut("1", modifiers: [.option, .command])
            Divider()
            Button("Heute\t T") { ActionDispatcher.perform(.calendarToday) }
                .keyboardShortcut("t", modifiers: .command)
            Button("Tagesansicht\t D") { ActionDispatcher.perform(.calendarMode(.day)) }
            Button("Wochenansicht\t W") { ActionDispatcher.perform(.calendarMode(.week)) }
            Button("Monatsansicht\t M") { ActionDispatcher.perform(.calendarMode(.month)) }
            Divider()
            Button("Neuer Termin\t B") { ActionDispatcher.perform(.calendarNewEvent) }
            Divider()
            Button("Seitenleiste ein/aus\t \\") {
                ActionDispatcher.perform(.calendarSidebar)
            }
            Button("Nächstem Meeting beitreten\t O") { ActionDispatcher.perform(.joinNextMeeting) }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu("KI") {
            // M2.17: fester Titel; ob geschrieben oder zusammengefasst wird,
            // entscheidet der Aufruf anhand des offenen Entwurfs.
            Button("Mit KI schreiben / zusammenfassen\t ⌥⌘I") {
                ActionDispatcher.perform(.aiWrite)
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
            Button("Korrekturlesen\t ⌥⌘;") { ActionDispatcher.perform(.aiProofread) }
                .keyboardShortcut(";", modifiers: [.option, .command])
            Divider()
            Button("Fragen an das Postfach\t ⇧⌥⌘I") { ActionDispatcher.perform(.aiAsk) }
                .keyboardShortcut("i", modifiers: [.option, .shift, .command])
            Button("KI-Filter für die Suche\t ⌥⌘K") { ActionDispatcher.perform(.aiSearchFilter) }
                .keyboardShortcut("k", modifiers: [.option, .command])
            Divider()
            Button("Intelligenz …") { ActionDispatcher.perform(.aiSettings) }
        }
        CommandMenu("Gehe zu") {
            // M2.18m: Ordner und Labels über ein Suchfeld anspringen.
            Button("Ordner oder Label …\t ⇧⌘O") { ActionDispatcher.perform(.goToPicker) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Thread auf- / zuklappen\t ↵") { ActionDispatcher.perform(.toggle) }
            Button("Weiter\t ↓") { ActionDispatcher.perform(.next) }
            Button("Zurück\t ↑") { ActionDispatcher.perform(.previous) }
            Button("Seite weiter\t Bild↓") { ActionDispatcher.perform(.pageDown) }
            Button("Seite zurück\t Bild↑") { ActionDispatcher.perform(.pageUp) }
            Button("Anfang\t Pos1") { ActionDispatcher.perform(.first) }
            Button("Ende\t Ende") { ActionDispatcher.perform(.last) }
        }
        CommandGroup(after: .sidebar) {
            Button("Seitenleiste ein/aus\t ⌃⌘S") {
                ActionDispatcher.perform(.toggleSidebar)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }
        CommandMenu("Darstellung") {
            ForEach(ThemeID.allCases) { theme in
                Button(theme.title) { ActionDispatcher.perform(.theme(theme)) }
            }
            Divider()
            Button("Leistungs-Overlay") { ActionDispatcher.perform(.perfOverlay) }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Tastenkürzel\t ⌘/") { ActionDispatcher.perform(.shortcuts) }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}
