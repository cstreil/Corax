import XCTest
@testable import RabeKit

/// M3.2: wann der Updater laufen darf. Die Regel entscheidet, ob eine Instanz
/// überhaupt nach Updates sucht — die Sandbox darf das nie.
final class M32UpdaterTests: XCTestCase {
    private let feed = "https://example.test/appcast.xml"
    private let key = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

    private func decide(bundle: String? = "de.streil.corax",
                        feed: String? = nil,
                        key: String? = nil,
                        hooks: Bool = false,
                        env: [String: String] = [:]) -> UpdaterPolicy.Mode {
        UpdaterPolicy.decide(bundleIdentifier: bundle,
                             feedURL: feed ?? self.feed,
                             publicKey: key ?? self.key,
                             testHooks: hooks,
                             environment: env)
    }

    /// Das Release-Bundle bekommt Feed und Schlüssel aus der Info.plist.
    func testTheReleaseBundleUsesItsFeed() {
        guard case .enabled(let url, let test) = decide() else {
            return XCTFail("Release muss den Updater starten")
        }
        XCTAssertEqual(url.absoluteString, feed)
        XCTAssertFalse(test)
    }

    /// Die Sandbox bleibt aus, auch wenn Feed und Schlüssel im Bundle stehen.
    func testTheSandboxStaysOff() {
        XCTAssertEqual(decide(bundle: "de.streil.corax.sandbox"), .disabled(reason: "sandbox"))
    }

    /// Hook-Builds ebenso — sonst könnte ein Walkthrough ein echtes Update ziehen.
    func testAHookBuildStaysOff() {
        XCTAssertEqual(decide(hooks: true), .disabled(reason: "sandbox"))
    }

    /// Der ausdrückliche Testschalter gilt nur für den eigenen Rechner.
    func testOnlyALoopbackTestFeedIsAllowed() {
        let env = [UpdaterPolicy.testFeedVariable: "http://127.0.0.1:8123/appcast.xml"]
        guard case .enabled(let url, let test) = decide(bundle: "de.streil.corax.sandbox", env: env) else {
            return XCTFail("lokaler Test-Feed muss die Sandbox freigeben")
        }
        XCTAssertTrue(test)
        XCTAssertEqual(url.host, "127.0.0.1")

        let remote = [UpdaterPolicy.testFeedVariable: "https://evil.example/appcast.xml"]
        XCTAssertEqual(decide(bundle: "de.streil.corax.sandbox", env: remote),
                       .disabled(reason: "test_feed_not_local"))
        XCTAssertEqual(decide(hooks: true, env: remote),
                       .disabled(reason: "test_feed_not_local"))
    }

    /// Ohne Schlüssel oder mit kaputtem Feed startet nichts.
    func testMissingKeyOrFeedDisables() {
        XCTAssertEqual(decide(key: ""), .disabled(reason: "no_public_key"))
        XCTAssertEqual(decide(key: "   "), .disabled(reason: "no_public_key"))
        XCTAssertEqual(decide(feed: ""), .disabled(reason: "no_feed"))
        XCTAssertEqual(decide(feed: "kein link"), .disabled(reason: "no_feed"))
        XCTAssertEqual(decide(feed: "ftp://example.test/appcast.xml"), .disabled(reason: "no_feed"))
    }

    /// Der Kippschalter für Tests gewinnt gegen alles.
    func testTheKillSwitchWins() {
        let env = [UpdaterPolicy.disableVariable: "1"]
        XCTAssertEqual(decide(env: env), .disabled(reason: "switch_off"))
        XCTAssertEqual(decide(bundle: "de.streil.corax.sandbox", env: env),
                       .disabled(reason: "switch_off"))
    }

    /// Loopback ist genau der eigene Rechner, nicht „irgendwas mit 127.".
    func testLoopbackIsExact() {
        XCTAssertTrue(UpdaterPolicy.isLoopback(URL(string: "http://127.0.0.1/x")!))
        XCTAssertTrue(UpdaterPolicy.isLoopback(URL(string: "http://localhost:8080/x")!))
        XCTAssertTrue(UpdaterPolicy.isLoopback(URL(string: "http://[::1]:8080/x")!))
        XCTAssertFalse(UpdaterPolicy.isLoopback(URL(string: "http://127.0.0.1.example/x")!))
        XCTAssertFalse(UpdaterPolicy.isLoopback(URL(string: "https://example.test/x")!))
    }
}
