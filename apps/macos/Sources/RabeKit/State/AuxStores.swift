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
    /// Called after a local change became visible (M2.4: the avatar store
    /// follows "Absenderfotos" without polling the settings object).
    public var onLocalChange: (@MainActor (String) -> Void)?

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

    // MARK: M2.1 — general section

    public var language: String { raw["language"] as? String ?? AILanguage.system }

    // MARK: Sprache und KI (M2.8b)

    /// Marks a language that follows the OS language. The core only stores one
    /// field (`language`) and understands concrete codes only, so "system" has
    /// to be resolved to a code there; this flag keeps the picker honest.
    private static let followsSystemKey = "rabe.languageFollowsSystem"

    /// The OS language tag list; a property so the test does not depend on the
    /// host's language.
    public var preferredLanguages: () -> [String] = AILanguage.preferredLanguages

    /// True while the stored language follows the OS language.
    public var languageFollowsSystem: Bool {
        if let flag = UserDefaults.standard.object(forKey: Self.followsSystemKey) as? Bool {
            return flag
        }
        // No flag yet (an install from before M2.8b): "system" means it follows.
        return language == AILanguage.system
    }

    /// What the "Sprache" picker shows: `"system"` while it follows the OS,
    /// otherwise the chosen code.
    public var languageChoice: String {
        languageFollowsSystem ? AILanguage.system : language
    }

    /// Picker change. "System" is stored as the resolved code, so the core can
    /// tell the model which language to answer in.
    public func setLanguage(_ choice: String) {
        UserDefaults.standard.set(choice == AILanguage.system, forKey: Self.followsSystemKey)
        set("language", AILanguage.stored(choice, preferred: preferredLanguages()))
    }

    /// Re-resolves a language that follows the OS. Called after `load()`, so a
    /// macOS language change reaches the core on the next launch.
    public func syncSystemLanguage() {
        guard loaded, languageFollowsSystem else { return }
        // From here on the state is explicit: the stored value is a code now,
        // so the "follows the system" bit has to be remembered separately.
        UserDefaults.standard.set(true, forKey: Self.followsSystemKey)
        let resolved = AILanguage.stored(AILanguage.system, preferred: preferredLanguages())
        guard resolved != language else { return }
        set("language", resolved)
    }
    public var soundEnabled: Bool { raw["soundEnabled"] as? Bool ?? true }
    public var copyVerificationCodes: Bool { raw["copyVerificationCodes"] as? Bool ?? true }
    public var selectAdvance: Bool { raw["selectAdvance"] as? Bool ?? true }
    public var autoAdvance: Bool { raw["autoAdvance"] as? Bool ?? true }
    /// M2.14: Einzeltasten (E, R, #, G …) außerhalb von Textfeldern.
    public var singleKeyShortcuts: Bool { raw["singleKeyShortcuts"] as? Bool ?? true }
    public var dockBadgeEnabled: Bool { raw["dockBadgeEnabled"] as? Bool ?? true }
    /// "classic" (dense rows) or "avatar" (tall rows with sender photos).
    public var inboxUI: String { raw["inboxUi"] as? String ?? "classic" }
    public var showSenderPhotos: Bool { raw["showSenderPhotos"] as? Bool ?? true }
    public var showBundles: Bool { raw["showBundles"] as? Bool ?? true }
    public var groupByDate: Bool { raw["groupByDate"] as? Bool ?? true }
    public var contactSuggestAllAccounts: Bool { raw["contactSuggestAllAccounts"] as? Bool ?? false }
    public var autoLabelsEnabled: Bool { raw["autoLabelsEnabled"] as? Bool ?? true }

    // MARK: M2.2 — Kalender

    /// Erster Tag in Woche und Monat (`"monday"` oder `"sunday"`).
    public var calendarWeekStart: String { raw["calendarWeekStart"] as? String ?? "monday" }
    /// Minuten vor einem Termin für die Desktop-Erinnerung; 0 schaltet sie ab.
    public var meetingNotifyLeadMinutes: Int { (raw["meetingNotifyLeadMinutes"] as? NSNumber)?.intValue ?? 10 }

    // MARK: M2.1 — MCP server settings

    public var mcpEnabled: Bool { raw["mcpEnabled"] as? Bool ?? false }
    public var mcpPort: Int { (raw["mcpPort"] as? NSNumber)?.intValue ?? 47823 }
    public var mcpAllowDrafts: Bool { raw["mcpAllowDrafts"] as? Bool ?? true }
    public var mcpAllowSend: Bool { raw["mcpAllowSend"] as? Bool ?? false }
    public var mcpAllowActions: Bool { raw["mcpAllowActions"] as? Bool ?? false }
    public var mcpAllowPermanentDelete: Bool { raw["mcpAllowPermanentDelete"] as? Bool ?? false }
    public var mcpInstructions: String { raw["mcpInstructions"] as? String ?? "" }

    // MARK: M2.3 — KI

    public var aiBaseUrl: String { raw["aiBaseUrl"] as? String ?? "" }
    public var aiModel: String { raw["aiModel"] as? String ?? "" }
    public var aiQuickReplies: Bool { raw["aiQuickReplies"] as? Bool ?? false }
    /// AI drafts follow the learned style profile.
    public var voiceDrafting: Bool { raw["voiceDrafting"] as? Bool ?? false }
    public var voiceProfile: String { raw["voiceProfile"] as? String ?? "" }
    public var embeddingBackend: String { raw["embeddingBackend"] as? String ?? "local" }
    /// "off" | "openrouter" | "openai" | "commandcode" | "custom".
    public var decisionProvider: String { raw["decisionProvider"] as? String ?? "off" }
    public var decisionModel: String { raw["decisionModel"] as? String ?? "" }
    public var decisionChatFallback: Bool { raw["decisionChatFallback"] as? Bool ?? false }
    public var decisionUseRules: Bool { raw["decisionUseRules"] as? Bool ?? false }

    // MARK: M2.1 — signatures (part of the settings object)

    public var signatures: [Signature] { decoded("signatureList", as: [Signature].self) ?? [] }
    public var signatureDefaults: [String: SignatureDefaults] {
        decoded("signatureDefaults", as: [String: SignatureDefaults].self) ?? [:]
    }

    public func signatures(for accountId: Int64) -> [Signature] {
        signatures.filter { $0.accountId == accountId }
    }

    public func signatureDefaults(for accountId: Int64) -> SignatureDefaults {
        signatureDefaults[String(accountId)] ?? SignatureDefaults()
    }

    /// Adds or replaces one signature (by id).
    public func upsertSignature(_ signature: Signature) {
        var list = signatures
        if let index = list.firstIndex(where: { $0.id == signature.id }) {
            list[index] = signature
        } else {
            list.append(signature)
        }
        setJSON("signatureList", list)
    }

    /// Removes a signature; a default that pointed at it becomes "none".
    public func removeSignature(id: String) {
        var list = signatures
        guard let removed = list.first(where: { $0.id == id }) else { return }
        list.removeAll { $0.id == id }
        setJSON("signatureList", list)

        var defaults = signatureDefaults
        let key = String(removed.accountId)
        if var entry = defaults[key] {
            if entry.newId == id { entry.newId = nil }
            if entry.replyId == id { entry.replyId = nil }
            if entry.isEmpty { defaults[key] = nil } else { defaults[key] = entry }
            setJSON("signatureDefaults", defaults)
        }
    }

    public func setSignatureDefaults(accountId: Int64, newId: String?, replyId: String?) {
        var defaults = signatureDefaults
        let key = String(accountId)
        let entry = SignatureDefaults(newId: newId, replyId: replyId)
        if entry.isEmpty { defaults[key] = nil } else { defaults[key] = entry }
        setJSON("signatureDefaults", defaults)
    }

    // MARK: M2.1 — categories (guidance for the auto-label classifier)

    public var aiCategoryDescriptions: [String: String] {
        (raw["aiCategoryDescriptions"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    }

    public func categoryDescription(for keyword: String) -> String {
        aiCategoryDescriptions[keyword] ?? ""
    }

    /// Sets (or clears) the model guidance of one category, keyed by the label's
    /// IMAP keyword.
    public func setCategoryDescription(_ keyword: String, _ text: String) {
        var map = aiCategoryDescriptions
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map[keyword] = nil } else { map[keyword] = trimmed }
        setJSON("aiCategoryDescriptions", map)
    }

    /// Decodes a settings value that is a nested JSON object/array.
    private func decoded<T: Decodable>(_ key: String, as: T.Type) -> T? {
        guard let value = raw[key], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Writes a Codable value through the normal read-modify-write path (N4).
    func setJSON<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return }
        set(key, object)
    }

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
        onLocalChange?(key)
        let previous = writeChain
        writeChain = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return }
            await self.write(client)
        }
    }

    /// Tests: waits until every queued write has run.
    public func waitForPendingWrites() async { await writeChain?.value }

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
    public private(set) var statuses: [SyncStatus] = []
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
