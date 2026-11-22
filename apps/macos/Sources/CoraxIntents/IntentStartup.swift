import AppIntents
import Foundation

/// M3.3: was beim Start einmal laufen muss, damit Siri und die Kurzbefehle-App
/// die Aktionen kennen.
public enum IntentStartup {
    /// Registriert die Sitzung und meldet die Sätze beim System neu an.
    ///
    /// Apple: „To register the App Shortcut with the system, the app calls
    /// `updateAppShortcutParameters()` on its `AppShortcutsProvider` during the
    /// `init` of the `App` structure." Ohne den Aufruf zieht das System die
    /// Sätze nicht nach — bei einer von Hand kopierten App (kein Installer,
    /// kein App Store) bleiben sie sonst ganz aus.
    ///
    /// Erst die Sitzung, dann die Meldung: startet das System die App für einen
    /// Intent, findet der Intent den Host schon vor.
    public static func install(host: any IntentHost,
                               updateShortcuts: () -> Void = { CoraxShortcuts.updateAppShortcutParameters() }) {
        IntentDependencies.register(host)
        updateShortcuts()
    }
}
