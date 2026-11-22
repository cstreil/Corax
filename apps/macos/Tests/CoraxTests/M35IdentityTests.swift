import Foundation
import XCTest
@testable import Corax
@testable import CoraxKit

/// M3.5: die finale Kennung `com.coraxapp.corax` und die Übernahme aus zwei
/// Altkennungen.
///
/// Zwei Regeln sind der Kern: Übernommen wird **eine** Quelle (die neueste, die
/// Daten hat), und ein Schlüsselbund-Eintrag kommt aus der ersten Quelle, die
/// ihn hat. Der Rest hält die Kennung an einer Stelle.
final class M35IdentityTests: XCTestCase {
    private let fm = FileManager.default

    private var packageDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CoraxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
    }

    // MARK: Kennung

    func testTheIdentityIsFinal() {
        XCTAssertEqual(AppIdentity.bundleID, "com.coraxapp.corax")
        XCTAssertEqual(AppIdentity.sandboxID, "com.coraxapp.corax.sandbox")
        XCTAssertEqual(AppIdentity.legacyIDs, ["de.streil.corax", "de.streil.rabe.native"],
                       "neueste zuerst — die Reihenfolge entscheidet die Quelle")
        XCTAssertEqual(AppIdentity.legacySandboxIDs,
                       ["de.streil.corax.sandbox", "de.streil.rabe.native.sandbox"])
        XCTAssertEqual(AppIdentity.legacyIdentifiers(sandbox: false), AppIdentity.legacyIDs)
        XCTAssertEqual(AppIdentity.legacyIdentifiers(sandbox: true), AppIdentity.legacySandboxIDs)
        XCTAssertEqual(AppIdentity.legacyID, "de.streil.corax")
        XCTAssertEqual(AppIdentity.legacySandboxID, "de.streil.corax.sandbox")
        XCTAssertEqual(Instance.native, AppIdentity.bundleID)
        XCTAssertEqual(Instance.sandbox, AppIdentity.sandboxID)
        XCTAssertEqual(AppIdentity.tauriID, "de.streil.rabe",
                       "die Tauri-App behält ihre Kennung; sie wird nur abgefragt")
    }

    /// Namen, die aus der Kennung abgeleitet werden, folgen ihr — ein fest
    /// eingetragenes `de.streil.corax` gibt es nicht.
    func testDerivedNamesFollowTheIdentity() {
        XCTAssertEqual(AppIdentity.urlScheme, "com.coraxapp.corax.mailto")
        XCTAssertEqual(AppIdentity.notification("updateReady").rawValue,
                       "com.coraxapp.corax.updateReady")
    }

    /// Das Build-Skript kann Swift nicht lesen; der Test hält beide Seiten
    /// zusammen.
    func testTheBuildScriptUsesTheFinalIdentifier() throws {
        let script = try String(contentsOf: packageDirectory.appendingPathComponent("scripts/build-app.sh"),
                                encoding: .utf8)
        XCTAssertTrue(script.contains("BUNDLE_ID=\"\(AppIdentity.bundleID)\""))
        XCTAssertFalse(script.contains("de.streil.corax"),
                       "die Zwischenkennung gehört nicht mehr ins Build-Skript")
    }

    /// Abnahme: `de.streil.corax` steht nur noch in `AppIdentity` — in Swift-
    /// Quellen und Skripten, als Zeichenkettenliteral. Kommentare mit
    /// Verlaufsangaben sind erlaubt, deshalb wird `"de.streil.corax` gesucht.
    func testTheInterimIdentifierOnlyLivesInAppIdentity() throws {
        var offenders: [String] = []

        let sources = packageDirectory.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(fm.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == "AppIdentity.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("\"de.streil.corax") {
                offenders.append("Sources/\(url.lastPathComponent)")
            }
        }

        let scripts = packageDirectory.appendingPathComponent("scripts")
        for url in try fm.contentsOfDirectory(at: scripts, includingPropertiesForKeys: nil)
        where url.pathExtension == "sh" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("\"de.streil.corax") { offenders.append("scripts/\(url.lastPathComponent)") }
        }

        XCTAssertEqual(offenders, [], "Zwischenkennung außerhalb von AppIdentity gefunden")
    }

    // MARK: Datenübernahme aus zwei Quellen

    private func makeBase() throws -> URL {
        let base = fm.temporaryDirectory.appendingPathComponent("m35-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func layout(_ base: URL, id: String, files: [String: String]) throws {
        let dir = base.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// Übernahme ohne Datenbankkopie, damit die Dateizahl eindeutig bleibt.
    @discardableResult
    private func migrate(_ base: URL,
                         from sources: [String],
                         defaults: UserDefaults? = nil,
                         isRunning: (String) -> Bool = { _ in false }) -> LegacyMigration.Outcome {
        LegacyMigration.runIfNeeded(appSupport: base,
                                    from: sources,
                                    to: "ziel",
                                    isRunning: isRunning,
                                    defaults: defaults,
                                    copyDatabase: { _, _ in })
    }

    func testTheNewestSourceWins() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        try layout(base, id: "neu", files: ["neu.txt": "N"])
        try layout(base, id: "alt", files: ["alt.txt": "A"])

        let outcome = migrate(base, from: ["neu", "alt"])

        XCTAssertEqual(outcome, .migrated(files: 1, bytes: 1))
        let target = base.appendingPathComponent("ziel")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("neu.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("alt.txt").path),
                       "keine Mischung aus beiden Quellen")
        XCTAssertTrue(fm.fileExists(atPath: base.appendingPathComponent("neu/neu.txt").path),
                      "kopiert, nicht verschoben")
    }

    func testTheOlderSourceIsTheFallback() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        try layout(base, id: "alt", files: ["alt.txt": "A"])

        let outcome = migrate(base, from: ["neu", "alt"])

        XCTAssertEqual(outcome, .migrated(files: 1, bytes: 1))
        XCTAssertTrue(fm.fileExists(atPath: base.appendingPathComponent("ziel/alt.txt").path))
    }

    func testWithoutAnySourceNothingMoves() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        XCTAssertEqual(migrate(base, from: ["neu", "alt"]), .notNeeded)
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("ziel").path))
    }

    /// Die ältere Instanz darf den Umzug blockieren, auch wenn die jüngere
    /// Quelle die gewählte ist: sie könnte deren Daten später noch schreiben.
    func testARunningOlderSourceBlocksTheCopy() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        try layout(base, id: "neu", files: ["neu.txt": "N"])
        try layout(base, id: "alt", files: ["alt.txt": "A"])

        let outcome = migrate(base, from: ["neu", "alt"], isRunning: { $0 == "alt" })

        XCTAssertEqual(outcome, .legacyRunning)
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("ziel").path))
    }

    /// Die Einstellungen kommen aus derselben Quelle wie die Daten.
    func testTheDefaultsComeFromTheChosenSource() throws {
        let newer = "m35.defaults.newer.\(UUID().uuidString)"
        let older = "m35.defaults.older.\(UUID().uuidString)"
        let targetID = "m35.defaults.target.\(UUID().uuidString)"
        let newerDefaults = try XCTUnwrap(UserDefaults(suiteName: newer))
        let olderDefaults = try XCTUnwrap(UserDefaults(suiteName: older))
        let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: targetID))
        defer {
            for domain in [newer, older, targetID] { UserDefaults.standard.removePersistentDomain(forName: domain) }
        }
        newerDefaults.set("neu", forKey: "theme")
        olderDefaults.set("alt", forKey: "theme")
        olderDefaults.set(true, forKey: "sidebarVisible")

        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        try layout(base, id: newer, files: ["neu.txt": "N"])
        try layout(base, id: older, files: ["alt.txt": "A"])

        XCTAssertEqual(migrate(base, from: [newer, older], defaults: targetDefaults),
                       .migrated(files: 1, bytes: 1))
        XCTAssertEqual(targetDefaults.string(forKey: "theme"), "neu")
        XCTAssertNil(targetDefaults.object(forKey: "sidebarVisible"),
                     "die ältere Quelle wird nicht dazugemischt")
    }

    // MARK: Schlüsselbund

    /// Je Eintrag gilt die erste Quelle, die ihn hat.
    func testEachEntryComesFromTheFirstSourceThatHasIt() {
        let existing: [String: Set<String>] = [
            "neu": ["1:password", "0:ai_api_key"],
            "alt": ["1:password", "2:caldav_password", "0:mcp_token"],
        ]
        var written: [String: String] = [:]
        var readFrom: [String: String] = [:]

        let result = CredentialAdoption.run(
            from: ["neu", "alt"],
            to: "ziel",
            accounts: [0, 1, 2],
            exists: { service, name in
                if service == "ziel" { return false }
                return existing[service]?.contains(name) ?? false
            },
            read: { service, name in
                readFrom[name] = service
                return "secret-\(service)-\(name)"
            },
            write: { service, name, secret in
                XCTAssertEqual(service, "ziel")
                written[name] = secret
                return true
            })

        XCTAssertEqual(result.adopted, 4)
        XCTAssertEqual(readFrom["1:password"], "neu", "die neuere Quelle gewinnt")
        XCTAssertEqual(readFrom["2:caldav_password"], "alt", "die ältere füllt nur die Lücke")
        XCTAssertEqual(readFrom["0:mcp_token"], "alt")
        XCTAssertEqual(written["1:password"], "secret-neu-1:password")
        XCTAssertEqual(written["0:ai_api_key"], "secret-neu-0:ai_api_key")
    }

    /// Was unter der neuen Kennung schon steht, bleibt stehen.
    func testEntriesAlreadyUnderTheFinalIdentifierAreSkipped() {
        let result = CredentialAdoption.run(
            from: ["neu", "alt"],
            to: "ziel",
            accounts: [1],
            exists: { service, name in
                (service == "ziel" && name == "1:password")
                    || (service == "alt" && name == "1:password")
            },
            read: { _, _ in XCTFail("vorhandene Einträge werden nicht gelesen"); return nil },
            write: { _, _, _ in XCTFail("vorhandene Einträge werden nicht geschrieben"); return false })

        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.adopted, 0)
    }
}
