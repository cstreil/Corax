import AppIntents

/// M3.3: die Sätze, die Siri und die Kurzbefehle-App anbieten. Jeder Satz
/// enthält \(.applicationName) — ohne das nimmt das System ihn nicht an.
public struct CoraxShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: VerificationCodeIntent(),
            phrases: [
                "Bestätigungscode in \(.applicationName)",
                "Hol den Bestätigungscode aus \(.applicationName)",
            ],
            shortTitle: "Bestätigungscode",
            systemImageName: "number.square"
        )
        AppShortcut(
            intent: UnreadCountIntent(),
            phrases: [
                "Wie viele ungelesene Mails in \(.applicationName)",
                "Ungelesene in \(.applicationName)",
            ],
            shortTitle: "Ungelesene",
            systemImageName: "envelope.badge"
        )
        AppShortcut(
            intent: InboxOverviewIntent(),
            phrases: [
                "Überblick in \(.applicationName)",
                "Was ist ungelesen in \(.applicationName)",
            ],
            shortTitle: "Überblick",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: AskMailboxIntent(),
            phrases: [
                "Frag \(.applicationName)",
                "Frag \(.applicationName) nach meinen Mails",
            ],
            shortTitle: "Frag das Postfach",
            systemImageName: "questionmark.bubble"
        )
        AppShortcut(
            intent: ComposeMailIntent(),
            phrases: [
                "Neue Mail in \(.applicationName)",
                "Schreib eine Mail in \(.applicationName)",
            ],
            shortTitle: "Mail verfassen",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SearchMailIntent(),
            phrases: [
                "Such in \(.applicationName)",
                "Suche in \(.applicationName) nach Mails",
            ],
            shortTitle: "In Mails suchen",
            systemImageName: "magnifyingglass"
        )
    }
}
