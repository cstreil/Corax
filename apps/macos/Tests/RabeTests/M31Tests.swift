import Foundation
import SQLite3
import XCTest
@testable import Rabe
@testable import RabeKit

/// M3.1: Umbenennen auf Corax.
///
/// Der Nutzer hat den Namen gesetzt (Korax/corax.de klingen ähnlich, er kann
/// sich also noch ändern). Deshalb steht er an genau einer Stelle im Swift-Code
/// und einmal im Build-Skript — diese Tests halten beide Seiten zusammen.
/// Dazu: die Datenübernahme beim ersten Start (Kopieren, nicht Verschieben,
/// kein halber Zustand) und die Übernahme der Schlüsselbund-Einträge, deren
/// Service die Kennung ist.
final class M31IdentityTests: XCTestCase {
    private let fm = FileManager.default

    private var packageDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RabeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
    }

    // MARK: Identität aus einer Quelle

    func testTheIdentityIsOneValue() {
        XCTAssertEqual(AppIdentity.displayName, "Corax")
        XCTAssertEqual(AppIdentity.bundleID, "de.streil.corax")
        XCTAssertEqual(AppIdentity.sandboxID, "de.streil.corax.sandbox")
        XCTAssertEqual(AppIdentity.legacyID, "de.streil.rabe.native")
        XCTAssertEqual(Instance.native, AppIdentity.bundleID)
        XCTAssertEqual(Instance.sandbox, AppIdentity.sandboxID)
        XCTAssertEqual(AppIdentity.urlScheme, "de.streil.corax.mailto")
        XCTAssertEqual(AppIdentity.identifier(sandbox: false), AppIdentity.bundleID)
        XCTAssertEqual(AppIdentity.identifier(sandbox: true), AppIdentity.sandboxID)
        XCTAssertEqual(AppIdentity.legacyIdentifier(sandbox: true), AppIdentity.legacySandboxID)
        XCTAssertEqual(AppIdentity.tauriID, "de.streil.rabe",
                       "die Tauri-App behält ihre Kennung; sie wird nur abgefragt")
    }

    /// Name und Kennung stehen im Build-Skript ein zweites Mal (das Skript kann
    /// Swift nicht lesen). Dieser Test verhindert, dass beide auseinanderlaufen.
    func testTheBuildScriptUsesTheSameNameAndIdentifier() throws {
        let script = try String(contentsOf: packageDirectory.appendingPathComponent("scripts/build-app.sh"),
                                encoding: .utf8)
        XCTAssertTrue(script.contains("APP_NAME=\"\(AppIdentity.displayName)\""))
        XCTAssertTrue(script.contains("BUNDLE_ID=\"\(AppIdentity.bundleID)\""))
        XCTAssertFalse(script.contains("Rabe Native"),
                       "der alte Bundle-Name darf im Build-Skript nicht mehr auftauchen")
        XCTAssertFalse(script.contains("de.streil.rabe.native"),
                       "die alte Kennung gehört nur noch in AppIdentity und die Übernahme")
    }

    /// Abnahme: die alte Kennung steht nur noch in `AppIdentity` (und in der
    /// Übernahme als Quelle).
    func testTheOldIdentifierOnlyLivesInAppIdentity() throws {
        let sources = packageDirectory.appendingPathComponent("Sources")
        var offenders: [String] = []
        let walker = try XCTUnwrap(fm.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == "AppIdentity.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("de.streil.rabe.native") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "Kennung außerhalb von AppIdentity gefunden")
    }

    // MARK: Datenübernahme

    private func makeLayout(sourceFiles: [String: String]) throws -> (base: URL, source: URL, target: URL) {
        let base = fm.temporaryDirectory.appendingPathComponent("m31-\(UUID().uuidString)")
        let source = base.appendingPathComponent("alt")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, content) in sourceFiles {
            let file = source.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        return (base, source, base.appendingPathComponent("neu"))
    }

    private func run(_ base: URL, source: URL, target: URL,
                     isRunning: Bool = false,
                     copyDatabase: @escaping (URL, URL) throws -> Void = { _, _ in }) -> LegacyMigration.Outcome {
        LegacyMigration.runIfNeeded(appSupport: base,
                                    from: source.lastPathComponent,
                                    to: target.lastPathComponent,
                                    isRunning: { _ in isRunning },
                                    defaults: nil,
                                    copyDatabase: copyDatabase)
    }

    func testNothingToDoWithoutALegacyDirectory() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("m31-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let outcome = LegacyMigration.runIfNeeded(
            appSupport: base, from: "alt", to: "neu", defaults: nil,
            copyDatabase: { _, _ in XCTFail("darf nicht kopieren") })
        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("neu").path))
    }

    func testTheLegacyDirectoryIsCopiedAndTheOriginalStays() throws {
        let (base, source, target) = try makeLayout(sourceFiles: [
            "avatars/a.png": "AA", "logs/rabe-native.log": "log", "instance.lock": "",
            "comail.db": "alt",
        ])
        defer { try? fm.removeItem(at: base) }
        var databaseCopied = false
        let outcome = run(base, source: source, target: target) { _, destination in
            databaseCopied = true
            try "db".write(to: destination, atomically: true, encoding: .utf8)
        }
        // avatars/a.png (2) + logs/rabe-native.log (3) + comail.db aus der
        // Kopierfunktion (2); instance.lock und comail.db kommen nicht roh mit.
        XCTAssertEqual(outcome, .migrated(files: 3, bytes: 7))
        XCTAssertTrue(databaseCopied, "die Datenbank kommt über die Kopierfunktion des Aufrufers")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("comail.db").path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("avatars/a.png").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("instance.lock").path),
                       "die Sperre gehört der alten Instanz")
        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("avatars/a.png").path),
                      "kopiert, nicht verschoben")
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("neu.migrating").path),
                       "kein Zwischenordner bleibt liegen")
    }

    func testARunningLegacyInstanceBlocksTheCopy() throws {
        let (base, source, target) = try makeLayout(sourceFiles: ["avatars/a.png": "AA"])
        defer { try? fm.removeItem(at: base) }
        let outcome = run(base, source: source, target: target, isRunning: true)
        XCTAssertEqual(outcome, .legacyRunning)
        XCTAssertFalse(fm.fileExists(atPath: target.path), "kein halber Zustand")
        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("avatars/a.png").path))
    }

    func testAFailureLeavesNoTargetAndNoStaging() throws {
        let (base, source, target) = try makeLayout(sourceFiles: ["avatars/a.png": "AA", "comail.db": "alt"])
        defer { try? fm.removeItem(at: base) }
        struct Boom: LocalizedError { var errorDescription: String? { "kaputt" } }
        let outcome = run(base, source: source, target: target) { _, _ in throw Boom() }
        guard case .failed(let reason) = outcome else { return XCTFail("erwartet: failed") }
        XCTAssertTrue(reason.contains("kaputt"))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("neu.migrating").path))
    }

    func testATargetWithADatabaseIsNeverOverwritten() throws {
        let (base, source, target) = try makeLayout(sourceFiles: ["avatars/a.png": "AA"])
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "vorhanden".write(to: target.appendingPathComponent("comail.db"), atomically: true, encoding: .utf8)
        let outcome = run(base, source: source, target: target) { _, _ in XCTFail("darf nicht kopieren") }
        XCTAssertEqual(outcome, .notNeeded)
        let kept = try String(contentsOf: target.appendingPathComponent("comail.db"), encoding: .utf8)
        XCTAssertEqual(kept, "vorhanden")
    }

    func testALeftoverStagingDirectoryIsReplaced() throws {
        let (base, source, target) = try makeLayout(sourceFiles: ["avatars/a.png": "AA", "comail.db": "alt"])
        defer { try? fm.removeItem(at: base) }
        let staging = base.appendingPathComponent("neu.migrating")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try "halb".write(to: staging.appendingPathComponent("halb.txt"), atomically: true, encoding: .utf8)
        let outcome = run(base, source: source, target: target) { _, destination in
            try "db".write(to: destination, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(outcome, .migrated(files: 2, bytes: 4))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("halb.txt").path),
                       "der Rest eines früheren Versuchs liegt nicht im Ziel")
    }

    // MARK: UserDefaults

    func testDefaultsAreTakenOverButSandboxAndOwnChoicesStay() throws {
        let from = "de.streil.corax.test.legacy.\(UUID().uuidString)"
        let to = "de.streil.corax.test.target.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: from))
        let target = try XCTUnwrap(UserDefaults(suiteName: to))
        defer {
            legacy.removePersistentDomain(forName: from)
            target.removePersistentDomain(forName: to)
        }
        legacy.set(true, forKey: "sidebarVisible")
        legacy.set(["1|finanzen"], forKey: "foldersExpanded")
        legacy.set(true, forKey: "foldersOpen.sandbox")
        legacy.set("eigene", forKey: "theme")
        target.set("neu", forKey: "theme")

        let copied = LegacyMigration.copyDefaults(from: from, to: target)

        XCTAssertTrue(target.bool(forKey: "sidebarVisible"))
        XCTAssertEqual(target.stringArray(forKey: "foldersExpanded"), ["1|finanzen"])
        XCTAssertNil(target.object(forKey: "foldersOpen.sandbox"), "Sandbox-Schlüssel kommen nicht mit")
        XCTAssertEqual(target.string(forKey: "theme"), "neu", "die eigene Wahl gewinnt")
        XCTAssertGreaterThanOrEqual(copied, 2)
    }

    func testTheWritePermissionFollowsTheNewIdentifier() throws {
        let from = "de.streil.corax.test.legacy.\(UUID().uuidString)"
        let to = "de.streil.corax.test.target.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: from))
        let target = try XCTUnwrap(UserDefaults(suiteName: to))
        defer {
            legacy.removePersistentDomain(forName: from)
            target.removePersistentDomain(forName: to)
        }
        legacy.set(true, forKey: "writesAllowed.\(from)")

        LegacyMigration.copyDefaults(from: from, to: target,
                                     renaming: ["writesAllowed.\(from)": "writesAllowed.\(to)"])

        XCTAssertTrue(target.bool(forKey: "writesAllowed.\(to)"),
                      "sonst startet die neue Kennung wieder im Nur-lesen-Modus")
        XCTAssertNil(target.object(forKey: "writesAllowed.\(from)"), "der alte Schlüssel bleibt nicht liegen")
    }

    // MARK: Übernommene Wahl gilt im ersten Start

    /// `AppModel` legt `SidebarState` als Eigenschaft an, also bevor die
    /// Übernahme läuft; ohne Neuladen zeigte der erste Start die Standardwahl
    /// und die übernommene erst beim zweiten.
    @MainActor
    func testTheMigratedSidebarChoiceAppliesToTheFirstStart() throws {
        let suite = "de.streil.corax.test.sidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SidebarState(defaults: defaults, key: "sidebarVisible")
        XCTAssertTrue(state.userWantsVisible, "ohne gespeicherten Wert steht die Leiste offen")

        defaults.set(false, forKey: "sidebarVisible")
        state.reloadFromDefaults()

        XCTAssertFalse(state.userWantsVisible)
        XCTAssertFalse(state.isVisible, "die übernommene Wahl gilt sofort")
    }

    // MARK: Schlüsselbund — Logik mit eingereichten Zugriffen

    private func adopt(existing: Set<String>,
                       presentInTarget: Set<String> = [],
                       unreadable: Set<String> = [],
                       writable: Bool = true) -> (CredentialAdoption.Result, [String: String]) {
        var written: [String: String] = [:]
        let result = CredentialAdoption.run(
            from: "alt", to: "neu", accounts: [0, 1],
            exists: { service, name in
                service == "alt" ? existing.contains(name) : presentInTarget.contains(name)
            },
            read: { _, name in unreadable.contains(name) ? nil : "secret-\(name)" },
            write: { _, name, secret in
                guard writable else { return false }
                written[name] = secret
                return true
            })
        return (result, written)
    }

    func testOnlyExistingEntriesAreAdopted() {
        let (result, written) = adopt(existing: ["1:password", "0:mcp_token"])
        XCTAssertEqual(result.adopted, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(Set(written.keys), ["1:password", "0:mcp_token"])
        XCTAssertEqual(written["1:password"], "secret-1:password")
    }

    func testEntriesThatAlreadyExistUnderTheNewNameAreSkipped() {
        let (result, written) = adopt(existing: ["1:password"], presentInTarget: ["1:password"])
        XCTAssertEqual(result.adopted, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(written.isEmpty)
    }

    func testAReadOrWriteFailureIsCountedAndDoesNotStopTheRest() {
        let (readFailure, _) = adopt(existing: ["1:password", "0:ai_api_key"], unreadable: ["1:password"])
        XCTAssertEqual(readFailure.adopted, 1)
        XCTAssertEqual(readFailure.failed, 1)

        let (writeFailure, _) = adopt(existing: ["1:password"], writable: false)
        XCTAssertEqual(writeFailure.adopted, 0)
        XCTAssertEqual(writeFailure.failed, 1)
    }

    func testTheAccountListAlwaysStartsWithTheAppWideZero() {
        XCTAssertEqual(CredentialAdoption.accounts(fromIDs: [3, 1, 1]), [0, 1, 3])
        XCTAssertEqual(CredentialAdoption.accounts(fromIDs: []), [0])
        XCTAssertEqual(CredentialAdoption.slots.first, "password")
        XCTAssertTrue(CredentialAdoption.slots.contains("mcp_token"))
    }
}

/// Die Datenbankkopie der Übernahme: konsistent über `VACUUM INTO`, auch mit
/// WAL — ein `cp` der Hauptdatei verlöre die letzten Transaktionen.
final class M31DatabaseCopyTests: XCTestCase {
    func testVacuumIntoCopiesTheLatestState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m31-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("comail.db")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE accounts(id INTEGER PRIMARY KEY); INSERT INTO accounts VALUES (1),(2);",
                                    nil, nil, nil), SQLITE_OK)
        // WAL: die Zeile liegt noch nicht in der Hauptdatei.
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO accounts VALUES (3);", nil, nil, nil), SQLITE_OK)

        let destination = dir.appendingPathComponent("kopie.db")
        try DatabaseCopy.vacuum(from: source, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        var ids: [Int64] = []
        var read: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(destination.path, &read, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let copy = try XCTUnwrap(read)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(copy, "SELECT id FROM accounts ORDER BY id;", -1, &statement, nil), SQLITE_OK)
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
        sqlite3_finalize(statement)
        sqlite3_close(copy)
        sqlite3_close(db)

        XCTAssertEqual(ids, [1, 2, 3], "auch die letzte, noch im WAL liegende Zeile muss mit")
        XCTAssertEqual(DatabaseCopy.accountIDs(in: destination), [1, 2, 3])
    }

    func testTheSourceDatabaseStaysUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m31-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("comail.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE accounts(id INTEGER PRIMARY KEY); INSERT INTO accounts VALUES (7);",
                                    nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try XCTUnwrap(try? Data(contentsOf: source))
        try DatabaseCopy.vacuum(from: source, to: dir.appendingPathComponent("kopie.db"))
        XCTAssertEqual(try Data(contentsOf: source), before, "die Quelle wird nicht verändert")
    }
}
