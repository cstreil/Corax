import AppIntents
import Foundation

/// M3.3: eine Frage ans Postfach („Frag das Postfach").
struct AskMailboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Frag das Postfach"
    static let description = IntentDescription(
        "Beantwortet eine Frage zum eigenen Postfach. Kurze Antworten, ohne Quellenmarker.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Frage",
               description: "Zum Beispiel: Wann kommt die Lieferung?",
               requestValueDialog: "Was möchtest du wissen?")
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let started = Date()
        do {
            let answer = try await IntentLogic.ask(question: question)
            IntentRun.log("ask_mailbox", started: started, ok: true)
            return .result(value: answer.value, dialog: IntentDialog(stringLiteral: answer.dialog))
        } catch {
            IntentRun.log("ask_mailbox", started: started, ok: false)
            throw IntentRun.failure(error)
        }
    }
}
