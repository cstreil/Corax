import AppKit
import Foundation
import RabeKit

// M2.5 walkthrough commands. Compiled only into debug builds or hook builds
// (`RABE_TEST_HOOKS=1`), and only reachable with `RABE_DEBUG_AUTOMATION=1`.
#if DEBUG || RABE_TEST_HOOKS

/// The M2.5 half of `DebugAutomation`: multi-selection, the group actions, the
/// composer functions and Quick Look, all through the same store methods the UI
/// calls. Nothing here is reachable in a release build.
@MainActor
enum MailWalkthrough {
    /// `select:all|down|up|toggle:<id>|range:<id>|none|state`
    static func selection(_ spec: String) {
        let box = AppModel.shared.mailbox
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "all": box.selectAllVisible()
        case "down": box.extendSelection(1)
        case "up": box.extendSelection(-1)
        case "none": box.collapseSelection()
        case "toggle":
            if parts.count > 1, let id = Int64(parts[1]) { box.toggleSelect(id) }
        case "range":
            if parts.count > 1, let id = Int64(parts[1]) { box.selectRange(id, additive: true) }
        default: break
        }
        state()
    }

    /// `action:archive|trash|unarchive|spam|notspam|star|read|unread|undo|sync|relabel|viewfrom|split|delete`
    /// `action:move:<folderId>` · `action:label:<labelId>:on|off` · `action:snooze:<presetId>`
    static func action(_ spec: String) {
        let model = AppModel.shared
        let box = model.mailbox
        let parts = spec.split(separator: ":").map(String.init)
        switch parts[0] {
        case "archive": box.archive()
        case "trash": box.trash()
        case "unarchive": box.unarchive()
        case "spam": box.spam()
        case "notspam": box.notSpam()
        case "star": box.toggleStar()
        case "read": if box.targetIds.contains(where: { box.thread($0)?.isUnread == true }) { box.toggleUnread() }
        case "unread": box.toggleUnread()
        case "undo": box.undo()
        case "sync": box.syncNow()
        case "relabel": model.runRelabelAutoLabels()
        case "viewfrom": model.viewFromSender()
        case "split": model.openSplitPopover()
        case "delete": model.confirmPermanentDelete()
        case "delete-confirm":
            let ids = model.permanentDeleteIds
            model.permanentDeleteOpen = false
            box.deletePermanently(ids: ids)
        case "move":
            guard parts.count > 1, let folderId = Int64(parts[1]),
                  let folder = box.folders.first(where: { $0.id == folderId }) else {
                PerfLog.shared.write("hook_action missing_folder \(spec)")
                return
            }
            box.moveToFolder(folder)
        case "label":
            guard parts.count > 2, let labelId = Int64(parts[1]) else {
                PerfLog.shared.write("hook_action missing_label \(spec)")
                return
            }
            box.setLabel(labelId, applied: parts[2] == "on")
        case "snooze":
            let preset = parts.count > 1 ? parts[1] : "tomorrow"
            if let found = Format.snoozePresets().first(where: { $0.id == preset }) {
                box.snooze(until: found.at, label: "Zurückgestellt: \(found.name)")
            }
        default:
            PerfLog.shared.write("hook_action unknown \(parts[0])")
        }
    }

    /// `compose:attach:<path>` · `compose:attachmany:<p1>|<p2>` · `compose:snippet:<name>`
    /// `compose:quote:<text>` · `compose:sendlater:<date>`
    static func compose(_ spec: String) {
        let model = AppModel.shared
        guard let draft = model.mailbox.inlineCompose ?? model.composeDrafts.values.first else {
            PerfLog.shared.write("hook_compose no_draft")
            return
        }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "attach":
            let added = draft.addAttachments(paths: [argument])
            PerfLog.shared.write("attach_result added=\(added) total=\(draft.attachments.count) bytes=\(draft.attachmentsBytes)")
        case "attachmany":
            let added = draft.addAttachments(paths: argument.split(separator: "|").map(String.init))
            PerfLog.shared.write("attach_result added=\(added) total=\(draft.attachments.count) bytes=\(draft.attachmentsBytes)")
        case "detach":
            if let last = draft.attachments.last { draft.removeAttachment(last) }
            PerfLog.shared.write("attach_removed total=\(draft.attachments.count)")
        case "snippet":
            guard let snippet = model.snippets.items.first(where: { $0.name == argument }) else {
                PerfLog.shared.write("snippet_missing \(argument)")
                return
            }
            draft.insertSnippet(snippet)
            PerfLog.shared.write("snippet_inserted name=\(snippet.name) chars=\(draft.body.count)")
        case "quote":
            draft.insertQuote(argument)
            PerfLog.shared.write("quote_inserted chars=\(argument.count) body=\(draft.body.count)")
        case "sendlater":
            guard let ms = Double(argument) else { return }
            draft.send(variant: .later(Date(timeIntervalSince1970: ms / 1000)),
                       onSent: { PerfLog.shared.write("sendlater_sent") }, onUndo: { _ in })
        case "senddone":
            model.composeCommand("send_done")
        case "instant":
            model.composeCommand("instant_send")
        default:
            // M2.6: the rich-text, link, image and mention steps live in the
            // open composer (it owns the editor), so they are posted there.
            NotificationCenter.default.post(name: .rabeComposeAction, object: spec)
            PerfLog.shared.write("compose_forwarded cmd=\(parts[0])")
        }
    }

    /// `snippet:ensure` — makes sure one test snippet exists (sandbox only), so
    /// the snippet picker and `compose:snippet` have something to show.
    static func ensureSnippet() {
        let model = AppModel.shared
        Task {
            await model.snippets.load()
            if model.snippets.items.isEmpty {
                let ok = await model.snippets.save(SnippetInput(id: nil, name: "M2.5 Zusage",
                                                                shortcut: "zus",
                                                                subject: "Termin bestätigt",
                                                                bodyText: "Gerne, der Termin passt mir."))
                PerfLog.shared.write("snippet_ensure created=\(ok != nil ? 1 : 0)")
            } else {
                PerfLog.shared.write("snippet_ensure existing=\(model.snippets.items.count)")
            }
        }
    }

    /// `contextmenu` — opens the thread context menu at a fixed point, so the
    /// screenshot shows the items and their key hints.
    static func contextMenu() {
        let box = AppModel.shared.mailbox
        guard let window = NSApp.windows.first(where: { $0.title == Instance.title }) else { return }
        let menu = ThreadContextMenu.build(forThreads: box.targetIds, view: box.view)
        PerfLog.shared.write("contextmenu_open targets=\(box.targetIds.count) items=\(menu.items.count)")
        DispatchQueue.main.async {
            // `popUp` runs the menu's own tracking loop and does not return until
            // it closes, and main-queue blocks are not serviced while it tracks —
            // a hook could not close it. A timer in `.common` mode fires inside
            // the tracking loop, so the menu closes itself after 2,5 s.
            let closer = Timer(timeInterval: 2.5, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(closer, forMode: .common)
            menu.popUp(positioning: nil, at: NSPoint(x: 320, y: window.frame.height - 220), in: window.contentView)
        }
    }

    /// `preview:attachments[:index]` — Quick Look for the open thread.
    static func preview(_ spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        AppModel.shared.previewAttachments(startAt: index)
        let box = AppModel.shared.mailbox
        let count = box.expandedId.flatMap { box.details[$0] }
            .map { $0.messages.flatMap(\.attachments).filter { !$0.isInline }.count } ?? 0
        PerfLog.shared.write("preview_request index=\(index) attachments=\(count)")
        // Quick Look stages asynchronously; report the outcome a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            PerfLog.shared.write("preview_state visible=\(AttachmentPreview.shared.isVisible ? 1 : 0)")
        }
    }

    /// `preview:index` — which attachment the Quick Look panel shows (the arrow
    /// keys inside the panel move it, `QLPreviewPanel` asks the data source).
    static func previewIndex() {
        PerfLog.shared.write("preview_index visible=\(AttachmentPreview.shared.isVisible ? 1 : 0) "
                             + "index=\(AttachmentPreview.shared.currentIndex)")
    }

    /// `preview:close`
    static func closePreview() {
        AttachmentPreview.shared.close()
        PerfLog.shared.write("preview_state visible=\(AttachmentPreview.shared.isVisible ? 1 : 0)")
    }

    /// `picker:move` · `picker:label` · `picker:split` — opens the popover so a
    /// screenshot can show it (the picks themselves go through `action:`).
    static func picker(_ name: String) {
        let model = AppModel.shared
        switch name {
        case "move": model.openMovePopover()
        case "label": model.openLabelPopover()
        case "split": model.openSplitPopover()
        case "close":
            model.moveOpen = false
            model.labelOpen = false
            model.splitOpen = false
            model.permanentDeleteOpen = false
            model.mailbox.focusList()
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let box = model.mailbox
            // M2.8a: where the focus landed — the live test found it in the
            // list search after `V`.
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
            // The placeholder says *which* field: the picker's or the list search.
            let field = (window?.firstResponder as? NSTextView)?.delegate as? NSTextField
            let placeholder = field?.placeholderString ?? "-"
            PerfLog.shared.write("picker_state move=\(model.moveOpen ? 1 : 0) label=\(model.labelOpen ? 1 : 0) "
                                 + "split=\(model.splitOpen ? 1 : 0) delete=\(model.permanentDeleteOpen ? 1 : 0) "
                                 + "folders=\(box.folders.count) focus=\(responder) field=\(placeholder)")
        }
    }

    /// One log line with everything the selection tests need to see.
    static func state() {
        let box = AppModel.shared.mailbox
        let ids: String = box.selectedIds.sorted().map { String($0) }.joined(separator: ",")
        let targets: String = box.targetIds.map { String($0) }.joined(separator: ",")
        let cursor: Int64 = box.selectedId ?? -1
        let anchor: Int64 = box.selectAnchorId ?? -1
        let count: Int = box.selectedIds.count
        let targetCount: Int = box.targetIds.count
        let toast: String = AppModel.shared.toasts.current?.text ?? "-"
        PerfLog.shared.write("selection_state sel=\(count) ids=\(ids) cursor=\(cursor) anchor=\(anchor) "
                             + "targets=\(targetCount) targetIds=\(targets) toast=\(toast)")
    }

    /// The write the last group action produced, read back from the core log:
    /// used by the walkthrough to prove "the action hit exactly these ids".
    static func folds() {
        let box = AppModel.shared.mailbox
        Task {
            await box.loadFolders()
            foldsNow()
        }
    }

    private static func foldsNow() {
        let box = AppModel.shared.mailbox
        for folder in box.folders {
            let role: String = folder.role ?? "-"
            let name: String = box.folderName(folder)
            let id: Int64 = folder.id
            PerfLog.shared.write("folder id=" + String(id) + " role=" + role + " name=" + name)
        }
        PerfLog.shared.write("folders total=" + String(box.folders.count))
    }
}

#endif
