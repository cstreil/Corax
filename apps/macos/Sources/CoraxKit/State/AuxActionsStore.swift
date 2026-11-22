import Foundation
import Observation

/// The two small mail actions of M2.4 that reach into the world outside the
/// list: copying a one-time code and unsubscribing from a newsletter.
///
/// Both tell the truth about what happened — "Abgemeldet" is only claimed when
/// the server confirmed a one-click POST or the mailto request was sent; a link
/// for the browser is offered as a toast action instead. Logic lives here so a
/// test drives it against `FakeCore` without network.
@MainActor
@Observable
public final class AuxActionsStore {
    public var client: (any MailCore)?
    public private(set) var toasts: ToastCenter
    /// Puts text on the clipboard; the Mac side hands it to `PlatformServices`.
    public var copyToClipboard: (@MainActor (String) -> Void)?
    /// Opens a URL in the browser (`needsBrowser` outcome only).
    public var openURL: (@MainActor (URL) -> Void)?

    /// The last code found, for tests and the debug log.
    public private(set) var lastVerificationCode: VerificationCode?
    /// The last unsubscribe answer, for tests and the debug log.
    public private(set) var lastUnsubscribeOutcome: UnsubscribeOutcome?

    public init(toasts: ToastCenter = ToastCenter()) {
        self.toasts = toasts
    }

    /// The app hands the shared toast center over later (it owns the order of
    /// initialization); tests pass theirs to `init`.
    public func use(_ toasts: ToastCenter) { self.toasts = toasts }

    /// "Bestätigungscode kopieren" (Tauri's `copy-verification-code`).
    /// The automatic copy when a code arrives is the host's job, governed by
    /// the `copyVerificationCodes` setting.
    @discardableResult
    public func copyVerificationCode(maxAgeMinutes: Int = 30) async -> Bool {
        guard let client else { return false }
        do {
            guard let found = try await client.latestVerificationCode(maxAgeMinutes: maxAgeMinutes) else {
                lastVerificationCode = nil
                toasts.show("Kein Bestätigungscode gefunden")
                return false
            }
            lastVerificationCode = found
            copyToClipboard?(found.code)
            toasts.show("Code \(found.code) von \(found.sender) kopiert")
            return true
        } catch {
            toasts.error(error)
            return false
        }
    }

    /// "Abmelden" (`⌘U`): resolve the thread's unsubscribe message, then **ask**
    /// before anything leaves the app (K3 aus dem Audit M2). The core acts on
    /// one click — a one-click POST to the sender or a request mail — and that
    /// cannot be taken back.
    public func unsubscribe(threadId: Int64, sender: String? = nil) async {
        guard let client else { return }
        do {
            guard let messageId = try await client.threadUnsubscribeMessage(threadId: threadId) else {
                toasts.show("Diese Mail bietet keine Abmeldung")
                return
            }
            let who = sender?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = who.isEmpty
                ? "Von diesem Newsletter abmelden?"
                : "Von \(who) abmelden?"
            toasts.show(text, actionTitle: "Abmelden", duration: 8) { [weak self] in
                guard let self else { return }
                Task { await self.performUnsubscribe(messageId: messageId) }
            }
            PerfLog.shared.write("unsubscribe_ask message=\(messageId)")
        } catch {
            toasts.error(error)
        }
    }

    /// The step the confirmation starts: calls `unsubscribe_message` and reports
    /// only what really happened.
    @discardableResult
    public func performUnsubscribe(messageId: Int64) async -> UnsubscribeOutcome? {
        guard let client else { return nil }
        do {
            let outcome = try await client.unsubscribeMessage(messageId: messageId)
            lastUnsubscribeOutcome = outcome
            switch outcome {
            case .oneClick:
                toasts.show("Abgemeldet")
            case .mailtoSent:
                toasts.show("Abmeldung per E-Mail angefragt")
            case .needsBrowser(let url):
                toasts.show("Abmeldung im Browser bestätigen", actionTitle: "Öffnen") { [openURL] in
                    // K3: the link comes from a foreign mail header; only a web
                    // address goes to the browser (the core filters too).
                    guard let target = URL(string: url), SafeLink.isOpenable(target) else { return }
                    openURL?(target)
                }
            }
            return outcome
        } catch {
            toasts.error(error)
            return nil
        }
    }
}
