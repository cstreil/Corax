import AppKit
import RabeKit
import SwiftUI

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
        }
        .defaultSize(width: 1100, height: 780)
        .windowResizability(.contentMinSize)
        .commands { RabeCommands() }

        WindowGroup("Neue E-Mail", id: "compose", for: UUID.self) { $id in
            ComposeWindowView(draftID: id)
        }
        .defaultSize(width: 620, height: 520)

        Settings {
            SettingsView()
        }
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
            Button("Ersten Anhang öffnen\t O") { ActionDispatcher.perform(.openAttachment) }
                .disabled(model.mailbox.expandedId == nil)
            Divider()
            Button("Rückgängig\t Z") { ActionDispatcher.perform(.undo) }
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
