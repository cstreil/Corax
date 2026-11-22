import XCTest
@testable import Corax
@testable import CoraxKit

/// M2.7 / N1 aus dem Audit M2: the subject filter removes only Cc.
///
/// `CharacterSet.controlCharacters` holds Cc **and** Cf, so the first version
/// tore emoji sequences apart (ZWJ) and dropped the bidi marks that Hebrew and
/// Arabic text needs — also in a reply to a foreign subject. The core applies
/// the same rule in `build_message` (`sanitize_subject`).
@MainActor
final class HeaderSafetyTests: XCTestCase {
    /// A subject as it arrives from a foreign mail: family emoji, rainbow flag,
    /// Hebrew with RLM, Arabic with ALM.
    private let foreign = "👨‍👩‍👧 🏳️‍🌈 שלום\u{200F} עולם / مرحبا\u{061C} بالعالم"

    func testSubjectKeepsEmojiSequencesAndBidiMarks() {
        XCTAssertEqual(HeaderSafety.subject(foreign), foreign)
        XCTAssertEqual(HeaderSafety.subject("👨‍👩‍👧"), "👨‍👩‍👧")
        XCTAssertEqual(HeaderSafety.subject("🏳️‍🌈"), "🏳️‍🌈")
        XCTAssertEqual(HeaderSafety.subject("שלום\u{200F}"), "שלום\u{200F}")
        XCTAssertEqual(HeaderSafety.subject("مرحبا\u{061C}"), "مرحبا\u{061C}")
        // A Cf-only subject takes the fast path and stays byte for byte.
        XCTAssertEqual(HeaderSafety.subject("\u{200D}"), "\u{200D}")
    }

    func testSubjectStillFoldsLineBreaksAndDropsOtherControlCharacters() {
        XCTAssertEqual(HeaderSafety.subject("Hallo\r\nBcc: x@y"), "Hallo Bcc: x@y")
        XCTAssertEqual(HeaderSafety.subject("a\t\tb"), "a b")
        XCTAssertEqual(HeaderSafety.subject("a\r\n\t b"), "a b")
        XCTAssertEqual(HeaderSafety.subject("a  \r\nb"), "a b")
        XCTAssertEqual(HeaderSafety.subject("a\u{0007}b"), "ab")
        XCTAssertEqual(HeaderSafety.subject("a\u{0085}b"), "ab")
        XCTAssertEqual(HeaderSafety.subject("\r\nHallo\r\n"), "Hallo")
        // Two typed spaces are not a control character and stay as typed.
        XCTAssertEqual(HeaderSafety.subject("a  b"), "a  b")
    }

    /// "Re: " on a foreign subject: the prefix is added, the characters stay.
    func testReplyToAForeignSubjectKeepsItsCharacters() async {
        let core = FakeCore()
        let draft = ComposeDraft(mode: .reply, accountId: 1, inReplyTo: 7,
                                 to: [Address(name: nil, email: "a@b.de")], cc: [],
                                 subject: "Re: " + foreign, body: "x", client: core,
                                 toasts: ToastCenter(), settings: SettingsStore())
        XCTAssertEqual(draft.subject, "Re: " + foreign)
        _ = await draft.saveNow()
        let saved = await core.savedDrafts.last
        XCTAssertEqual(saved?.subject, "Re: " + foreign)
    }
}
