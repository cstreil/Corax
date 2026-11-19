import Foundation
import Observation

// MARK: - Toasts (`src/components/common/Toasts.tsx`: one at a time, action button)

@MainActor
@Observable
public final class ToastCenter {
    public struct Toast: Identifiable {
        public let id = UUID()
        public let text: String
        public let actionTitle: String?
        public let action: (@MainActor () -> Void)?
        public let isError: Bool
        /// Runs once when the toast goes away — timeout, dismiss, its own action
        /// or being replaced by the next toast (the undo window ends then).
        let onClose: (@MainActor () -> Void)?
    }

    public private(set) var current: Toast?
    private var hideTask: Task<Void, Never>?

    public init() {}

    /// `action` comes before `onClose`: a trailing closure binds to the first
    /// parameter that takes one, and callers pass the toast's action that way.
    public func show(_ text: String, actionTitle: String? = nil, duration: TimeInterval = 4.2,
              isError: Bool = false, action: (@MainActor () -> Void)? = nil,
              onClose: (@MainActor () -> Void)? = nil) {
        let toast = Toast(text: text, actionTitle: actionTitle, action: action, isError: isError, onClose: onClose)
        let previous = current
        current = toast
        #if DEBUG || RABE_TEST_HOOKS
        PerfLog.shared.write("toast_show text=\(text) action=\(action != nil) onClose=\(onClose != nil)")
        #endif
        previous?.onClose?()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
            #if DEBUG || RABE_TEST_HOOKS
            PerfLog.shared.write("toast_timeout text=\(toast.text)")
            #endif
            toast.onClose?()
        }
    }

    public func error(_ error: Error) {
        show(RabeClientError.from(error).errorDescription ?? "Fehler", isError: true)
    }

    /// The toast's own action (button or `Z`). Returns false when none is shown.
    @discardableResult
    public func runAction() -> Bool {
        guard let toast = current, let action = toast.action else { return false }
        #if DEBUG || RABE_TEST_HOOKS
        PerfLog.shared.write("toast_run_action text=\(toast.text)")
        #endif
        current = nil
        action()
        toast.onClose?()
        return true
    }

    public func dismiss() {
        guard let toast = current else { return }
        current = nil
        toast.onClose?()
    }
}

// MARK: - Settings (read-modify-write on the full object)

@MainActor
@Observable
public final class SettingsStore {
    public private(set) var raw: [String: Any] = [:]
    public private(set) var loaded = false
    public var client: (any MailCore)?
    public weak var toasts: ToastCenter?

    public init() {}

    public var themeID: ThemeID { ThemeID(rawValue: raw["theme"] as? String ?? "system") ?? .system }
    public var accentKey: String { raw["accentColor"] as? String ?? "violet" }
    public var undoSendSeconds: Int { (raw["undoSendSeconds"] as? NSNumber)?.intValue ?? 10 }
    /// `RABE_REMOTE_IMAGES=off` overrides the stored setting for this run only
    /// (nothing is written), so the blocked state can be checked read-only.
    public var loadRemoteImages: Bool {
        #if DEBUG || RABE_TEST_HOOKS
        if ProcessInfo.processInfo.environment["RABE_REMOTE_IMAGES"] == "off" { return false }
        #endif
        return raw["loadRemoteImages"] as? Bool ?? false
    }
    public var notificationsEnabled: Bool { raw["notificationsEnabled"] as? Bool ?? true }
    var inboxDefaultSplits: Bool { raw["inboxDefaultSplits"] as? Bool ?? false }

    public func load() async {
        guard let client else { return }
        do {
            let json = try await client.settingsJSON()
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw RabeClientError.decode(command: "get_settings", detail: "kein Objekt")
            }
            raw = object
            loaded = true
        } catch {
            toasts?.error(error)
        }
    }

    /// A change that is not written yet (N4-Rest).
    private struct Change {
        let value: Any
        /// Value before this change, restored when the write fails.
        let previous: Any?
        /// Distinguishes "still the same change" from a newer one on that key.
        let revision: Int
    }

    private var pending: [String: Change] = [:]
    private var revision = 0
    private var writeChain: Task<Void, Never>?

    /// Changes one field and writes the whole object back. The local value
    /// changes first (the UI reacts at once) and is rolled back on failure.
    /// The object is read again right before writing (N4): `set_settings` takes
    /// all fields, so a stale copy would undo a change the core made meanwhile.
    ///
    /// N4-Rest: writes run one after the other, and each one carries every
    /// change that is still pending. Two quick changes therefore both land
    /// (read, read, write, write used to lose one), and for the same key the
    /// later value wins.
    public func set(_ key: String, _ value: Any) {
        guard loaded, let client else { return }
        revision += 1
        pending[key] = Change(value: value, previous: raw[key], revision: revision)
        raw[key] = value
        let previous = writeChain
        writeChain = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return }
            await self.write(client)
        }
    }

    /// Tests: waits until every queued write has run.
    func waitForPendingWrites() async { await writeChain?.value }

    private func write(_ client: any MailCore) async {
        let batch = pending
        guard !batch.isEmpty else { return }
        do {
            let json = try await client.settingsJSON()
            var fresh = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
            for (key, change) in batch { fresh[key] = change.value }
            let data = try JSONSerialization.data(withJSONObject: fresh)
            try await client.setSettingsJSON(String(decoding: data, as: UTF8.self))
            for (key, change) in batch where pending[key]?.revision == change.revision { pending[key] = nil }
            raw = fresh
            // Changes made while this write ran are still unwritten; keep them
            // visible until the next write carries them.
            for (key, change) in pending { raw[key] = change.value }
        } catch {
            for (key, change) in batch where pending[key]?.revision == change.revision {
                pending[key] = nil
                raw[key] = change.previous
            }
            toasts?.error(error)
        }
    }
}

// MARK: - Sync status for the hint bar

@MainActor
@Observable
public final class SyncStore {
    private(set) var statuses: [SyncStatus] = []
    public private(set) var online = true
    public var client: RabeClient?
    private var refreshTask: Task<Void, Never>?

    public init() {}

    public func setOnline(_ value: Bool) { online = value }

    public func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let client = self.client else { return }
            if let statuses = try? await client.syncStatus() { self.statuses = statuses }
        }
    }

    /// One short line, or nil when everything is idle.
    public var summary: String? {
        if !online || statuses.contains(where: { $0.state == "offline" }) { return Strings.offline }
        if statuses.contains(where: { $0.state == "needs_reauth" }) { return "Konto muss neu verbunden werden" }
        if statuses.contains(where: { $0.state == "error" }) { return "Synchronisierung fehlgeschlagen" }
        if statuses.contains(where: { $0.foregroundPhase == "inbox" || $0.state == "syncing" }) { return "Wird synchronisiert …" }
        if let bg = statuses.compactMap(\.background).first(where: { $0.total > 0 && $0.done < $0.total }) {
            let phase = ["headers": "Kopfzeilen", "content": "Inhalte", "indexing": "Index", "retrying": "Wiederholung"][bg.phase] ?? bg.phase
            return "\(phase) \(bg.done)/\(bg.total)"
        }
        return nil
    }
}

// MARK: - Thread cache (LRU, 50 entries)

@MainActor
final class ThreadCache {
    private var entries: [Int64: ThreadDetail] = [:]
    private var order: [Int64] = []
    private let capacity = 50

    public func get(_ id: Int64) -> ThreadDetail? {
        guard let value = entries[id] else { return nil }
        touch(id)
        return value
    }

    public func put(_ detail: ThreadDetail) {
        entries[detail.thread.id] = detail
        touch(detail.thread.id)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    public func invalidate(_ id: Int64) { entries[id] = nil; order.removeAll { $0 == id } }

    private func touch(_ id: Int64) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}
