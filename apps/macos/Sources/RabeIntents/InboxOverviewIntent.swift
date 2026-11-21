import AppIntents
import Foundation

/// M3.3: kurzer Überblick über die ungelesenen Mails im Posteingang.
struct InboxOverviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Überblick"
    static let description = IntentDescription(
        "Sagt, was ungelesen im Posteingang liegt — höchstens sechs Mails.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let started = Date()
        do {
            let answer = try await IntentLogic.overview()
            IntentRun.log("inbox_overview", started: started, ok: true)
            return .result(value: answer.value, dialog: IntentDialog(stringLiteral: answer.dialog))
        } catch {
            IntentRun.log("inbox_overview", started: started, ok: false)
            throw IntentRun.failure(error)
        }
    }
}
