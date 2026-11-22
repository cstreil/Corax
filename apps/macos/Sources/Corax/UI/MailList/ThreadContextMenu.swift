import AppKit
import CoraxKit

/// Right-click menu on a thread row (M2.5, `ThreadContextMenu` in Tauri): the
/// same verbs and the same key hints as the list keys, so nothing needs
/// remembering twice.
///
/// The menu acts on the rows the click landed on: a row that is part of the
/// multi-selection keeps the whole selection, a row outside it becomes the
/// target itself (Tauri's rule). One undo toast per action, as with the keys.
@MainActor
enum ThreadContextMenu {
    /// An item that runs a closure; AppKit needs a target/action, not a block.
    final class Item: NSMenuItem {
        private let handler: () -> Void

        init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [],
             enabled: Bool = true, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: key)
            self.target = self
            self.isEnabled = enabled
            keyEquivalentModifierMask = modifiers
        }

        required init(coder: NSCoder) { fatalError("nicht aus einer Datei") }

        @objc private func run() { handler() }
    }

    /// A separator (`NSMenuItem.separator()` returns a plain item).
    static var separator: NSMenuItem { .separator() }

    static func build(forThreads ids: [Int64], view: MailView) -> NSMenu {
        let model = AppModel.shared
        let box = model.mailbox
        let menu = NSMenu()
        menu.autoenablesItems = false
        let single = ids.count == 1
        let inTrash = view == .trash

        if single, let id = ids.first {
            menu.addItem(Item("Öffnen", key: "\r") { box.toggle(id) })
            menu.addItem(separator)
        }

        let first = ids.first.flatMap { box.thread($0) }
        let unread = first?.isUnread ?? false
        let starred = first?.isStarred ?? false
        let title = ids.count > 1 ? "\(ids.count) Threads" : nil

        menu.addItem(Item(unread ? "Als gelesen markieren" : "Als ungelesen markieren", key: "u") { box.toggleUnread() })
        menu.addItem(Item(starred ? "Markierung entfernen" : "Markieren", key: "s") { box.toggleStar() })
        menu.addItem(separator)
        if view == .done {
            menu.addItem(Item("Zurück in den Posteingang", key: "e", modifiers: .shift) { box.unarchive() })
        } else {
            menu.addItem(Item("Erledigt", key: "e") { box.archive() })
        }
        menu.addItem(Item("Später (morgen 8:00)", key: "h") { box.snooze() })
        menu.addItem(Item("Verschieben …", key: "v") { model.openMovePopover() })
        menu.addItem(Item("Label …", key: "l") { model.openLabelPopover() })
        menu.addItem(separator)
        menu.addItem(Item(inTrash ? "Endgültig löschen …" : "In den Papierkorb", key: "#") {
            if inTrash { model.confirmPermanentDelete() } else { box.trash() }
        })
        menu.addItem(Item(view == .spam ? "Kein Spam" : "Als Spam markieren", key: "!") { box.spam() })
        menu.addItem(separator)
        menu.addItem(Item("Alle von diesem Absender", key: "") { model.viewFromSender() })
        menu.addItem(Item("Split nach Absender …", key: "") { model.openSplitPopover() })
        if let title {
            // The count is the menu's own first line (Tauri labels its toast so).
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.insertItem(header, at: 0)
            menu.insertItem(separator, at: 1)
        }
        return menu
    }
}
