import Foundation

/// M3.2: ob und wogegen der Updater laufen darf — eine Entscheidung ohne
/// AppKit, damit sie prüfbar bleibt.
///
/// Regeln:
/// - Die Sandbox-Instanz (`*.sandbox`) und jeder Hook-Build ziehen **nie** ein
///   echtes Update. Nur ein ausdrücklicher Testschalter auf einen Loopback-Feed
///   schaltet sie frei.
/// - Das Release-Bundle braucht `SUFeedURL` und `SUPublicEDKey`; fehlt eines,
///   bleibt der Updater aus und das Log nennt den Grund.
public enum UpdaterPolicy {
    /// Umgebungsvariable, die in Sandbox/Hook-Builds einen lokalen Test-Feed
    /// freigibt. Nur `127.0.0.1`, `localhost` oder `::1`.
    public static let testFeedVariable = "CORAX_UPDATER_TEST_FEED"
    /// Not-Aus für Tests und den Walkthrough.
    public static let disableVariable = "CORAX_UPDATER_DISABLE"

    public enum Mode: Equatable, Sendable {
        /// Updater bleibt aus; `reason` steht so im Log.
        case disabled(reason: String)
        /// Updater läuft; `testFeed` heißt: der Feed kommt aus dem Testschalter.
        case enabled(feedURL: URL, testFeed: Bool)
    }

    public static func decide(bundleIdentifier: String?,
                              feedURL: String?,
                              publicKey: String?,
                              testHooks: Bool,
                              environment: [String: String]) -> Mode {
        if environment[disableVariable] == "1" {
            return .disabled(reason: "switch_off")
        }

        let testFeed = environment[testFeedVariable]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .flatMap(URL.init(string:))
        let restricted = (bundleIdentifier?.hasSuffix(".sandbox") ?? false) || testHooks

        if restricted {
            // Ein echtes Update aus der Sandbox heraus wäre ein Unfall: nur ein
            // lokaler Feed ist erlaubt, und auch der nur ausdrücklich.
            guard let testFeed else { return .disabled(reason: "sandbox") }
            guard isLoopback(testFeed) else { return .disabled(reason: "test_feed_not_local") }
            return .enabled(feedURL: testFeed, testFeed: true)
        }

        let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return .disabled(reason: "no_public_key") }

        let raw = feedURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, let feed = URL(string: raw),
              let scheme = feed.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return .disabled(reason: "no_feed")
        }
        return .enabled(feedURL: feed, testFeed: false)
    }

    /// Nur der eigene Rechner zählt als Testgeber.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
