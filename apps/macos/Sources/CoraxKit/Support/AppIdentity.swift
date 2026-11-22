import Foundation

/// M3.1: **die eine Quelle** für Name und Kennungen der App.
///
/// Korax (ein PGP-Mailclient aus Finnland) und corax.de (ein Hoster) klingen
/// genauso; der Name kann sich deshalb noch ändern. Er steht zusammen mit den
/// Kennungen nur hier, alles andere liest von hier: Fenstertitel, Datenordner,
/// Schlüsselbund-Service, Mitteilungsnamen, Signposter, URL-Schema und
/// `scripts/build-app.sh` (ein Test vergleicht beide Seiten).
///
/// Die alten Kennungen stehen als geordnete Liste darunter — nur die
/// Datenübernahme (`LegacyMigration`) und die Schlüsselbund-Übernahme
/// (`CredentialAdoption`) lesen sie, und zwar **eine** Quelle: die erste, die
/// Daten hat.
public enum AppIdentity {
    public static let displayName = "Corax"

    /// M3.5: die finale Kennung (Domain `coraxapp.com`).
    public static let bundleID = "com.coraxapp.corax"
    public static let sandboxID = "com.coraxapp.corax.sandbox"

    /// Die Tauri-App (Vorgängerin, gleicht dieselben Konten ab) — wird nur
    /// abgefragt, nie angefasst.
    public static let tauriID = "de.streil.rabe"

    /// Die bisherigen Kennungen, **neueste zuerst**:
    /// M3.1–M3.4 lief unter `de.streil.corax`, davor die frühere native Version unter
    /// `de.streil.rabe.native`.
    public static let legacyIDs = ["de.streil.corax", "de.streil.rabe.native"]
    public static let legacySandboxIDs = ["de.streil.corax.sandbox", "de.streil.rabe.native.sandbox"]

    /// Die jüngste Altkennung — bequem für Anzeige und Tests; die Übernahme
    /// arbeitet mit der ganzen Liste.
    public static var legacyID: String { legacyIDs[0] }
    public static var legacySandboxID: String { legacySandboxIDs[0] }

    /// Kennung für die gewählte Instanz.
    public static func identifier(sandbox: Bool) -> String {
        sandbox ? sandboxID : bundleID
    }

    /// Alte Kennungen derselben Instanz, neueste zuerst (Quellen der Übernahme).
    public static func legacyIdentifiers(sandbox: Bool) -> [String] {
        sandbox ? legacySandboxIDs : legacyIDs
    }

    /// Alte Kennung derselben Instanz (die jüngste; Quelle der Übernahme).
    public static func legacyIdentifier(sandbox: Bool) -> String {
        legacyIdentifiers(sandbox: sandbox)[0]
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
