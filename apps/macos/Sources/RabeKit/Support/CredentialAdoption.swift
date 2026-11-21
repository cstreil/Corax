import Foundation

/// M3.1: die Zugangsdaten der bisherigen Instanz im Schlüsselbund übernehmen.
///
/// Der Schlüsselbund-Service **ist** die Kennung (alte Kennung → neue Kennung,
/// beide in `AppIdentity`), Einträge heißen
/// `<account_id>:<slot>`. Ohne Übernahme wäre nach dem Umbenennen nichts mehr
/// lesbar: Postfach-Passwort, CalDAV-Passwort, KI-Schlüssel, MCP-Token.
///
/// Gelesen wird nur, was es gibt; geschrieben wird nur, was unter der neuen
/// Kennung noch fehlt. macOS fragt beim Lesen eines fremden Eintrags nach
/// Zugriff — das muss der Nutzer einmal je Eintrag bestätigen (`Immer
/// erlauben`). Der Zugriff selbst liegt beim Aufrufer (`Sources/Rabe`), damit
/// `RabeKit` bei Foundation bleibt und die Logik testbar ist.
public enum CredentialAdoption {
    public struct Result: Equatable, Sendable {
        /// Übernommene Einträge.
        public var adopted = 0
        /// Unter der neuen Kennung schon vorhanden.
        public var skipped = 0
        /// Lesen oder Schreiben abgelehnt/fehlgeschlagen.
        public var failed = 0
        public init(adopted: Int = 0, skipped: Int = 0, failed: Int = 0) {
            self.adopted = adopted
            self.skipped = skipped
            self.failed = failed
        }
    }

    /// Die Slots des Kerns (`accounts/credentials.rs`), in Abfragereihenfolge.
    /// App-weite Geheimnisse liegen unter Konto 0.
    public static let slots = [
        "password", "refresh_token", "access_token", "ai_api_key",
        "caldav_password", "mcp_token", "decision_api_key",
        "decision_api_key_openai", "decision_api_key_commandcode",
        "decision_api_key_custom",
    ]

    /// Ein Eintrag gilt als vorhanden, wenn `exists` ihn unter einer der alten
    /// Kennungen findet — es gilt die **erste** Quelle, die ihn hat (M3.5).
    /// Fehlt er überall, kostet die Abfrage höchstens einen Metadaten-Blick —
    /// keinen Dialog.
    public static func run(from sources: [String],
                           to: String,
                           accounts: [Int64],
                           exists: (String, String) -> Bool,
                           read: (String, String) -> String?,
                           write: (String, String, String) -> Bool) -> Result {
        var result = Result()
        var perSource: [String: Int] = [:]
        for account in Set(accounts).sorted() {
            for slot in slots {
                let name = "\(account):\(slot)"
                guard let source = sources.first(where: { exists($0, name) }) else { continue }
                if exists(to, name) {
                    result.skipped += 1
                    continue
                }
                guard let secret = read(source, name) else {
                    result.failed += 1
                    PerfLog.shared.write("credential_failed account=\(account) slot=\(slot) source=\(source) reason=read")
                    continue
                }
                if write(to, name, secret) {
                    result.adopted += 1
                    perSource[source, default: 0] += 1
                    PerfLog.shared.write("credential_adopted account=\(account) slot=\(slot) source=\(source)")
                } else {
                    result.failed += 1
                    PerfLog.shared.write("credential_failed account=\(account) slot=\(slot) source=\(source) reason=write")
                }
            }
        }
        for source in sources {
            PerfLog.shared.write("credentials source=\(source) adopted=\(perSource[source] ?? 0)")
        }
        PerfLog.shared.write("credentials adopted=\(result.adopted) skipped=\(result.skipped) failed=\(result.failed) source=\(sources.first ?? "")")
        return result
    }

    /// Konto-Kennungen für die Abfrage: `0` für die app-weiten Geheimnisse
    /// (KI, MCP) zuerst, dann die Konten der Datenbank. Die IDs liest der
    /// Aufrufer mit SQLite (`DatabaseCopy`), damit `RabeKit` bei Foundation
    /// bleibt.
    public static func accounts(appWide: Int64 = 0, fromIDs ids: [Int64]) -> [Int64] {
        var seen: Set<Int64> = [appWide]
        var list = [appWide]
        for id in ids.sorted() where id > 0 {
            if seen.insert(id).inserted { list.append(id) }
        }
        return list
    }
}
