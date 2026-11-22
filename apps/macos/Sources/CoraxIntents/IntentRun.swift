import Foundation
import CoraxKit

/// M3.3: gemeinsamer Ablauf der Intents — Sitzung holen, auf Bereitschaft
/// warten, Laufzeit protokollieren. Die Logzeile enthält nur Name, Dauer und
/// Erfolg; Code, Frage und Antwort stehen nie im Log.
enum IntentRun {
    static func host() throws -> any IntentHost {
        guard let host = IntentDependencies.host else { throw IntentFailure.notReady }
        return host
    }

    /// Startet das System die App für einen Intent, ist die Sitzung noch nicht
    /// bereit; dann warten wir bis zu 10 s.
    static func readyHost() async throws -> any IntentHost {
        let host = try host()
        guard await host.waitUntilReady(timeout: .seconds(10)) else { throw IntentFailure.notReady }
        return host
    }

    static func log(_ name: String, started: Date, ok: Bool) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        PerfLog.shared.write("intent run name=\(name) ms=\(ms) ok=\(ok ? 1 : 0)")
    }

    /// Alle Absender eines Threads, erster zuerst.
    static func sender(_ thread: ThreadSummary) -> String {
        if let first = thread.participants.first {
            return IntentText.sender(of: first.name, email: first.email)
        }
        return IntentText.sender(of: nil, email: thread.accountEmail)
    }
}

extension IntentRun {
    /// Was als Dialog ankommt: bekannte Fälle bleiben, alles andere wird zu
    /// einer verständlichen Meldung — nie ein roher Host- oder Rust-Text.
    static func failure(_ error: Error) -> any Error {
        if let failure = error as? IntentFailure { return failure }
        return IntentFailure.core
    }
}
