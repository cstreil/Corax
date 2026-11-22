import Foundation

/// M2.17 §1: Suche in der Terminliste.
///
/// Der Kern hat keine Terminsuche (Prüfpunkt 8.5 aus M2.13), deshalb filtert
/// die App die bereits geladenen Termine. Gesucht wird über Titel, Ort,
/// Beschreibung und Teilnehmende — so, wie der Nutzer einen Termin
/// wiedererkennt. Mehrere Wörter müssen alle treffen (UND), Groß-/Klein- und
/// Umlautschreibung zählen nicht.
public enum CalendarSearch {
    /// Die Felder, in denen ein Treffer zählt.
    public static func haystack(_ event: CalendarEvent) -> [String] {
        var text: [String] = []
        if let summary = event.summary { text.append(summary) }
        if let location = event.location { text.append(location) }
        if let description = event.description { text.append(description) }
        for attendee in event.attendees {
            if let name = attendee.name { text.append(name) }
            text.append(attendee.email)
        }
        return text
    }

    /// Trifft der Termin die Anfrage? Leere Anfrage trifft nichts (die Liste
    /// zeigt dann den normalen Zeitraum, nicht alle Termine).
    public static func matches(_ event: CalendarEvent, query: String) -> Bool {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return false }
        let fields = haystack(event)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive,
                                              .widthInsensitive]
        return tokens.allSatisfy { token in
            fields.contains { $0.range(of: token, options: options) != nil }
        }
    }

    /// Treffer in Anzeigereihenfolge (nach Start, dann Titel).
    public static func results(_ events: [CalendarEvent], query: String) -> [CalendarEvent] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return events
            .filter { matches($0, query: query) }
            .sorted { a, b in
                if a.startsAt != b.startsAt { return a.startsAt < b.startsAt }
                return (a.summary ?? "").localizedStandardCompare(b.summary ?? "") == .orderedAscending
            }
    }
}
