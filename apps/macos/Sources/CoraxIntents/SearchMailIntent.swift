import AppIntents
import Foundation

/// M3.3: die Suche in der App starten.
struct SearchMailIntent: AppIntent {
    static let title: LocalizedStringResource = "In Mails suchen"
    static let description = IntentDescription("Sucht in Corax nach Mails und zeigt die Treffer.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Suchbegriff",
               requestValueDialog: "Wonach soll ich suchen?")
    var query: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = Date()
        do {
            let dialog = try await IntentLogic.search(query)
            IntentRun.log("search_mail", started: started, ok: true)
            return .result(dialog: IntentDialog(stringLiteral: dialog))
        } catch {
            IntentRun.log("search_mail", started: started, ok: false)
            throw IntentRun.failure(error)
        }
    }
}
