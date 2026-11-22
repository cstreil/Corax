import Foundation

/// M2.13 §8.3: die Tage eines Jahres für die Jahresansicht.
///
/// Eigene Datei, damit das Raster ohne `CalendarStore` prüfbar ist (Schaltjahr,
/// Jahresgrenzen) — die Ansicht braucht nur die Tagesliste und die Punkte.
public enum YearGrid {
    /// Tagesbeginne vom 1.1. bis 31.12. des Jahres, in der Zeitzone des Kalenders.
    public static func days(year: Int, calendar: Calendar) -> [Int64] {
        var cal = calendar
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        guard let start = cal.date(from: components) else { return [] }
        components.year = year + 1
        guard let end = cal.date(from: components) else { return [] }
        var out: [Int64] = []
        out.reserveCapacity(366)
        var date = start
        while date < end {
            out.append(Int64((date.timeIntervalSince1970 * 1000).rounded()))
            guard let next = cal.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return out
    }

    /// Die zwölf Monatsbeginne eines Jahres.
    public static func months(year: Int, calendar: Calendar) -> [Int64] {
        var cal = calendar
        var out: [Int64] = []
        out.reserveCapacity(12)
        for month in 1...12 {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = 1
            guard let date = cal.date(from: components) else { continue }
            out.append(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return out
    }
}
