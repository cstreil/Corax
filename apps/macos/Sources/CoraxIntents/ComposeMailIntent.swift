import AppIntents
import Foundation

/// M3.3: einen Entwurf öffnen. **Sendet nie** — der Nutzer liest und schickt
/// selbst.
struct ComposeMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Mail verfassen"
    static let description = IntentDescription(
        "Öffnet einen neuen Entwurf in Corax. Gesendet wird nichts.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "An")
    var to: String?

    @Parameter(title: "Betreff")
    var subject: String?

    @Parameter(title: "Text")
    var body: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = Date()
        do {
            let dialog = try await IntentLogic.compose(to: to, subject: subject, body: body)
            IntentRun.log("compose_mail", started: started, ok: true)
            return .result(dialog: IntentDialog(stringLiteral: dialog))
        } catch {
            IntentRun.log("compose_mail", started: started, ok: false)
            throw IntentRun.failure(error)
        }
    }
}
