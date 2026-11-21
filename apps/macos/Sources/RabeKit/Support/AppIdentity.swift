import Foundation

/// M3.1: **die eine Quelle** für Name und Kennungen der App.
///
/// Korax (ein PGP-Mailclient aus Finnland) und corax.de (ein Hoster) klingen
/// genauso; der Name kann sich deshalb noch ändern. Er steht zusammen mit den
/// Kennungen nur hier, alles andere liest von hier: Fenstertitel, Datenordner,
/// Schlüsselbund-Service, Mitteilungsnamen, Signposter, URL-Schema und
/// `scripts/build-app.sh` (ein Test vergleicht beide Seiten).
///
/// Die alten Kennungen bleiben als `legacyID`/`legacySandboxID` stehen — nur
/// die Datenübernahme (`LegacyMigration`) und die Schlüsselbund-Übernahme
/// (`CredentialAdoption`) lesen sie.
public enum AppIdentity {
    public static let displayName = "Corax"
    public static let bundleID = "de.streil.corax"
    public static let sandboxID = "de.streil.corax.sandbox"

    /// Die Tauri-App (Vorgängerin, gleicht dieselben Konten ab) — wird nur
    /// abgefragt, nie angefasst.
    public static let tauriID = "de.streil.rabe"

    /// Bis M2.18o: `Rabe Native.app` mit dieser Kennung.
    public static let legacyID = "de.streil.rabe.native"
    public static let legacySandboxID = "de.streil.rabe.native.sandbox"

    /// Kennung für die gewählte Instanz.
    public static func identifier(sandbox: Bool) -> String {
        sandbox ? sandboxID : bundleID
    }

    /// Alte Kennung derselben Instanz (Quelle der Übernahme).
    public static func legacyIdentifier(sandbox: Bool) -> String {
        sandbox ? legacySandboxID : legacyID
    }

    /// Die Kennung dieses Prozesses.
    public static var current: String { identifier(sandbox: Instance.isSandbox) }

    /// Fenstertitel; der Zusatz trennt die Sandbox vom echten Postfach.
    public static var windowTitle: String {
        Instance.isSandbox ? "\(displayName) (Sandbox)" : displayName
    }

    /// `mailto:`-Schema des Bundles.
    public static var urlScheme: String { bundleID + ".mailto" }

    /// Prozessweite Mitteilung, an die Kennung gebunden (Sandbox und echte
    /// Instanz teilen nicht mehr denselben Namen).
    public static func notification(_ suffix: String) -> Notification.Name {
        Notification.Name(current + "." + suffix)
    }
}
