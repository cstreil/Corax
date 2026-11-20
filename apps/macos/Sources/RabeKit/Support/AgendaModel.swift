import Foundation

/// M2.13 §8.4: eine Zeile der Terminliste.
///
/// Das Modell ist bewusst ohne UI: die Gruppierung, die Reihenfolge und die
/// Stelle des aufgeklappten Bands lassen sich so prüfen (M213Tests).
public enum AgendaRow: Equatable, Sendable {
    /// Gruppenkopf eines Tages.
    case day(Int64)
    /// „Keine Termine" unter dem heutigen Tag, damit der Anker sichtbar bleibt.
    case emptyDay(Int64)
    /// Ein Termin.
    case event(CalendarEvent)
    /// Das aufgeklappte Band unter dem offenen Termin.
    case band(Int64)
}

public enum AgendaModel {
    /// Baut die Zeilen: Tage ohne Termin entfallen, der heutige Tag erscheint
    /// auch leer, das Band steht direkt unter seinem Termin.
    public static func rows(events: [CalendarEvent], days: [Int64],
                            openEvent: Int64?, today: Int64) -> [AgendaRow] {
        var rows: [AgendaRow] = []
        let byDay = CalendarEventRules.groupByDay(events, days: days)
        for day in days {
            let items = sorted(byDay[day] ?? [])
            if items.isEmpty {
                if day == today {
                    rows.append(.day(day))
                    rows.append(.emptyDay(day))
                }
                continue
            }
            rows.append(.day(day))
            for event in items {
                rows.append(.event(event))
                if openEvent == event.id { rows.append(.band(event.id)) }
            }
        }
        return rows
    }

    /// Die Anzeigereihenfolge der Liste, ohne Doppelte: ein mehrtägiger Termin
    /// steht in jeder berührten Tagesgruppe, für `↑`/`↓` zählt er aber nur
    /// einmal — an seiner ersten Stelle. M2.15b (2.3): die Auswahl muss der
    /// Liste folgen, nicht der Reihenfolge im Store.
    public static func orderedEvents(events: [CalendarEvent], days: [Int64]) -> [CalendarEvent] {
        let byDay = CalendarEventRules.groupByDay(events, days: days)
        var seen = Set<Int64>()
        var ordered: [CalendarEvent] = []
        for day in days {
            for event in sorted(byDay[day] ?? []) where seen.insert(event.id).inserted {
                ordered.append(event)
            }
        }
        return ordered
    }

    /// Innerhalb eines Tages: ganztägig zuerst, dann nach Start, dann Titel.
    static func sorted(_ items: [CalendarEvent]) -> [CalendarEvent] {
        items.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            if a.startsAt != b.startsAt { return a.startsAt < b.startsAt }
            return (a.summary ?? "").localizedStandardCompare(b.summary ?? "") == .orderedAscending
        }
    }

    /// Der Tag, zu dem eine Zeile gehört (für die „Tag 2 von 3"-Anzeige).
    public static func day(of row: AgendaRow, in rows: [AgendaRow], at index: Int) -> Int64? {
        switch row {
        case .day(let day), .emptyDay(let day):
            return day
        case .event, .band:
            var cursor = index
            while cursor >= 0 {
                switch rows[cursor] {
                case .day(let day), .emptyDay(let day): return day
                case .event, .band: cursor -= 1
                }
            }
            return nil
        }
    }
}
