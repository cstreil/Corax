import Foundation
import RabeKit

/// M3.3: was die Intents von der App brauchen — absichtlich schmal und ohne
/// AppKit, damit `RabeIntents` unverändert nach `rabe-app` wandern kann.
public protocol IntentHost: Sendable {
    /// Wartet, bis die Sitzung steht (Host gestartet, Liste geladen).
    func waitUntilReady(timeout: Duration) async -> Bool
    func latestVerificationCode(maxAgeMinutes: Int) async throws -> VerificationCode?
    func copyToClipboard(_ text: String) async
    func unreadInboxCount() async throws -> Int
    /// Ungelesene Threads des Posteingangs, höchstens `limit`.
    func unreadInboxThreads(limit: Int) async throws -> [ThreadSummary]
    /// Antwort ohne Quellenmarker.
    func ask(_ question: String) async throws -> String
    @MainActor func compose(to: String?, subject: String?, body: String?)
    @MainActor func search(_ query: String)
}

/// Fehler, die als deutscher Dialog beim Nutzer ankommen. Bewusst kein roher
/// Host- oder Rust-Text.
public enum IntentFailure: LocalizedError {
    case notReady
    case aiNotConfigured
    case aiUnavailable
    case core

    public var errorDescription: String? {
        switch self {
        case .notReady: "Corax startet noch – bitte gleich noch einmal."
        case .aiNotConfigured: "KI ist nicht eingerichtet (Einstellungen → Intelligenz)."
        case .aiUnavailable: "Die KI konnte die Frage gerade nicht beantworten."
        case .core: "Das hat nicht geklappt. Bitte in Corax noch einmal versuchen."
        }
    }
}

/// Wo die App ihre Implementierung ablegt.
///
/// Warum ein eigener Zugang statt `AppDependencyManager`: der verwaltet
/// Abhängigkeiten für *Instanzen* von `AppIntent` und wird über `@Dependency`
/// im jeweiligen Intent aufgelöst — hier laufen alle Intents aber gegen genau
/// eine Sitzung, und die Tests ersetzen sie durch eine Attrappe. Ein
/// statischer Zugang mit Sperre ist dafür kleiner, deterministisch und vor
/// dem ersten Intent setzbar.
public enum IntentDependencies {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: (any IntentHost)?

    public static func register(_ host: any IntentHost) {
        lock.lock()
        defer { lock.unlock() }
        stored = host
    }

    public static var host: (any IntentHost)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Nur für Tests.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}
