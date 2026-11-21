import Foundation

/// M2.17 §4: Farbpunkte der Jahresansicht.
///
/// Ein Punkt steht für **einen Kalender**, nicht für einen Termin: drei
/// Termine im selben Kalender ergeben einen Punkt, drei Kalender am selben Tag
/// drei. Mehr als drei Punkte gibt es nicht, damit die Zelle ruhig bleibt.
/// Mehrträgige Termine markieren jeden Tag, den sie berühren.
public enum YearDots {
    public static let maximum = 3

    /// Je Tag die Kalender in der Reihenfolge ihres ersten Termins; `nil`
    /// steht für „Einladungen & lokale" (Termine ohne Kalender).
    public static func byDay(events: [CalendarEvent], days: [Int64],
                             math: CalendarMath, max: Int = YearDots.maximum) -> [Int64: [Int64?]] {
        guard !days.isEmpty else { return [:] }
        let known = Set(days)
        var result: [Int64: [Int64?]] = [:]
        // Nach Start sortiert: die Reihenfolge der Punkte folgt dem Tag, nicht
        // der Reihenfolge, in der der Kern die Termine liefert.
        for event in events.sorted(by: { $0.startsAt < $1.startsAt }) {
            let first = math.startOfDay(event.startsAt)
            let end = CalendarEventRules.eventEnd(event)
            var day = first
            // Schutz gegen kaputte Daten (Ende weit in der Zukunft).
            var steps = 0
            while day < end, known.contains(day), steps < 400 {
                var colors = result[day] ?? []
                if colors.count < max, !colors.contains(where: { $0 == event.calendarId }) {
                    colors.append(event.calendarId)
                    result[day] = colors
                }
                day = math.addDays(day, 1)
                steps += 1
            }
        }
        return result
    }
}
