import AppIntents
import Foundation

/// M3.3: wie viele ungelesene Mails im Posteingang liegen.
struct UnreadCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Ungelesene Mails"
    static let description = IntentDescription("Wie viele ungelesene Mails im Posteingang liegen.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let started = Date()
        do {
            let answer = try await IntentLogic.unreadCount()
            IntentRun.log("unread_count", started: started, ok: true)
            return .result(value: answer.value, dialog: IntentDialog(stringLiteral: answer.dialog))
        } catch {
            IntentRun.log("unread_count", started: started, ok: false)
            throw IntentRun.failure(error)
        }
    }
}
