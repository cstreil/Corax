import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.18c: iCloud trägt bei eigenen Terminen als Organisator oft nur die
/// Kontokennung ein (`/aODc…/principal/`) statt der Mailadresse. Dieselbe Regel
/// wie im Kern (`calendar::edit_blocked_reason`): nur die **eigene** Kennung des
/// Zugangs zählt, verglichen über den Pfad; unbekannt oder fremd bleibt gesperrt.
final class M218dTests: XCTestCase {
    private let ownPrincipal = "https://p01-caldav.example/123456/principal/"
    private let me: Set<String> = ["cs@example.test"]

    private func calendar(principal: String?, accountId: Int64 = 1,
                          readOnly: Bool = false) -> CalendarCollection {
        CalendarCollection(id: 1, accountId: accountId, url: "https://p01.example/cal/1/",
                           displayName: "Kalender", color: nil, readOnly: readOnly,
                           enabled: true, isDefault: true, lastSyncedAt: nil,
                           principalUrl: principal)
    }

    private func event(organizer: String?, accountId: Int64 = 1,
                       calendarId: Int64? = 1, local: Bool = false) -> CalendarEvent {
        CalendarEvent(id: 42, accountId: accountId, messageId: nil, summary: "Termin",
                      location: nil, organizer: organizer, description: nil, attendees: [],
                      joinUrl: nil, rsvpStatus: nil, isLocal: local, calendarId: calendarId,
                      rrule: nil, startsAt: 1_795_000_000_000, endsAt: 1_795_003_600_000,
                      allDay: false, status: "CONFIRMED", method: nil)
    }

    /// M2.18e: In Corax angelegt bleibt bearbeitbar — auch mit einem fremd
    /// wirkenden Organisator, den iCloud beim Hochladen eintragen kann.
    func testASelfCreatedEventStaysEditable() {
        let calendars = [calendar(principal: ownPrincipal)]
        for organizer in ["boss@example.test", "/654321/principal/", nil] {
            let created = event(organizer: organizer, local: true)
            XCTAssertNil(CalendarPermissions.blockReason(created, calendars: calendars,
                                                         ownEmails: me),
                         "selbst angelegt ist bearbeitbar: \(organizer ?? "leer")")
        }
        // Gezogen und fremd bleibt gesperrt.
        let pulled = event(organizer: "boss@example.test", local: false)
        XCTAssertEqual(CalendarPermissions.blockReason(pulled, calendars: calendars, ownEmails: me),
                       "only the organizer can edit this event")
    }

    /// Der gemeldete Fall: iCloud trägt die eigene Kontokennung ein.
    func testTheOwnPrincipalIsNotAForeignOrganizer() {
        let calendars = [calendar(principal: ownPrincipal)]
        let event = event(organizer: "/123456/principal/")
        XCTAssertFalse(CalendarPermissions.hasForeignOrganizer(event, ownEmails: me,
                                                              calendars: calendars))
        XCTAssertTrue(CalendarPermissions.canEdit(event, calendars: calendars, ownEmails: me))
    }

    /// Verglichen wird nur der Pfad: anderer Host, Schluss-`/`, Schreibweise.
    func testHostCaseAndTrailingSlashDoNotMatter() {
        let calendars = [calendar(principal: ownPrincipal)]
        for organizer in ["http://other-host.example/123456/PRINCIPAL",
                          "https://p01-caldav.example/123456/principal",
                          "/123456/principal/"] {
            let event = event(organizer: organizer)
            XCTAssertTrue(CalendarPermissions.canEdit(event, calendars: calendars, ownEmails: me),
                          "gilt als eigene Kennung: \(organizer)")
        }
    }

    /// Ein freigegebener oder fremder Kalender kann dieselbe Form tragen.
    func testAForeignPrincipalStaysLocked() {
        let calendars = [calendar(principal: ownPrincipal)]
        let event = event(organizer: "/654321/principal/")
        XCTAssertTrue(CalendarPermissions.hasForeignOrganizer(event, ownEmails: me,
                                                             calendars: calendars))
        XCTAssertEqual(CalendarPermissions.blockReason(event, calendars: calendars, ownEmails: me),
                       "only the organizer can edit this event")
    }

    /// Ohne gespeicherte Kennung wird nicht geraten.
    func testAnUnknownPrincipalStaysLocked() {
        for calendars in [[calendar(principal: nil)], []] {
            let event = event(organizer: "/123456/principal/")
            XCTAssertEqual(CalendarPermissions.blockReason(event, calendars: calendars,
                                                           ownEmails: me),
                           "only the organizer can edit this event")
        }
    }

    /// Die Kennung eines anderen Kontos zählt nicht.
    func testThePrincipalOfAnotherAccountDoesNotCount() {
        let calendars = [calendar(principal: ownPrincipal, accountId: 1)]
        let event = event(organizer: "/123456/principal/", accountId: 2)
        XCTAssertEqual(CalendarPermissions.blockReason(event, calendars: calendars, ownEmails: me),
                       "only the organizer can edit this event")
    }

    /// Mailadressen behalten ihre alte Regel.
    func testMailAddressesKeepTheirRule() {
        let calendars = [calendar(principal: ownPrincipal)]
        XCTAssertTrue(CalendarPermissions.canEdit(event(organizer: "mailto:CS@example.test"),
                                                  calendars: calendars, ownEmails: me))
        XCTAssertEqual(CalendarPermissions.blockReason(event(organizer: "boss@example.test"),
                                                       calendars: calendars, ownEmails: me),
                       "only the organizer can edit this event")
    }

    /// Gleiche Normalisierung wie im Kern (`calendar::normalize_principal`).
    func testThePathNormalizationMatchesTheCore() {
        XCTAssertEqual(CalendarPermissions.principalPath("https://p01.example/abc/principal/"),
                       "abc/principal")
        XCTAssertEqual(CalendarPermissions.principalPath("/abc/PRINCIPAL"), "abc/principal")
        XCTAssertEqual(CalendarPermissions.principalPath("http://host.example"), nil)
        XCTAssertEqual(CalendarPermissions.principalPath("   "), nil)
        XCTAssertEqual(CalendarPermissions.principalPath(nil), nil)
    }

    /// Ein schreibgeschützter Kalender bleibt schreibgeschützt.
    func testAReadOnlyCalendarStillBlocks() {
        let calendars = [calendar(principal: ownPrincipal, readOnly: true)]
        XCTAssertEqual(CalendarPermissions.blockReason(event(organizer: "/123456/principal/"),
                                                       calendars: calendars, ownEmails: me),
                       "calendar is read-only")
    }
}
