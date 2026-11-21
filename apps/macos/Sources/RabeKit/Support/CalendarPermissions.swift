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

    /// Ist der Termin von einem fremden Organisator? Ein leerer Organisator ist
    /// **nicht** fremd: so sehen eigene Termine im Kalender aus.
    ///
    /// M2.18c: iCloud trägt bei eigenen Terminen oft nur die Kontokennung ein
    /// (`/aODc…/principal/`). Eine Kennung ist nur fremd, wenn sie nicht die
    /// eigene des Zugangs ist; unbekannt zählt als fremd (gesperrt). Dieselbe
    /// Regel wie im Kern (`calendar::edit_blocked_reason`).
    public static func hasForeignOrganizer(_ event: CalendarEvent, ownEmails: Set<String>,
                                           calendars: [CalendarCollection] = []) -> Bool {
        guard let organizer = address(event.organizer) else { return false }
        if organizer.contains("@") { return !ownEmails.contains(organizer) }
        guard let own = ownPrincipal(for: event, calendars: calendars),
              let path = principalPath(event.organizer) else { return true }
        return path != own
    }

    /// Die eigene Kontokennung des Kontos, zu dem der Termin gehört.
    public static func ownPrincipal(for event: CalendarEvent,
                                    calendars: [CalendarCollection]) -> String? {
        calendars
            .filter { $0.accountId == event.accountId }
            .compactMap { principalPath($0.principalUrl) }
            .first
    }

    /// Nur der Pfad einer Kennung — ohne Schema und Host, ohne Schluss-`/`,
    /// klein. `https://p01.example/abc/principal/` und `/abc/PRINCIPAL` ergeben
    /// beide `abc/principal`. Dieselbe Normalisierung wie im Kern.
    public static func principalPath(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") {
            let rest = text[scheme.upperBound...]
            text = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return text.isEmpty ? nil : text
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
        blockReason(event, calendars: calendars, ownEmails: ownEmails) == nil
    }

    /// M2.18 §2: derselbe Grund wie im Kern (`calendar::edit_blocked_reason`) —
    /// gleiche Reihenfolge, gleiche Worte. Der Kern prüft beim Sichern noch
    /// einmal; die App muss dieselbe Entscheidung treffen, sonst öffnet sie
    /// einen Stift, den der Kern hinterher ablehnt (oder versteckt ihn).
    public static func blockReason(_ event: CalendarEvent, calendars: [CalendarCollection],
                                   ownEmails: Set<String>) -> String? {
        if CalendarEventRules.isCancelled(event) { return "event is cancelled" }
        // M2.18e: Ein in Rabe angelegter Termin ist unser Termin — auch wenn
        // iCloud beim Hochladen eine Kennung als Organisator einträgt.
        if !event.isLocal,
           hasForeignOrganizer(event, ownEmails: ownEmails, calendars: calendars) {
            return "only the organizer can edit this event"
        }
        guard let calendarId = event.calendarId else {
            // Ohne Kalender kennt auch der Kern kein Schreibrecht: dort zählt
            // `is_local`.
            return event.isLocal ? nil : "event has no writable calendar"
        }
        guard let calendar = calendars.first(where: { $0.id == calendarId }) else {
            // Kalender nicht geladen: kein Schreibrecht bekannt. Lokale Termine
            // bleiben bearbeitbar (wie im Kern), sonst gilt „kein Kalender".
            return event.isLocal ? nil : "event has no writable calendar"
        }
        return calendar.readOnly ? "calendar is read-only" : nil
    }

    /// Zu-/absagen darf nur, wer als Teilnehmer eingetragen und nicht selbst
    /// Organisator ist.
    public static func canRSVP(_ event: CalendarEvent, ownEmails: Set<String>) -> Bool {
        guard !CalendarEventRules.isCancelled(event) else { return false }
        guard !isOrganizer(event, ownEmails: ownEmails) else { return false }
        return isAttendee(event, ownEmails: ownEmails)
    }

    /// M2.17 §3: „Antwort offen" — eine Einladung, bei der der Nutzer
    /// Teilnehmer ist und noch nicht geantwortet hat. Leerer Status und
    /// `NEEDS-ACTION` zählen beide als offen; eigene und abgesagte Termine nie.
    public static func needsResponse(_ event: CalendarEvent, ownEmails: Set<String>) -> Bool {
        guard !CalendarEventRules.isCancelled(event) else { return false }
        guard isAttendee(event, ownEmails: ownEmails) else { return false }
        guard !isOrganizer(event, ownEmails: ownEmails) else { return false }
        let status = (event.rsvpStatus ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return status.isEmpty || status == "NEEDS-ACTION"
    }
}
