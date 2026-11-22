import Foundation

// MARK: - Arguments of the calendar commands (M2.2)

extension IPCArgs {
    /// `list_events(args)`: `{startMs, endMs}`.
    struct ListEvents: Encodable, Sendable { let startMs: Int64; let endMs: Int64 }
    /// `events_for_message(args)`: `{messageId}`.
    struct EventsForMessage: Encodable, Sendable { let messageId: Int64 }
    /// `rsvp_event(args)`: `{args: {eventId, response}}`.
    struct RsvpEvent: Encodable, Sendable { let eventId: Int64; let response: RsvpResponse }
    /// `delete_event(args)`: `{eventId, notify}` (notify defaults to true).
    struct DeleteEvent: Encodable, Sendable { let eventId: Int64; let notify: Bool }
    /// `list_calendars(args)`: `{accountId?}`.
    struct ListCalendars: Encodable, Sendable { let accountId: Int64? }
    struct SetCalendarEnabled: Encodable, Sendable { let calendarId: Int64; let enabled: Bool }
    struct SetCalendarColor: Encodable, Sendable { let calendarId: Int64; let color: String? }
    struct SetDefaultCalendar: Encodable, Sendable { let calendarId: Int64 }
    /// `calendar_sync_now(args)`: `{accountId?}`.
    struct CalendarSyncNow: Encodable, Sendable { let accountId: Int64? }
}

/// The part of the core client the calendar uses. A protocol so the store can be
/// driven by `FakeCalendarCore` without a running Rust core.
public protocol CalendarCore: Sendable {
    func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent]
    func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent]
    func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent
    func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent
    func deleteEvent(_ id: Int64, notify: Bool) async throws
    func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent
    func listCalendars(accountId: Int64?) async throws -> [CalendarCollection]
    func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws
    func setCalendarColor(_ id: Int64, color: String?) async throws
    func setDefaultCalendar(_ id: Int64) async throws
    func calendarSyncNow(accountId: Int64?) async throws
    /// M2.12: CalDAV connect (`connect_calendar`). The core runs discovery
    /// against `url` with `username`/`password`, stores the password in the
    /// keychain and returns the collections it found.
    func connectCalendar(_ args: ConnectCalendarArgs) async throws -> [CalendarCollection]
}

extension CalendarCore {
    /// Test doubles that never connect a calendar keep compiling; the settings
    /// view reports the refusal instead of pretending success.
    public func connectCalendar(_ args: ConnectCalendarArgs) async throws -> [CalendarCollection] {
        throw CoraxClientError.core(code: "unsupported",
                                   message: "connect_calendar is not supported by this client")
    }
}

// MARK: - Typed wrappers

extension CoraxClient: CalendarCore {
    public func listEvents(startMs: Int64, endMs: Int64) async throws -> [CalendarEvent] {
        try await call("list_events", IPCArgs.ListEvents(startMs: startMs, endMs: endMs))
    }

    public func eventsForMessage(_ messageId: Int64) async throws -> [CalendarEvent] {
        try await call("events_for_message", IPCArgs.EventsForMessage(messageId: messageId))
    }

    public func createEvent(_ args: CreateEventArgs) async throws -> CalendarEvent {
        try await call("create_event", WithArgs(args: args))
    }

    public func updateEvent(_ args: UpdateEventArgs) async throws -> CalendarEvent {
        try await call("update_event", WithArgs(args: args))
    }

    public func deleteEvent(_ id: Int64, notify: Bool = true) async throws {
        try await send("delete_event", IPCArgs.DeleteEvent(eventId: id, notify: notify))
    }

    public func rsvpEvent(_ id: Int64, response: RsvpResponse) async throws -> CalendarEvent {
        try await call("rsvp_event", WithArgs(args: IPCArgs.RsvpEvent(eventId: id, response: response)))
    }

    public func listCalendars(accountId: Int64? = nil) async throws -> [CalendarCollection] {
        try await call("list_calendars", IPCArgs.ListCalendars(accountId: accountId))
    }

    public func setCalendarEnabled(_ id: Int64, enabled: Bool) async throws {
        try await send("set_calendar_enabled", IPCArgs.SetCalendarEnabled(calendarId: id, enabled: enabled))
    }

    public func setCalendarColor(_ id: Int64, color: String?) async throws {
        try await send("set_calendar_color", IPCArgs.SetCalendarColor(calendarId: id, color: color))
    }

    public func setDefaultCalendar(_ id: Int64) async throws {
        try await send("set_default_calendar", IPCArgs.SetDefaultCalendar(calendarId: id))
    }

    public func calendarSyncNow(accountId: Int64? = nil) async throws {
        try await send("calendar_sync_now", IPCArgs.CalendarSyncNow(accountId: accountId))
    }

    /// M2.12: the same payload the Tauri command takes — `{"args": {…}}`.
    public func connectCalendar(_ args: ConnectCalendarArgs) async throws -> [CalendarCollection] {
        try await call("connect_calendar", WithArgs(args: args))
    }
}
