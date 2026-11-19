import Foundation

/// German UI strings. Where `src/i18n/locales/de/*.json` has the text, it is
/// copied verbatim (key in the comment); the rest follows the mockup.
public enum Strings {
    public static func view(_ view: MailView) -> String {
        switch view {
        case .inbox: "Posteingang"            // mockup title (common:view.inbox = "Inbox")
        case .starred: "Markiert"             // common:view.starred
        case .snoozed: "Zurückgestellt"       // common:view.snoozed
        case .sent: "Gesendet"                // common:view.sent
        case .drafts: "Entwürfe"              // common:view.drafts
        case .done: "Erledigt"                // common:view.done
        case .trash: "Papierkorb"             // common:view.trash
        case .spam: "Spam"                    // common:view.spam
        case .all: "Alle E-Mails"             // common:view.all
        }
    }

    // common:dateGroup.*
    static let today = "Heute"
    static let yesterday = "Gestern"
    static let thisWeek = "Diese Woche"
    static let thisMonth = "Diesen Monat"

    public static let undo = "Rückgängig"                         // common:action.undo
    public static let sent = "Gesendet"                           // compose:sent
    public static let send = "Senden"                             // compose:send
    public static let discard = "Verwerfen"                       // compose:discard
    public static let reply = "Antworten"                         // compose:modeTitles.reply
    public static let replyAll = "Allen antworten"                // compose:modeTitles.reply_all
    public static let forward = "Weiterleiten"                    // compose:modeTitles.forward
    public static let newMail = "Neue E-Mail"
    public static let loadImages = "Bilder laden"                 // thread:remoteImages.load
    public static let imagesHidden = "Bilder in dieser Nachricht werden nicht angezeigt." // thread:remoteImages.hidden
    public static let attachmentFallback = "Anhang"               // thread:attachment.fallbackName
    public static let undone = "Rückgängig gemacht"               // commands:undo.undone
    static let nothingToUndo = "Nichts rückgängig zu machen" // commands:undo.nothingToUndo
    static let tooLate = "Zu spät, die Nachricht ist bereits gesendet" // commands:undo.tooLate
    /// R-W1: `undo_last` took back a foreign action instead of ours.
    static let undoForeignAction = "Rückgängig hat eine andere Aktion getroffen – bitte prüfen"
    static let undoGone = "Rückgängig nicht mehr möglich"
    public static let search = "Suchen"
    public static let shortcuts = "Tastenkürzel"
    public static let draftSaved = "Entwurf gespeichert"          // compose:draftSaved

    // commands:actionLabel.* (archive has no catalog entry: mockup text)
    static let archived = "Archiviert"
    static let trashed = "In den Papierkorb verschoben"
    static let starred = "Markiert"
    static let unstarred = "Markierung entfernt"
    static let markedUnread = "Als ungelesen markiert"
    static let markedRead = "Als gelesen markiert"
    public static let snoozedUntilTomorrow = "Zurückgestellt bis morgen, 8:00"

    // common:snoozePreset.*
    static let snoozeLaterToday = "Später heute"
    static let snoozeTonight = "Heute Abend"
    public static let snoozeTomorrow = "Morgen"
    static let snoozeWeekend = "Dieses Wochenende"
    static let snoozeNextWeek = "Nächste Woche"

    public static let offline = "Du bist offline"                 // errors:offline

    /// `errorMessage` in `src/ipc/errors.ts` with the `errors:` catalog.
    public static func errorText(_ error: RabeClientError) -> String {
        switch error {
        case .notStarted: return "Der Kern läuft noch nicht"
        case .decode(let command, _): return "Antwort von \(command) unlesbar"
        case .host(let message): return truncate(message)
        case .core(let code, let message):
            let table: [String: String] = [
                "db": "Datenbankfehler",
                "io": "Fehler im Dateisystem",
                "network": "Der Server ist nicht erreichbar. Prüfe deine Verbindung oder den Endpunkt in den Einstellungen.",
                "imap": "Fehler beim E-Mail-Server (IMAP)",
                "smtp": "Senden fehlgeschlagen (SMTP-Fehler)",
                "tls": "Fehler bei der sicheren Verbindung (TLS)",
                "auth": "Anmeldung fehlgeschlagen",
                "needs_reauth": "Dieses Konto muss neu verbunden werden",
                "keyring": "Fehler im sicheren Speicher",
                "mime": "Fehler im Nachrichtenformat",
                "not_found": "Nicht gefunden",
                "offline": "Du bist offline",
                "host_stopped": "Der Kern wurde beendet",
                "url_refused": "Link wurde nicht geöffnet (nicht erlaubtes Schema)",
                "path_refused": "Datei liegt außerhalb des Datenverzeichnisses und wurde nicht geöffnet",
                "read_only": "Nur-Lesen-Modus – Postfach → Änderungen erlauben",
                "command_not_allowed": "Dieser Befehl ist in der echten Instanz nicht freigegeben",
                "action_not_allowed": "Diese Aktion ist in der echten Instanz nicht freigegeben",
            ]
            if let text = table[code] { return text }
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Etwas ist schiefgelaufen" : truncate(detail)
        }
    }

    static func truncate(_ text: String, max: Int = 200) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
