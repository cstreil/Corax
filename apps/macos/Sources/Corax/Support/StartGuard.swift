import Foundation
import CoraxKit

/// M2.13 §3 Teil A: ein Hook-Build darf nur in der Sandbox laufen.
///
/// Zweimal ist ein Test-Build als echte Instanz gestartet (M2.11, M2.12), weil
/// `open --env` die Umgebung nicht durchreicht und `CORAX_IDENTIFIER` dann leer
/// ist. Dann arbeitet der Build am echten Postfach. Die Sperre greift, bevor
/// `AppModel.shared` den Host startet oder eine Datenbank öffnet.
///
/// M2.13b (W-A): ob dieser Build die Sperre trägt, hängt am Compile-Flag
/// `DEBUG || CORAX_TEST_HOOKS` — nicht am Eintrag `CoraxTestHooks` in der
/// Info.plist. Der Eintrag fehlt bei Debug-Builds und bei einer Binärdatei, die
/// ohne App-Paket direkt gestartet wird; beide liefen sonst ungeprüft an.
///
/// Im Release-Build ist nur `enforce()` ohne Rumpf vorhanden; die Prüfung und
/// der Text stehen nur im Debug- und im Hook-Build.
enum StartGuard {
    /// Reine Funktion für die Tests: ein Hook-Build startet nur mit der
    /// Sandbox-Kennung (`AppIdentity.sandboxID`). Alles andere — leer,
    /// unbekannt, die Kennung der echten Instanz — verweigert den Start.
    static func shouldRefuseStart(hooks: Bool, identifier: String) -> Bool {
        hooks && identifier != Instance.sandbox
    }

    #if DEBUG || CORAX_TEST_HOOKS
    /// Trägt dieser Build die Prüfung? Im Debug- und Hook-Build ja — auch dann,
    /// wenn er ohne App-Paket oder ohne Info.plist-Eintrag gestartet wird.
    static let hooksInThisBuild = true

    /// Beendet den Prozess sofort, wenn ein Hook-Build außerhalb der Sandbox
    /// startet. Die Zeile auf stderr ist der Beleg dieses Wegs.
    static func enforce() {
        let identifier = ProcessInfo.processInfo.environment["CORAX_IDENTIFIER"] ?? ""
        guard shouldRefuseStart(hooks: hooksInThisBuild, identifier: identifier) else { return }
        FileHandle.standardError.write(Data("refusing to start: hook build outside sandbox\n".utf8))
        exit(78)   // EX_CONFIG
    }
    #else
    /// Im Release nichts zu tun — der Build kann gar nicht als Hook-Build laufen.
    static let hooksInThisBuild = false
    static func enforce() {}
    #endif
}
