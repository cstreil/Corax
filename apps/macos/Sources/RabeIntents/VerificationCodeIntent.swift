import AppIntents
import Foundation

/// M3.3: den neuesten Bestätigungscode der letzten 30 Minuten ansagen und
/// optional in die Zwischenablage legen.
struct VerificationCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Bestätigungscode"
    static let description = IntentDescription(
        "Sucht den neuesten Bestätigungscode der letzten 30 Minuten.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "In die Zwischenablage kopieren", default: true)
    var copyToClipboard: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let started = Date()
        do {
            let answer = try await IntentLogic.verificationCode(copy: copyToClipboard)
            IntentRun.log("verification_code", started: started, ok: !answer.value.isEmpty)
            return .result(value: answer.value, dialog: IntentDialog(stringLiteral: answer.dialog))
        } catch {
            IntentRun.log("verification_code", started: started, ok: false)
            throw IntentRun.failure(error)
        }
    }
}
