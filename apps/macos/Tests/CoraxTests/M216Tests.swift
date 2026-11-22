import XCTest
@testable import CoraxKit

/// M2.16: `action:failed` — a move the core gave up on reaches the UI with a
/// reason the app can turn into a German sentence.
final class M216Tests: XCTestCase {

    func testActionFailedEventCarriesReasonAndThread() {
        let line = #"{"name":"action:failed","payload":{"actionId":9,"kind":"move","threadId":42,"reason":"source_missing","error":"move: the source message is not on the server"}}"#
        guard let event = EventRouter.parse(line) else { return XCTFail("kein Event") }
        guard case .actionFailed(let actionId, let threadId, let kind, let reason, let error) = event else {
            return XCTFail("falscher Fall: \(event)")
        }
        XCTAssertEqual(actionId, 9)
        XCTAssertEqual(threadId, 42)
        XCTAssertEqual(kind, "move")
        XCTAssertEqual(reason, "source_missing")
        XCTAssertEqual(error, "move: the source message is not on the server")
    }

    func testActionFailedWithoutThreadId() {
        let line = #"{"name":"action:failed","payload":{"actionId":10,"kind":"trash","threadId":null,"reason":"deferral_exhausted","error":"gone"}}"#
        guard let event = EventRouter.parse(line),
              case .actionFailed(_, let threadId, let kind, let reason, _) = event else {
            return XCTFail("kein action:failed")
        }
        XCTAssertNil(threadId)
        XCTAssertEqual(kind, "trash")
        XCTAssertEqual(reason, "deferral_exhausted")
    }

    func testMoveFailureTextFollowsTheKind() {
        XCTAssertEqual(Strings.moveFailure(kind: "move"), "Verschieben nicht möglich")
        XCTAssertEqual(Strings.moveFailure(kind: "trash"), "In den Papierkorb verschieben nicht möglich")
        XCTAssertEqual(Strings.moveFailure(kind: "archive"), "Archivieren nicht möglich")
        XCTAssertEqual(Strings.moveFailure(kind: "unbekannt"), "Verschieben nicht möglich")
        XCTAssertEqual(Strings.moveSourceMissing, "Mail auf dem Server nicht gefunden")
    }
}
