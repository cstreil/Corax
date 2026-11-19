import Foundation

/// Ports of `src/lib/format.ts`, `src/lib/listItems.ts` (date groups) and the
/// presets of `src/lib/snooze.ts`, with the German locale fixed.
public enum Format {
    public static let locale = Locale(identifier: "de_DE")
    /// Built once: the list groups thousands of rows per update.
    nonisolated(unsafe) private static var cachedCalendar: Calendar = makeCalendar()
    private static func makeCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = locale
        c.timeZone = .current
        return c
    }
    fileprivate static var calendar: Calendar {
        if cachedCalendar.timeZone != TimeZone.current { cachedCalendar = makeCalendar() }
        return cachedCalendar
    }
    /// Month labels per "y-m" key, so grouping formats each month once.
    nonisolated(unsafe) fileprivate static var monthLabels: [String: String] = [:]

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    private static let timeF = formatter("HHmm")
    /// German weekday abbreviations always with a period ("Di."), as in
    /// `src/lib/format.ts`; ICU's "EEE" drops it depending on the OS version.
    private static let weekdayShort = ["So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa."]
    private static func weekday(_ date: Date) -> String { weekdayShort[calendar.component(.weekday, from: date) - 1] }
    private static let monthDayF = formatter("dMMM")
    private static let monthDayYearF = formatter("dMMMyy")
    fileprivate static let monthF = formatter("MMMM")
    fileprivate static let monthYearF = formatter("MMMMyyyy")
    private static let longTimeF = formatter("EEEdMMMyyyyHHmm")
    private static let longDateF = formatter("EEEEdMMM")

    /// `relativeTime`: "09:42", "Di.", "30. Juni", "2. Jan. 25".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return timeF.string(from: date) }
        let days = Int(floor(startOfToday.timeIntervalSince(date) / 86_400)) + 1
        if days <= 6 { return weekday(date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDayF.string(from: date)
        }
        return monthDayYearF.string(from: date)
    }

    /// `dateGroup`: Heute, Gestern, Diese Woche, Diesen Monat, then months.
    static func dateGroup(_ date: Date, now: Date = Date()) -> (key: String, label: String) {
        let startOfToday = calendar.startOfDay(for: now)
        let day: TimeInterval = 86_400
        if date >= startOfToday { return ("today", Strings.today) }
        if date >= startOfToday - day { return ("yesterday", Strings.yesterday) }
        if date >= startOfToday - 6 * day { return ("thisWeek", Strings.thisWeek) }
        let y = calendar.component(.year, from: date), m = calendar.component(.month, from: date)
        if y == calendar.component(.year, from: now), m == calendar.component(.month, from: now) {
            return ("thisMonth", Strings.thisMonth)
        }
        let key = "\(y)-\(m)"
        if let label = monthLabels[key] { return (key, label) }
        let label = y == calendar.component(.year, from: now) ? monthF.string(from: date) : monthYearF.string(from: date)
        monthLabels[key] = label
        return (key, label)
    }

    /// `dateGroup` for many dates at once: day boundaries computed once.
    struct Grouping {
        let today: Date, yesterday: Date, weekStart: Date, year: Int, month: Int, now: Date
        init(now: Date) {
            let c = Format.calendar
            self.now = now
            today = c.startOfDay(for: now)
            yesterday = today - 86_400
            weekStart = today - 6 * 86_400
            year = c.component(.year, from: now)
            month = c.component(.month, from: now)
        }
        func group(_ date: Date) -> (key: String, label: String) {
            if date >= today { return ("today", Strings.today) }
            if date >= yesterday { return ("yesterday", Strings.yesterday) }
            if date >= weekStart { return ("thisWeek", Strings.thisWeek) }
            let parts = Format.calendar.dateComponents([.year, .month], from: date)
            let y = parts.year ?? 0, m = parts.month ?? 0
            if y == year, m == month { return ("thisMonth", Strings.thisMonth) }
            let key = "\(y)-\(m)"
            if let label = Format.monthLabels[key] { return (key, label) }
            let label = y == year ? Format.monthF.string(from: date) : Format.monthYearF.string(from: date)
            Format.monthLabels[key] = label
            return (key, label)
        }
    }

    static func longTime(_ date: Date) -> String { longTimeF.string(from: date) }
    static func longDate(_ date: Date) -> String { longDateF.string(from: date) }

    /// Message header time in the mockup: "10:42" today, otherwise "Mo., 16:05".
    public static func messageTime(_ date: Date, now: Date = Date()) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return timeF.string(from: date) }
        if calendar.isDate(date, inSameDayAs: now.addingTimeInterval(-86_400)) { return "Gestern, " + timeF.string(from: date) }
        return weekday(date) + ", " + timeF.string(from: date)
    }

    public static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        let nf = NumberFormatter()
        nf.locale = locale
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 {
            nf.maximumFractionDigits = 0
            return (nf.string(from: NSNumber(value: Double(bytes) / 1024)) ?? "") + " KB"
        }
        nf.minimumFractionDigits = 1; nf.maximumFractionDigits = 1
        return (nf.string(from: NSNumber(value: Double(bytes) / 1_048_576)) ?? "") + " MB"
    }

    /// Short file-type badge for an attachment ("PDF", "PNG").
    public static func fileBadge(_ attachment: AttachmentMeta) -> String {
        if let name = attachment.filename, let ext = name.split(separator: ".").last, ext.count <= 4, name.contains(".") {
            return ext.uppercased()
        }
        return (attachment.mimeType?.split(separator: "/").last.map { String($0.prefix(4)).uppercased() }) ?? "DATEI"
    }

    // MARK: Snooze presets (`snoozePresets`, German labels)

    public struct SnoozePreset: Identifiable { public let id: String; public let name: String; public let at: Date }

    public static func at(_ base: Date, hour: Int, minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
    }

    /// `H` in the mockup: tomorrow 8:00.
    public static func tomorrowMorning(now: Date = Date()) -> Date {
        at(now.addingTimeInterval(86_400), hour: 8)
    }

    public static func snoozePresets(now: Date = Date()) -> [SnoozePreset] {
        var out: [SnoozePreset] = []
        var seen = Set<Date>()
        func add(_ id: String, _ name: String, _ date: Date) {
            if seen.insert(date).inserted { out.append(SnoozePreset(id: id, name: name, at: date)) }
        }
        add("later", Strings.snoozeLaterToday, now.addingTimeInterval(3 * 3600))
        var tonight = at(now, hour: 19)
        if tonight <= now { tonight = tonight.addingTimeInterval(86_400) }
        add("tonight", Strings.snoozeTonight, tonight)
        add("tomorrow", Strings.snoozeTomorrow, at(now.addingTimeInterval(86_400), hour: 9))
        add("weekend", Strings.snoozeWeekend, nextWeekday(7, from: now))   // Saturday
        add("nextWeek", Strings.snoozeNextWeek, nextWeekday(2, from: now)) // Monday
        return out
    }

    private static func nextWeekday(_ weekday: Int, from now: Date) -> Date {
        var d = now
        repeat { d = d.addingTimeInterval(86_400) } while calendar.component(.weekday, from: d) != weekday
        return at(d, hour: 9)
    }
}
