import Foundation

// Codable mirrors of the calendar DTOs in `src/ipc/types.ts` / `models.rs`
// (M2.2). The Rust side serializes with `serde(rename_all = "camelCase")`, so
// the JSON keys match the Swift property names.
//
// `Calendar` is taken by Foundation, so the CalDAV collection is
// `CalendarCollection` here; the JSON shape is unchanged.

public struct EventAttendee: Codable, Sendable, Hashable {
    public let email: String
    public let name: String?
    /// NEEDS-ACTION | ACCEPTED | TENTATIVE | DECLINED
    public let partstat: String?

    public init(email: String, name: String? = nil, partstat: String? = nil) {
        self.email = email
        self.name = name
        self.partstat = partstat
    }
}

/// `CalendarEvent` in `types.ts`: one stored event or parsed invite.
public struct CalendarEvent: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let accountId: Int64
    public let messageId: Int64?
    public let summary: String?
    public let location: String?
    public let organizer: String?
    public let description: String?
    public let attendees: [EventAttendee]
    public let joinUrl: String?
    /// Our answer to an invite: ACCEPTED | TENTATIVE | DECLINED.
    public let rsvpStatus: String?
    /// Created in Rabe (vs. parsed from an incoming invite).
    public let isLocal: Bool
    /// CalDAV collection this event syncs with; nil = local-only.
    public let calendarId: Int64?
    public let rrule: String?
    public let startsAt: Int64
    public let endsAt: Int64?
    public let allDay: Bool
    public let status: String?
    public let method: String?
    /// M2.16: Warum der letzte Upload zum Kalender-Server scheiterte; nil =
    /// nichts offen. Der Kern leert das Feld beim nächsten erfolgreichen PUT.
    public var syncError: String? = nil
    /// M2.18: Beginn dieser Wiederholung. `nil` = der Termin selbst (der Kern
    /// liefert eine Serie als **einen** Datensatz; die App breitet sie für die
    /// Anzeige aus, `CalendarStore.occurrences`).
    public var occurrenceStart: Int64? = nil
    /// M2.18: Bei einer ausgebreiteten Wiederholung die Kennung des Termins im
    /// Kern; `nil` = `id` ist schon die Kern-Kennung.
    public var seriesId: Int64? = nil

    /// Die Kennung, die der Kern kennt (Schreiben, Löschen, Antworten).
    public var eventId: Int64 { seriesId ?? id }

    /// Ist das eine ausgebreitete Wiederholung einer Serie?
    public var isSeriesOccurrence: Bool { seriesId != nil }
}

public extension CalendarEvent {
    /// Eine Wiederholung als eigener Anzeigetermin (M2.18 §5).
    ///
    /// Der Kern breitet eine Serie in `list_events` **schon** in einzelne
    /// Wiederholungen aus und lässt ihnen die Kennung des Masters. Für die
    /// Anzeige braucht jede Wiederholung eine eigene: sonst überspringt `↑`/`↓`
    /// alle bis auf eine, und `↵` findet „den offenen Termin" in jeder Zeile
    /// wieder. Die Kern-Kennung bleibt in `seriesId` erhalten.
    func taggedAsSeriesOccurrence() -> CalendarEvent {
        guard rrule != nil, seriesId == nil else { return self }
        return CalendarEvent(
            id: CalendarOccurrenceID.displayId(eventId: id, start: startsAt),
            accountId: accountId, messageId: messageId, summary: summary, location: location,
            organizer: organizer, description: description, attendees: attendees,
            joinUrl: joinUrl, rsvpStatus: rsvpStatus, isLocal: isLocal,
            calendarId: calendarId, rrule: rrule, startsAt: startsAt, endsAt: endsAt,
            allDay: allDay, status: status, method: method, syncError: syncError,
            occurrenceStart: startsAt, seriesId: id)
    }
}

/// Anzeige-Kennungen für Wiederholungen (M2.18 §5).
///
/// Der Kern liefert alle Wiederholungen einer Serie mit **derselben** Kennung.
/// Die Anzeige-Kennung kodiert deshalb `(Kern-Kennung, Beginn)` und ist
/// negativ (die Kern-Kennungen sind positiv). Sie ist aus den Daten berechnet,
/// nicht fortlaufend nummeriert — sie bleibt über ein Neuladen hinweg gleich,
/// die Auswahl steht also still.
public enum CalendarOccurrenceID {
    /// Frühester darstellbarer Beginn (2017-07). Reicht für alle Fenster, die
    /// die App anfragt (±12 Monate um heute).
    public static let epoch: Int64 = 1_500_000_000
    /// Sekunden je Serie; die Kennung bleibt damit auch nach Jahrzehnten eindeutig.
    public static let stride: Int64 = 4_000_000_000

    public static func displayId(eventId: Int64, start: Int64) -> Int64 {
        let seconds = start / 1000
        let offset = max(0, min(seconds - epoch, stride - 1))
        return -(eventId * stride + offset)
    }

    /// Der Kern-Termin zu einer Anzeige-Kennung (nil bei einer normalen Kennung).
    public static func eventId(of displayId: Int64) -> Int64? {
        displayId < 0 ? (-displayId) / stride : nil
    }

    /// Der Beginn (ms) zu einer Anzeige-Kennung.
    public static func start(of displayId: Int64) -> Int64? {
        guard displayId < 0 else { return nil }
        return (epoch + (-displayId) % stride) * 1000
    }
}

/// M2.18 §6: „Alle Termine der Serie" ändert die **Uhrzeit**, nicht das Datum
/// der Serie. Verschoben wird um die Differenz der bearbeiteten Wiederholung.
public enum SeriesShift {
    /// Neue Zeiten für den Master, wenn eine Wiederholung bearbeitet wurde:
    /// Datum des Masters, Uhrzeit aus dem Formular, Dauer aus dem Formular.
    ///
    /// Gerechnet wird in Ortszeit (`CalendarMath`), damit „09:00" auch über die
    /// Zeitumstellung 09:00 bleibt und nicht über die UTC-Tagesgrenze rutscht.
    public static func master(start masterStart: Int64, chosenStart: Int64, chosenEnd: Int64,
                              math: CalendarMath = CalendarMath(weekStartsOn: .monday)) -> (start: Int64, end: Int64) {
        let timeOfDay = chosenStart - math.startOfDay(chosenStart)
        let newStart = math.startOfDay(masterStart) + timeOfDay
        var length = chosenEnd - chosenStart
        if length <= 0 { length = 30 * 60_000 }
        return (newStart, newStart + length)
    }
}

/// `Calendar` in `types.ts`: a discovered CalDAV collection.
public struct CalendarCollection: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let accountId: Int64
    public let url: String
    public let displayName: String?
    public let color: String?
    public let readOnly: Bool
    public let enabled: Bool
    public let isDefault: Bool
    public let lastSyncedAt: Int64?
    /// M2.18c: die eigene Kontokennung des Zugangs (`caldav_config.principal_url`).
    /// Der Kern hängt sie an jede Sammlung; die App vergleicht damit einen
    /// Organisator, den iCloud als `/…/principal/` einträgt.
    public var principalUrl: String? = nil

    public var label: String { displayName ?? url }
}

/// `CreateEventArgs` in `models.rs`. The dispatcher takes it as
/// `{"args": …}`; `calendarId` nil means the account's default (or local-only).
public struct CreateEventArgs: Encodable, Sendable, Equatable {
    public var accountId: Int64
    public var calendarId: Int64?
    public var summary: String
    public var description: String?
    public var location: String?
    public var joinUrl: String?
    public var startsAt: Int64
    public var endsAt: Int64
    public var allDay: Bool
    /// Invites are emailed (ICS METHOD:REQUEST) to every attendee.
    public var attendees: [Address]

    public init(accountId: Int64, calendarId: Int64? = nil, summary: String,
                description: String? = nil, location: String? = nil, joinUrl: String? = nil,
                startsAt: Int64, endsAt: Int64, allDay: Bool = false,
                attendees: [Address] = []) {
        self.accountId = accountId
        self.calendarId = calendarId
        self.summary = summary
        self.description = description
        self.location = location
        self.joinUrl = joinUrl
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.attendees = attendees
    }
}

/// `UpdateEventArgs` in `models.rs`. Note: the host has **no** `accountId` and
/// no `calendarId` here (`types.ts` prints `accountId` in the Tauri payload,
/// the host ignores it); moving an event between calendars is not supported.
public struct UpdateEventArgs: Encodable, Sendable, Equatable {
    public var eventId: Int64
    public var summary: String
    public var description: String?
    public var location: String?
    public var joinUrl: String?
    public var startsAt: Int64
    public var endsAt: Int64
    public var allDay: Bool
    public var attendees: [Address]
    /// Email an updated REQUEST ICS to attendees (organizer only).
    public var notify: Bool

    public init(eventId: Int64, summary: String, description: String? = nil,
                location: String? = nil, joinUrl: String? = nil, startsAt: Int64, endsAt: Int64,
                allDay: Bool = false, attendees: [Address] = [], notify: Bool = true) {
        self.eventId = eventId
        self.summary = summary
        self.description = description
        self.location = location
        self.joinUrl = joinUrl
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.attendees = attendees
        self.notify = notify
    }

    /// Full update payload from a drag drop: the event's fields, new times.
    /// M2.18: `eventId` ist die Kern-Kennung — bei einer Wiederholung ist `id`
    /// nur die Anzeige-Kennung.
    public init(_ event: CalendarEvent, startsAt: Int64, endsAt: Int64, notify: Bool = true) {
        self.init(eventId: event.eventId, summary: event.summary ?? "", description: event.description,
                  location: event.location, joinUrl: event.joinUrl, startsAt: startsAt, endsAt: endsAt,
                  allDay: event.allDay,
                  attendees: event.attendees.map { Address(name: $0.name, email: $0.email) },
                  notify: notify)
    }
}

/// `ConnectCalendarArgs` in `models.rs` (M2.12). The dispatcher takes it as
/// `{"args": …}`. `kind` is `"google"` or `"generic"`; the native app sends only
/// `"generic"` (CalDAV with a server URL and an app password) — Google and
/// Microsoft go through their own OAuth paths in the core and belong to M3.
///
/// The password is only passed through: the core stores it in the keychain
/// (`Slot::CaldavPassword`) and the app keeps no copy.
public struct ConnectCalendarArgs: Encodable, Sendable, Equatable {
    public var accountId: Int64
    /// "google" | "generic"
    public var kind: String
    public var url: String?
    public var username: String?
    public var password: String?

    public init(accountId: Int64, kind: String = "generic", url: String? = nil,
                username: String? = nil, password: String? = nil) {
        self.accountId = accountId
        self.kind = kind
        self.url = url
        self.username = username
        self.password = password
    }
}

/// `RsvpResponse` in `types.ts`: our answer to an invite.
public enum RsvpResponse: String, Codable, Sendable, CaseIterable {
    case accepted, tentative, declined
}
