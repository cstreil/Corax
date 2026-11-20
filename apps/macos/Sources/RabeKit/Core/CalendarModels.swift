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
    public init(_ event: CalendarEvent, startsAt: Int64, endsAt: Int64, notify: Bool = true) {
        self.init(eventId: event.id, summary: event.summary ?? "", description: event.description,
                  location: event.location, joinUrl: event.joinUrl, startsAt: startsAt, endsAt: endsAt,
                  allDay: event.allDay,
                  attendees: event.attendees.map { Address(name: $0.name, email: $0.email) },
                  notify: notify)
    }
}

/// `RsvpResponse` in `types.ts`: our answer to an invite.
public enum RsvpResponse: String, Codable, Sendable, CaseIterable {
    case accepted, tentative, declined
}
