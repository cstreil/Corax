import AppKit
import Foundation
import Observation
import RabeKit
import UserNotifications

/// Root of the app state. Created once, as early as possible: `init` starts the
/// host before any UI is built (the host sets environment variables while it
/// starts, which must happen before other threads exist).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let identifier: String?
    /// P2g: the one write gate, shared by menu, status line, client and stores.
    let writeAccess: WriteAccess
    private(set) var client: RabeClient?
    let bridge: DelegateBridge
    private(set) var startError: String?
    private(set) var coreReady = false

    /// The Mac side of `PlatformServices` (M2.0): created here and handed to
    /// the bridge and the store, so `RabeKit` needs no AppKit and no globals.
    let platform = MacPlatformServices()

    let toasts = ToastCenter()
    let settings = SettingsStore()
    let sync = SyncStore()
    let mailbox: MailboxStore

    // UI state shared by window, menus and the palette
    var systemDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    var paletteOpen = false
    var shortcutsOpen = false
    var accountSheetOpen = false
    var perfOverlay = false
    var searchFocusRequest = 0
    var composeDrafts: [UUID: ComposeDraft] = [:]
    var openComposeWindow: ((UUID) -> Void)?

    var theme: Theme { Theme.resolve(settings.themeID, systemDark: systemDark, accentKey: settings.accentKey) }

    /// R6: the list gets the keyboard once per launch; the search field only via
    /// `/` or a click.
    private var focusDone = false
    private var focusRetryScheduled = false

    private init() {
        PerfLog.shared.configureDefault(identifier: (try? Instance.selected()) ?? Instance.native)
        PerfLog.shared.markStartNow()
        PerfLog.shared.write("phase model_init ms=\(PerfLog.shared.elapsedMilliseconds)")

        // The gate first: `shared` is built lazily here, so its initial state
        // lands in the log file `PerfLog` just configured.
        writeAccess = .shared
        mailbox = MailboxStore(toasts: toasts, settings: settings, writeAccess: writeAccess, platform: platform)
        settings.toasts = toasts
        // A refused core command becomes a toast; installed once, before the
        // first command (P2f: the client layer refuses what is not on the list).
        RabeClient.onRefused = { text in
            Task { @MainActor in AppModel.shared.toasts.show(text, isError: true) }
        }
        bridge = DelegateBridge(
            platform: platform,
            onEventJSON: { json in Task { @MainActor in AppModel.shared.receive(json) } },
            onRefused: { url in Task { @MainActor in AppModel.shared.toasts.show(Strings.errorText(.core(code: "url_refused", message: url)), isError: true) } },
            onComposeMailto: { url in Task { @MainActor in AppModel.shared.composeMailto(url) } }
        )

        do {
            identifier = try Instance.selected()
        } catch {
            identifier = nil
            startError = error.localizedDescription
            PerfLog.shared.write("identifier_refused \(error.localizedDescription)")
            return
        }
        do {
            let client = try RabeClient.start(identifier: identifier!, delegate: bridge)
            self.client = client
            mailbox.client = client
            settings.client = client
            sync.client = client
            PerfLog.shared.configure(dataDirectory: client.dataDirectory)
            PerfLog.shared.write("host_started ms=\(PerfLog.shared.elapsedMilliseconds) instance=\(identifier!)")
        } catch {
            startError = RabeClientError.from(error).errorDescription
            PerfLog.shared.write("host_failed \(error.localizedDescription)")
        }
    }

    /// After the window is up: wait for the core, then load settings and list.
    func start() async {
        guard let client, !coreReady else { return }
        do {
            try await client.waitReady()
            coreReady = true
            PerfLog.shared.write("host_ready ms=\(PerfLog.shared.elapsedMilliseconds)")
            await settings.load()
            await mailbox.bootstrap()
            sync.refreshSoon()
            if mailbox.accounts.isEmpty { accountSheetOpen = true }
            focusListAtLaunch(reason: "start")
        } catch {
            startError = RabeClientError.from(error).errorDescription
        }
    }

    func shutdown() {
        client?.shutdown()
        PerfLog.shared.write("host_shutdown")
    }

    private func receive(_ json: String) {
        guard let event = EventRouter.parse(json) else { return }
        switch event {
        case .ready(let ms):
            PerfLog.shared.write("event host:ready coreStartMs=\(Int(ms))")
        case .failed(let code, let message):
            startError = Strings.errorText(.core(code: code, message: message))
        case .mailUpdated(let ids), .mailNew(_, let ids):
            mailbox.mailUpdated(ids)
        case .syncProgress:
            sync.refreshSoon()
        case .networkState(let online):
            sync.setOnline(online)
        case .other:
            break
        }
    }

    // MARK: Notifications

    /// R6: after `host:ready` and the first list the table takes the keyboard.
    /// SwiftUI puts the search field first responder while the window becomes
    /// key, so the request is repeated twice shortly after — only while the
    /// search field is still empty and no text field has the focus by a click.
    func focusListAtLaunch(reason: String) {
        guard !accountSheetOpen, !paletteOpen, mailbox.searchQuery == nil, mailbox.searchText.isEmpty else { return }
        focusDone = true
        mailbox.focusList()
        PerfLog.shared.write("focus_list reason=\(reason)")
        guard !focusRetryScheduled else { return }
        focusRetryScheduled = true
        for delay in [0.5, 1.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.mailbox.searchQuery == nil, self.mailbox.searchText.isEmpty,
                      let window = NSApp.keyWindow, window.title == Instance.title,
                      !(window.firstResponder is MailTableView) else { return }
                self.mailbox.focusList()
                PerfLog.shared.write("focus_list reason=retry")
            }
        }
    }

    /// N3: a permission revoked in System Settings is noticed on the next
    /// activation (the host would otherwise retry every 5 minutes).
    func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [bridge] settings in
            let allowed = settings.authorizationStatus != .denied
            bridge.setNotificationsAllowed(allowed)
            PerfLog.shared.write("notification_status status=\(settings.authorizationStatus.rawValue) allowed=\(allowed)")
        }
    }

    func didBecomeActive() {
        refreshNotificationPermission()
        guard !focusDone else { return }
        focusListAtLaunch(reason: "activate")
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [bridge] granted, _ in
            center.getNotificationSettings { settings in
                bridge.setNotificationsAllowed(settings.authorizationStatus != .denied)
                PerfLog.shared.write("notification_permission granted=\(granted) status=\(settings.authorizationStatus.rawValue)")
            }
        }
    }

    func openThreadFromNotification(_ threadId: Int64) {
        NSApp.activate()
        if mailbox.index(of: threadId) != nil {
            mailbox.select(threadId)
            mailbox.expand(threadId)
        } else {
            mailbox.setView(.inbox)
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                if mailbox.index(of: threadId) != nil { mailbox.select(threadId); mailbox.expand(threadId) }
            }
        }
    }

    // MARK: Compose

    var selfEmails: Set<String> { Set(mailbox.accounts.map { $0.email.lowercased() }) }

    func composeNew(to: [Address] = [], subject: String = "", body: String = "") {
        guard let client else { return }
        guard let account = mailbox.accounts.first(where: { $0.id == mailbox.accountId }) ?? mailbox.accounts.first else {
            accountSheetOpen = true; return
        }
        let draft = ComposeDraft(mode: .new, accountId: account.id, inReplyTo: nil, to: to, cc: [], subject: subject,
                                 body: body, client: client, toasts: toasts, settings: settings)
        composeDrafts[draft.id] = draft
        openComposeWindow?(draft.id)
    }

    func composeMailto(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let address = components?.path ?? ""
        let items = components?.queryItems ?? []
        composeNew(to: address.isEmpty ? [] : [Address(name: nil, email: address)],
                   subject: items.first { $0.name.lowercased() == "subject" }?.value ?? "",
                   body: items.first { $0.name.lowercased() == "body" }?.value ?? "")
    }

    /// `Esc` in the inline draft (TASTATUR.md): discard at once, no question;
    /// the toast restores text and draft.
    func discardInlineDraft() {
        guard let draft = mailbox.inlineCompose else { return }
        let threadId = mailbox.expandedId
        let hadContent = !draft.isEmpty
        draft.discard()
        mailbox.inlineCompose = nil
        mailbox.focusList()
        guard hadContent else { return }
        toasts.show("Entwurf verworfen", actionTitle: Strings.undo, action: { [weak self] in
            guard let self else { return }
            if let threadId, self.mailbox.expandedId != threadId { self.mailbox.expand(threadId) }
            self.mailbox.inlineCompose = draft.restoredCopy()
        })
    }

    /// `A`/`⇧A`/`W` (`R`/`⇧R`/`F`): inline under the expanded thread, on the
    /// focused message (state B) or the newest one (state A).
    func reply(_ mode: ComposeMode) {
        guard let client, let id = mailbox.selectedId else { return }
        let wasOpen = mailbox.expandedId == id
        let open = {
            guard let detail = self.mailbox.details[id] else { return }
            let target = wasOpen ? self.mailbox.focusedMessage(in: detail)?.id : nil
            let draft = ComposeDraft.reply(mode: mode, to: detail, messageId: target, selfEmails: self.selfEmails, client: client,
                                           toasts: self.toasts, settings: self.settings)
            self.mailbox.inlineCompose = draft
        }
        if mailbox.expandedId != id { mailbox.expand(id) }
        if mailbox.details[id] != nil {
            open()
        } else {
            Task {
                for _ in 0..<40 where mailbox.details[id] == nil { try? await Task.sleep(for: .milliseconds(25)) }
                open()
            }
        }
    }
}
