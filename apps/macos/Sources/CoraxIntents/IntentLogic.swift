import Foundation
import CoraxKit

/// M3.3: die Logik der Intents, getrennt von AppIntents — dieselbe Funktion
/// benutzt `perform()`, und die Tests rufen sie mit einer Attrappe auf.
enum IntentLogic {
    struct Answer: Equatable {
        let value: String
        let dialog: String
    }

    static let codeWindowMinutes = 30
    static let overviewLimit = 6

    /// Bestätigungscode: Treffer ansagen (Ziffern mit Abstand), optional
    /// kopieren; ohne Treffer der Hinweis auf das Zeitfenster.
    static func verificationCode(maxAgeMinutes: Int = codeWindowMinutes,
                                 copy: Bool) async throws -> Answer {
        let host = try await IntentRun.readyHost()
        guard let found = try await host.latestVerificationCode(maxAgeMinutes: maxAgeMinutes) else {
            return Answer(value: "",
                          dialog: IntentText.noCodeLine(minutes: maxAgeMinutes))
        }
        let digits = IntentText.spokenDigits(found.code)
        if copy { await host.copyToClipboard(found.code) }
        return Answer(value: found.code,
                      dialog: IntentText.codeLine(sender: found.sender, digits: digits, copied: copy))
    }

    static func unreadCount() async throws -> (value: Int, dialog: String) {
        let host = try await IntentRun.readyHost()
        let count = try await host.unreadInboxCount()
        return (count, IntentText.unreadLine(count))
    }

    static func overview() async throws -> Answer {
        let host = try await IntentRun.readyHost()
        let total = try await host.unreadInboxCount()
        let threads = total > 0 ? try await host.unreadInboxThreads(limit: overviewLimit) : []
        let lines = threads.map { (sender: IntentRun.sender($0), subject: $0.subject) }
        let text = IntentText.overview(lines, total: total)
        return Answer(value: text, dialog: text)
    }

    static func ask(question: String) async throws -> Answer {
        let host = try await IntentRun.readyHost()
        let answer = IntentText.stripCitations(try await host.ask(question))
        let text = answer.isEmpty ? "Dazu habe ich nichts gefunden." : answer
        return Answer(value: text, dialog: text)
    }

    static func compose(to: String?, subject: String?, body: String?) async throws -> String {
        let host = try await IntentRun.readyHost()
        await host.compose(to: to, subject: subject, body: body)
        return "Entwurf ist offen – du kannst ihn prüfen und senden."
    }

    static func search(_ query: String) async throws -> String {
        let host = try await IntentRun.readyHost()
        await host.search(query)
        return "Ich habe die Suche in Corax gestartet."
    }
}
