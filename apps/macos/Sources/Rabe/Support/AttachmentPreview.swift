import AppKit
import Darwin
import Quartz
import RabeKit

/// Quick Look for attachments (M2.5, requirement 7): one system preview instead
/// of nine hand-written viewers.
///
/// The file is fetched through the audited `save_attachment` path into an
/// app-owned temp directory (`<tmp>/rabe-preview-<pid>/<id>/<name>`); the whole
/// directory is removed when the app quits, and leftovers of a crash are removed
/// at the next launch. Quick Look itself pages through the staged files with the
/// arrow keys, because the panel asks for one item per index.
@MainActor
final class AttachmentPreview {
    static let shared = AttachmentPreview()

    /// Root of the staged previews: the system temp directory, per process.
    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rabe-preview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    private let source = PreviewSource()
    private var staging = false
    /// Which attachment the panel shows (the arrow keys move it).
    var currentIndex: Int { source.currentIndex }

    /// Deletes staged previews of earlier runs (a crash leaves them behind).
    /// Called once at launch, before any preview exists.
    ///
    /// K2 aus dem Audit M2: the temp directory is shared. Sandbox and release
    /// instance can run at the same time, so only a directory whose process is
    /// gone is stale — otherwise one instance would delete the other's open
    /// preview.
    static func removeStalePreviews() {
        let parent = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for url in entries where url.lastPathComponent.hasPrefix("rabe-preview-") {
            guard url.lastPathComponent != root.lastPathComponent,
                  isStalePreviewDirectory(url.lastPathComponent) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { PerfLog.shared.write("preview_stale_removed n=\(removed)") }
    }

    /// Whether `rabe-preview-<pid>` belongs to a process that no longer runs.
    /// A name without a pid is a leftover of an older format and counts as
    /// stale; a live process (or one of another user, `EPERM`) does not.
    static func isStalePreviewDirectory(_ name: String) -> Bool {
        guard let pid = pid_t(name.dropFirst("rabe-preview-".count)) else { return true }
        if kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }

    /// Removes this run's previews (app quit).
    static func removeAll() { try? FileManager.default.removeItem(at: root) }

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    /// Stages every attachment of the list (so the panel can page through them)
    /// and opens the preview at `startIndex`. `attachments` is in display order;
    /// inline pictures must already be filtered out by the caller.
    func show(attachments: [AttachmentMeta], startAt startIndex: Int, threadId: Int64?) {
        guard !attachments.isEmpty, !staging else { return }
        staging = true
        let box = AppModel.shared.mailbox
        Task {
            defer { staging = false }
            let directory = Self.root
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var staged: [(index: Int, url: URL)] = []
            for (index, attachment) in attachments.enumerated() {
                if let url = await box.stageAttachment(attachment, into: directory) {
                    staged.append((index, url))
                } else {
                    PerfLog.shared.write("preview_skip id=\(attachment.id) name_len=\(attachment.filename?.count ?? 0)")
                }
            }
            guard !staged.isEmpty else {
                AppModel.shared.toasts.show("Anhang konnte nicht geladen werden", isError: true)
                PerfLog.shared.write("preview_failed n=\(attachments.count)")
                return
            }
            source.urls = staged.map(\.url)
            let wanted = staged.firstIndex { $0.index == startIndex } ?? 0
            source.currentIndex = wanted
            PerfLog.shared.write("preview_open n=\(staged.count) start=\(startIndex) thread=\(threadId ?? -1)")
            guard let panel = QLPreviewPanel.shared() else {
                PerfLog.shared.write("preview_panel_missing")
                return
            }
            panel.dataSource = source
            panel.currentPreviewItemIndex = wanted
            panel.reloadData()
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            PerfLog.shared.write("preview_shown visible=\(panel.isVisible ? 1 : 0) index=\(wanted)")
        }
    }

    /// Closes the panel if it is ours (the hook walkthrough uses it; Esc does the same).
    func close() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
        source.urls = []
    }
}

/// Quick Look's data source. The panel calls it on the main thread; the type is
/// not actor-isolated so the Obj-C protocol conformance stays simple, and it owns
/// nothing but the staged URLs handed over by `AttachmentPreview`.
private final class PreviewSource: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    var urls: [URL] = []
    var currentIndex = 0

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem? {
        guard urls.indices.contains(index) else { return nil }
        currentIndex = index
        return urls[index] as NSURL
    }
}
