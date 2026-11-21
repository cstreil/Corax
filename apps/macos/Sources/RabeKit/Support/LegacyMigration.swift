import Foundation

/// M3.1: beim ersten Start die Daten der bisherigen Instanz übernehmen.
///
/// Die App heißt jetzt anders (`AppIdentity.bundleID`), also zeigt auch ihr
/// Datenordner auf ein neues Verzeichnis. Beim ersten Start wird der alte
/// Ordner **kopiert, nicht verschoben**: die alte Instanz bleibt vollständig
/// und damit ein Rückweg möglich.
///
/// Kein halber Zustand: alles wird zuerst nach `<ziel>.migrating` geschrieben
/// und erst danach als Ganzes umbenannt. Scheitert etwas, verschwindet der
/// Zwischenordner und das Ziel bleibt unberührt — der nächste Start versucht es
/// erneut.
///
/// Die Datenbank kommt nicht als Dateikopie (bei WAL fehlten sonst die letzten
/// Transaktionen), sondern über den Aufrufer: die App nutzt SQLite
/// (`VACUUM INTO`), Tests reichen eine eigene Funktion herein.
public struct LegacyMigration {
    public enum Outcome: Equatable, Sendable {
        case notNeeded
        case migrated(files: Int, bytes: Int64)
        case legacyRunning
        case failed(String)
    }

    /// `~/Library/Application Support`.
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Was in den neuen Ordner **nicht** mitkommt: die Sperre und der lebende
    /// Datenbankzustand (die DB schreibt `copyDatabase`, WAL und SHM gehören
    /// ihr).
    static let excludedNames: Set<String> = [
        "instance.lock", "comail.db", "comail.db-wal", "comail.db-shm",
    ]

    public static func runIfNeeded(appSupport: URL = applicationSupport,
                                   from: String,
                                   to: String,
                                   isRunning: (String) -> Bool = { _ in false },
                                   defaults: UserDefaults? = nil,
                                   copyDatabase: (URL, URL) throws -> Void) -> Outcome {
        let fm = FileManager.default
        let source = appSupport.appendingPathComponent(from, isDirectory: true)
        let target = appSupport.appendingPathComponent(to, isDirectory: true)
        let staging = appSupport.appendingPathComponent(to + ".migrating", isDirectory: true)
        let started = Date()

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            PerfLog.shared.write("migration_skipped reason=no_legacy from=\(from)")
            return .notNeeded
        }
        // Schon eine Datenbank im Ziel: die Übernahme ist gelaufen (oder das
        // Ziel ist bewusst frisch). Nie über eine Datenbank kopieren.
        if fm.fileExists(atPath: target.appendingPathComponent("comail.db").path) {
            PerfLog.shared.write("migration_skipped reason=target_has_db to=\(to)")
            return .notNeeded
        }
        guard !isRunning(from) else {
            PerfLog.shared.write("migration_skipped reason=legacy_running id=\(from)")
            return .legacyRunning
        }

        do {
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            // Alles außer der lebenden Datenbank, rekursiv.
            for entry in try fm.contentsOfDirectory(at: source,
                                                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
                let name = entry.lastPathComponent
                if excludedNames.contains(name) { continue }
                try fm.copyItem(at: entry, to: staging.appendingPathComponent(name))
            }

            let database = source.appendingPathComponent("comail.db")
            if fm.fileExists(atPath: database.path) {
                try copyDatabase(database, staging.appendingPathComponent("comail.db"))
            }

            var copiedDefaults = 0
            if let defaults {
                // Die Schreibfreigabe hängt an der Kennung; sie zieht mit, sonst
                // startete die neue Instanz wieder „nur lesen“.
                copiedDefaults = copyDefaults(from: from, to: defaults,
                                              renaming: ["writesAllowed.\(from)": "writesAllowed.\(to)"])
            }

            // Das Ziel ist leer (ohne `comail.db`); einen Rest eines früheren
            // Starts (nur Logs, nie eine Datenbank) räumen wir weg, damit das
            // Umbenennen atomar bleibt.
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)

            let (files, bytes) = try count(of: target)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            PerfLog.shared.write("migration_defaults from=\(from) keys=\(copiedDefaults)")
            PerfLog.shared.write("migration from=\(from) files=\(files) bytes=\(bytes) ms=\(ms)")
            return .migrated(files: files, bytes: bytes)
        } catch {
            try? fm.removeItem(at: staging)
            PerfLog.shared.write("migration_failed reason=\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Seitenleiste, Ordnerzustand, Einzeltasten und so weiter. Die Wahl des
    /// Nutzers im Ziel gewinnt; Sandbox-Schlüssel und Systemeinträge kommen
    /// nicht mit.
    @discardableResult
    public static func copyDefaults(from domain: String, to defaults: UserDefaults,
                                    renaming: [String: String] = [:]) -> Int {
        guard let legacy = UserDefaults(suiteName: domain) else { return 0 }
        var copied = 0
        for (legacyKey, value) in legacy.dictionaryRepresentation() {
            let key = renaming[legacyKey] ?? legacyKey
            if key.hasSuffix(".sandbox") { continue }
            if key.hasPrefix("NS") || key.hasPrefix("Apple") || key.hasPrefix("com.apple") { continue }
            if key.hasPrefix("AK") || key.hasPrefix("PK") || key.hasPrefix("WebKit") { continue }
            if defaults.object(forKey: key) != nil { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    /// Dateien und Bytes im Zielordner — für die Logzeile.
    static func count(of dir: URL) throws -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else {
            return (0, 0)
        }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }
}
