import Foundation

/// Port of `src/lib/snooze.ts` (`parseNaturalTime`) for the time pickers of
/// "Später" (`H`) and "Später senden" (`⌘⇧L`).
///
/// Tauri understands English keywords only. This port takes German first
/// ("morgen", "heute abend", "montag", "in 2 stunden", "14:30", "2h", "30m",
/// "3d", "1w") and keeps the English words, because Oma-Typing shortcuts like
/// "2h" or "tomorrow" are muscle memory.
public enum NaturalTime {
    public struct Pick: Equatable {
        public let at: Date
        public let label: String
    }

    private static let day: TimeInterval = 86_400

    private static var calendar: Calendar { Format.calendarForPickers }

    private static func at(_ base: Date, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
    }

    /// "14:30", "Heute, 14:30", "Morgen, 09:00", "Mo., 24. Nov., 09:00".
    static func label(_ date: Date, now: Date) -> String {
        let time = Format.pickerTime(date)
        let startToday = calendar.startOfDay(for: now)
        let days = Int((calendar.startOfDay(for: date).timeIntervalSince(startToday) / day).rounded())
        if days == 0 { return "Heute, \(time)" }
        if days == 1 { return "Morgen, \(time)" }
        return "\(Format.pickerWeekday(date)), \(Format.pickerDate(date)), \(time)"
    }

    private static func pick(_ date: Date, now: Date) -> Pick {
        Pick(at: date, label: label(date, now: now))
    }

    private struct Clock { let hour: Int; let minute: Int }

    private static func parseClock(_ text: String) -> Clock? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var digits = trimmed
        var amPm: String?
        let lower = trimmed.lowercased()
        for suffix in ["am", "pm"] where lower.hasSuffix(suffix) {
            amPm = suffix
            digits = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        let parts = digits.split(separator: ":")
        guard parts.count <= 2, let first = Int(parts[0]) else { return nil }
        var hour = first
        var minute = 0
        if parts.count == 2 {
            guard let value = Int(parts[1]), value >= 0, value <= 59 else { return nil }
            minute = value
        }
        guard hour >= 0, hour <= 23 else { return nil }
        if amPm == "pm", hour < 12 { hour += 12 }
        if amPm == "am", hour == 12 { hour = 0 }
        return Clock(hour: hour, minute: minute)
    }

    private static let weekdaysGerman: [String: Int] = [
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7,
        "mo": 2, "di": 3, "mi": 4, "do": 5, "fr": 6, "sa": 7, "so": 1,
        // English, as in Tauri.
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static func nextWeekday(_ weekday: Int, from now: Date) -> Date {
        var date = now
        repeat { date = date.addingTimeInterval(day) } while calendar.component(.weekday, from: date) != weekday
        return date
    }

    /// Parses one line of text; nil when nothing usable stands there.
    public static func parse(_ input: String, now: Date = Date()) -> Pick? {
        var query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }
        for prefix in ["in ", "in der ", "in den "] where query.hasPrefix(prefix) {
            query = String(query.dropFirst(prefix.count))
        }

        // Relative durations: "2h", "30m", "3d", "1w", "2 stunden", "45 minuten".
        if let relative = parseRelative(query, now: now) { return relative }

        // "morgen 14:30", "montag 9", "heute abend 19:00"
        var words = query.split(separator: " ").map(String.init)
        var clock: Clock?
        if let last = words.last, words.count > 1 {
            if let parsed = parseClock(last) {
                clock = parsed
                words.removeLast()
            } else if last == "uhr", words.count > 2, let parsed = parseClock(words[words.count - 2]) {
                clock = parsed
                words.removeLast()
                words.removeLast()
            }
        }
        let word = words.joined(separator: " ")

        switch word {
        case "später", "spaeter", "later", "later today", "später heute":
            return pick(now.addingTimeInterval(3 * 3_600), now: now)
        case "heute abend", "tonight":
            let target = at(now, clock?.hour ?? 19, clock?.minute ?? 0)
            return pick(target > now ? target : target.addingTimeInterval(day), now: now)
        case "heute", "today":
            // Without a time "heute" has no single answer; the presets cover it.
            guard let clock else { return nil }
            let target = at(now, clock.hour, clock.minute)
            return pick(target > now ? target : target.addingTimeInterval(day), now: now)
        case "morgen", "tomorrow":
            let base = now.addingTimeInterval(day)
            return pick(at(base, clock?.hour ?? 9, clock?.minute ?? 0), now: now)
        case "übermorgen", "uebermorgen":
            let base = now.addingTimeInterval(2 * day)
            return pick(at(base, clock?.hour ?? 9, clock?.minute ?? 0), now: now)
        case "wochenende", "dieses wochenende", "weekend", "this weekend", "samstag", "saturday":
            return pick(at(nextWeekday(7, from: now), clock?.hour ?? 9, clock?.minute ?? 0), now: now)
        case "nächste woche", "naechste woche", "next week", "montag", "monday":
            return pick(at(nextWeekday(2, from: now), clock?.hour ?? 9, clock?.minute ?? 0), now: now)
        case "nächsten monat", "naechsten monat", "next month":
            let base = calendar.date(byAdding: .month, value: 1, to: now) ?? now
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: base)) ?? base
            return pick(at(first, clock?.hour ?? 9, clock?.minute ?? 0), now: now)
        default:
            break
        }

        if let weekday = weekdaysGerman[word.replacingOccurrences(of: "next ", with: "")] {
            return pick(at(nextWeekday(weekday, from: now), clock?.hour ?? 9, clock?.minute ?? 0), now: now)
        }

        // A bare clock time means its next occurrence.
        if let clock = parseClock(query) ?? clock {
            let target = at(now, clock.hour, clock.minute)
            return pick(target > now ? target : target.addingTimeInterval(day), now: now)
        }
        return nil
    }

    private static func parseRelative(_ query: String, now: Date) -> Pick? {
        let compact = query.replacingOccurrences(of: " ", with: "")
        let units: [(suffixes: [String], seconds: TimeInterval)] = [
            (["minuten", "minute", "mins", "min", "m"], 60),
            (["stunden", "stunde", "hours", "hour", "hrs", "hr", "h"], 3_600),
            (["tagen", "tage", "days", "day", "d"], day),
            (["wochen", "woche", "weeks", "week", "w"], 7 * day),
        ]
        for unit in units {
            for suffix in unit.suffixes where compact.hasSuffix(suffix) {
                let number = String(compact.dropLast(suffix.count))
                guard !number.isEmpty, let value = Double(number.replacingOccurrences(of: ",", with: ".")),
                      value > 0 else { continue }
                return pick(now.addingTimeInterval(value * unit.seconds), now: now)
            }
        }
        return nil
    }
}
