import Foundation
import SQLite3

/// M3.1: die Datenbank der bisherigen Instanz konsistent übernehmen.
///
/// Bei WAL liegt der letzte Stand nicht in `comail.db`, sondern in
/// `comail.db-wal`; ein `cp` der Hauptdatei verlöre genau die letzten
/// Nachrichten. `VACUUM INTO` schreibt dagegen eine abgeschlossene Kopie in eine
/// neue Datei und lässt die Quelle unangetastet — das geht auch auf einer
/// schreibgeschützten Verbindung.
enum DatabaseCopy {
    enum Failure: LocalizedError {
        case open(String, Int32)
        case vacuum(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .open(let path, let code):
                return "Datenbank \(path) ließ sich nicht öffnen (SQLite \(code))."
            case .vacuum(_, let code, let message):
                return "Kopie der Datenbank fehlgeschlagen (SQLite \(code)): \(message)"
            }
        }
    }

    /// Rohlesen ohne Schreibrecht: `mode=ro` als URI, damit SQLite die Quelle
    /// nicht verändert (kein Checkpoint, keine WAL-Änderung).
    private static func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let uri = "file:" + url.path + "?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let code = db != nil ? sqlite3_extended_errcode(db) : rc
            sqlite3_close(db)
            throw Failure.open(url.path, code)
        }
        return db
    }

    /// Kopie nach `destination`; die Datei darf noch nicht existieren.
    static func vacuum(from source: URL, to destination: URL) throws {
        let db = try open(source)
        defer { sqlite3_close(db) }
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, "VACUUM INTO '\(escaped)';", nil, nil, &error)
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? sqlite3_errmsg(db).map { String(cString: $0) } ?? ""
            sqlite3_free(error)
            throw Failure.vacuum(source.path, rc, message)
        }
    }

    /// Konto-Kennungen für die Schlüsselbund-Übernahme — nur lesend.
    static func accountIDs(in db: URL) -> [Int64] {
        guard let handle = try? open(db) else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id FROM accounts ORDER BY id;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(Int64(sqlite3_column_int64(statement, 0)))
        }
        return ids
    }
}
