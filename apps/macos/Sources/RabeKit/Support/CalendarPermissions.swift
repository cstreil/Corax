import Foundation

/// M2.15b (2.2): Was darf ich mit einem Termin tun?
///
/// Bis M2.15 galt `isLocal` als Bearbeitungsrecht. Damit war jeder Termin aus
/// einem CalDAV-Kalender eine fremde Einladung — auch der eigene Termin im
/// beschreibbaren Kalender. Die Entscheidung hängt jetzt am Kalender und am
/// Organisator, nicht an der Herkunft:
///
/// - **bearbeitbar**: der Termin liegt in einem beschreibbaren Kalender
///   (`read_only = 0`, oder lokal ohne Kalender) und wird nicht von einer
///   fremden Adresse organisiert.
/// - **zu-/absagen**: der Nutzer ist Teilnehmer und nicht der Organisator.
///
/// Woher `readOnly` kommt (seit M2.16): der Kern liest die Privilegien einer
/// Sammlung (`current-user-privilege-set`) bei der Discovery aus; ein Kalender
/// ohne `DAV:write` ist schreibgeschützt. Fehlt die Angabe im PROPFIND, gilt der
/// Kalender wie bisher als beschreibbar.
public enum CalendarPermissions {

    /// Vergleichbare Adresse: `mailto:` weg, Anzeigename in spitzen Klammern
    /// weg, Kleinschreibung. Leer oder nil -> nil.
    public static func address(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasSuffix(">"), let open = text.lastIndex(of: "<") {
            text = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        }
        if text.lowercased().hasPrefix("mailto:") {
            text = String(text.dropFirst("mailto:".count))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.lowercased()
    }

    public static func ownAddresses<S: Sequence>(_ emails: S) -> Set<String> where S.Element == String {
        Set(emails.compactMap(address))
    }

    /// Ist der Termin von einer fremden Adresse organisiert? Ein leerer
    /// Organisator ist **nicht** fremd: so sehen eigene Termine im Kalender aus.
    public static func hasForeignOrganizer(_ event: CalendarEvent, ownEmails: Set<String>) -> Bool {
        guard let organizer = address(event.organizer) else { return false }
        return !ownEmails.contains(organizer)
    }

    public static func isOrganizer(_ event: CalendarEvent, ownEmails: Set<String>) -> Bool {
        guard let organizer = address(event.organizer) else { return false }
        return ownEmails.contains(organizer)
    }

    public static func isAttendee(_ event: CalendarEvent, ownEmails: Set<String>) -> Bool {
        event.attendees.contains { attendee in
            guard let address = address(attendee.email) else { return false }
            return ownEmails.contains(address)
        }
    }

    /// Bearbeitbar: beschreibbarer Kalender (oder lokaler Termin), nicht von
    /// jemand anderem organisiert, nicht abgesagt.
    public static func canEdit(_ event: CalendarEvent, calendars: [CalendarCollection],
                               ownEmails: Set<String>) -> Bool {
        guard !CalendarEventRules.isCancelled(event) else { return false }
        guard !hasForeignOrganizer(event, ownEmails: ownEmails) else { return false }
        guard let calendarId = event.calendarId else { return event.isLocal }
        guard let calendar = calendars.first(where: { $0.id == calendarId }) else { return false }
        return !calendar.readOnly
    }

    /// Zu-/absagen darf nur, wer als Teilnehmer eingetragen und nicht selbst
    /// Organisator ist.
    public static func canRSVP(_ event: CalendarEvent, ownEmails: Set<String>) -> Bool {
        guard !CalendarEventRules.isCancelled(event) else { return false }
        guard !isOrganizer(event, ownEmails: ownEmails) else { return false }
        return isAttendee(event, ownEmails: ownEmails)
    }
}
