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
            Button("Neue E-Mail\t C") { ActionDispatcher.perform(.compose) }
        }
        CommandMenu("Postfach") {
            ForEach(MailView.allCases) { view in
                Button(Strings.view(view)) { ActionDispatcher.perform(.view(view)) }
            }
            Divider()
            Button("Alle Konten") { ActionDispatcher.perform(.account(nil)) }
            ForEach(Array(model.mailbox.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button(account.label) { ActionDispatcher.perform(.account(account.id)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
            Divider()
            Button("Konto hinzufügen …") { ActionDispatcher.perform(.addAccount) }
            Divider()
            Button("Suchen\t /") { ActionDispatcher.perform(.search) }
            Button("Befehlspalette") { ActionDispatcher.perform(.palette) }.keyboardShortcut("k", modifiers: .command)
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
            Button("Antworten\t A") { ActionDispatcher.perform(.reply) }
            Button("Allen antworten\t ⇧A") { ActionDispatcher.perform(.replyAll) }
            Button("Weiterleiten\t W") { ActionDispatcher.perform(.forward) }
            Divider()
            Button("Erledigt\t E") { ActionDispatcher.perform(.archive) }
            Button("In den Papierkorb\t #") { ActionDispatcher.perform(.trash) }
            Menu("Zurückstellen") {
                Button("Morgen, 8:00\t H") { ActionDispatcher.perform(.snoozeTomorrow) }
                ForEach(Format.snoozePresets()) { preset in
                    Button(preset.name) { ActionDispatcher.perform(.snooze(presetID: preset.id)) }
                }
            }
            Button("Markieren\t S") { ActionDispatcher.perform(.star) }
            Button("Gelesen / ungelesen\t U") { ActionDispatcher.perform(.unread) }
            Button(Strings.loadImages) { ActionDispatcher.perform(.loadImages) }
            Divider()
            // M2.4: Tauri's `unsubscribe` (⌘U) and `copy-verification-code`.
            Button("Abmelden\t ⌘U") { ActionDispatcher.perform(.unsubscribe) }
                .keyboardShortcut("u", modifiers: .command)
            Button("Bestätigungscode kopieren") { ActionDispatcher.perform(.copyVerificationCode) }
            Divider()
            Button("Ersten Anhang öffnen\t O") { ActionDispatcher.perform(.openAttachment) }
                .disabled(model.mailbox.expandedId == nil)
            Divider()
            Button("Rückgängig\t Z") { ActionDispatcher.perform(.undo) }
        }
        CommandMenu("Kalender") {
            Button(model.calendarOpen ? "Kalender schließen\t 2" : "Kalender öffnen\t 2") {
                ActionDispatcher.perform(.calendarToggle)
            }
            Button("Zurück zum Postfach\t 1") { ActionDispatcher.perform(.calendarClose) }
                .disabled(!model.calendarOpen)
            Divider()
            Button("Heute\t T") { ActionDispatcher.perform(.calendarToday) }
            Button("Tagesansicht\t D") { ActionDispatcher.perform(.calendarMode(.day)) }
            Button("Wochenansicht\t W") { ActionDispatcher.perform(.calendarMode(.week)) }
            Button("Monatsansicht\t M") { ActionDispatcher.perform(.calendarMode(.month)) }
            Divider()
            Button("Neuer Termin\t B") { ActionDispatcher.perform(.calendarNewEvent) }
            Divider()
            Button(model.calendar.sidebarVisible ? "Seitenleiste ausblenden\t \\" : "Seitenleiste einblenden\t \\") {
                ActionDispatcher.perform(.calendarSidebar)
            }
            Button("Nächstem Meeting beitreten") { ActionDispatcher.perform(.joinNextMeeting) }
        }
        CommandMenu("KI") {
            Button(model.mailbox.inlineCompose != nil || !model.composeDrafts.isEmpty
                   ? "Mit KI schreiben\t ⌘J" : "Zusammenfassen\t ⌘J") {
                ActionDispatcher.perform(.aiWrite)
            }
            .keyboardShortcut("j", modifiers: .command)
            Button("Korrekturlesen\t ⌘⇧P") { ActionDispatcher.perform(.aiProofread) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Fragen an das Postfach\t ⌘⇧K") { ActionDispatcher.perform(.aiAsk) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("KI-Filter für die Suche\t ⌘O") { ActionDispatcher.perform(.aiSearchFilter) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Intelligenz …") { ActionDispatcher.perform(.aiSettings) }
        }
        CommandMenu("Gehe zu") {
            Button("Thread auf- / zuklappen\t ↵") { ActionDispatcher.perform(.toggle) }
            Button("Weiter\t ↓") { ActionDispatcher.perform(.next) }
            Button("Zurück\t ↑") { ActionDispatcher.perform(.previous) }
            Button("Seite weiter\t Bild↓") { ActionDispatcher.perform(.pageDown) }
            Button("Seite zurück\t Bild↑") { ActionDispatcher.perform(.pageUp) }
            Button("Anfang\t Pos1") { ActionDispatcher.perform(.first) }
            Button("Ende\t Ende") { ActionDispatcher.perform(.last) }
        }
        CommandMenu("Darstellung") {
            ForEach(ThemeID.allCases) { theme in
                Button(theme.title) { ActionDispatcher.perform(.theme(theme)) }
            }
            Divider()
            Button("Leistungs-Overlay") { ActionDispatcher.perform(.perfOverlay) }.keyboardShortcut("p", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Tastenkürzel\t ?") { ActionDispatcher.perform(.shortcuts) }
        }
    }
}
