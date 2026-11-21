import Foundation
import XCTest
@testable import RabeIntents
@testable import RabeKit

/// M3.3: Texte und Logik der Intents — ohne Siri, ohne laufende App.
final class M33IntentsTests: XCTestCase {
    private let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // RabeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // macos

    override func tearDown() {
        IntentDependencies.reset()
        super.tearDown()
    }

    // MARK: Dialogtexte

    func testDigitsAreSpokenOneByOne() {
        XCTAssertEqual(IntentText.spokenDigits("482913"), "4 8 2 9 1 3")
        XCTAssertEqual(IntentText.spokenDigits("48 29 13"), "4 8 2 9 1 3",
                       "Leerzeichen im Code stören die Sprachausgabe nicht")
        XCTAssertEqual(IntentText.spokenDigits(""), "")
    }

    func testCitationMarkersAreRemoved() {
        XCTAssertEqual(IntentText.stripCitations("a [1] b [2, 3]."), "a b.")
        XCTAssertEqual(IntentText.stripCitations("Lieferung am Freitag [12]"), "Lieferung am Freitag")
        XCTAssertEqual(IntentText.stripCitations("ohne Marker"), "ohne Marker")
        XCTAssertEqual(IntentText.stripCitations("  "), "")
    }

    func testUnreadLineHasSingularAndEmptyCase() {
        XCTAssertEqual(IntentText.unreadLine(0), "Der Posteingang ist leer.")
        XCTAssertEqual(IntentText.unreadLine(1), "Du hast 1 ungelesene Mail im Posteingang.")
        XCTAssertEqual(IntentText.unreadLine(3), "Du hast 3 ungelesene Mails im Posteingang.")
    }

    func testOverviewShowsAtMostSixAndCountsTheRest() {
        let lines = (1...9).map { (sender: "Absender \($0)", subject: "Betreff \($0)") }
        let text = IntentText.overview(lines, total: 9)
        let rows = text.split(separator: "\n")
        XCTAssertEqual(rows.first, "9 ungelesene Mails im Posteingang:")
        XCTAssertEqual(rows.count, 1 + 6 + 1, "Kopfzeile, sechs Zeilen, Rest")
        XCTAssertEqual(rows[1], "Absender 1: Betreff 1")
        XCTAssertEqual(rows.last, "… und 3 weitere.")
    }

    func testOverviewWithoutUnreadSaysEverythingIsRead() {
        XCTAssertEqual(IntentText.overview([], total: 0), "Alles gelesen.")
        XCTAssertEqual(IntentText.overview([("A", "B")], total: 0), "Alles gelesen.")
    }

    func testCodeLineMentionsSenderAndCopy() {
        XCTAssertEqual(IntentText.codeLine(sender: "Shop", digits: "1 2 3", copied: true),
                       "Code von Shop: 1 2 3 – kopiert")
        XCTAssertEqual(IntentText.codeLine(sender: "", digits: "1 2 3", copied: false), "Code: 1 2 3")
        XCTAssertEqual(IntentText.noCodeLine(minutes: 30), "Kein Bestätigungscode in den letzten 30 Minuten.")
    }

    // MARK: Logik gegen eine Attrappe

    func testVerificationCodeAsksForThirtyMinutesAndCopies() async throws {
        let host = FakeHost()
        host.code = VerificationCode(code: "482913", messageId: 7, threadId: 8,
                                     sender: "Shop", subject: "Dein Code", receivedAt: 0)
        IntentDependencies.register(host)

        let answer = try await IntentLogic.verificationCode(copy: true)

        XCTAssertEqual(host.requestedMaxAge, 30)
        XCTAssertEqual(answer.value, "482913")
        XCTAssertEqual(answer.dialog, "Code von Shop: 4 8 2 9 1 3 – kopiert")
        XCTAssertEqual(host.copied, "482913")
    }

    func testWithoutACopyTheDialogSaysSo() async throws {
        let host = FakeHost()
        host.code = VerificationCode(code: "482913", messageId: 7, threadId: 8,
                                     sender: "Shop", subject: "Dein Code", receivedAt: 0)
        IntentDependencies.register(host)

        let answer = try await IntentLogic.verificationCode(copy: false)

        XCTAssertNil(host.copied)
        XCTAssertEqual(answer.dialog, "Code von Shop: 4 8 2 9 1 3")
    }

    func testWithoutACodeTheWindowIsNamed() async throws {
        let host = FakeHost()
        IntentDependencies.register(host)

        let answer = try await IntentLogic.verificationCode(copy: true)

        XCTAssertEqual(answer.value, "")
        XCTAssertEqual(answer.dialog, "Kein Bestätigungscode in den letzten 30 Minuten.")
        XCTAssertNil(host.copied, "ohne Code wird nichts kopiert")
    }

    func testUnreadCountAndDialog() async throws {
        let host = FakeHost()
        host.unread = 3
        IntentDependencies.register(host)

        let answer = try await IntentLogic.unreadCount()

        XCTAssertEqual(answer.value, 3)
        XCTAssertEqual(answer.dialog, "Du hast 3 ungelesene Mails im Posteingang.")
    }

    func testOverviewUsesTheThreadsAndTheTotal() async throws {
        let host = FakeHost()
        host.unread = 2
        host.threads = [try thread(id: 1, sender: "Shop", subject: "Rechnung"),
                        try thread(id: 2, sender: "Anna", subject: "Kaffee")]
        IntentDependencies.register(host)

        let answer = try await IntentLogic.overview()

        XCTAssertEqual(host.requestedLimit, 6)
        XCTAssertTrue(answer.dialog.hasPrefix("2 ungelesene Mails im Posteingang:"))
        XCTAssertTrue(answer.dialog.contains("Shop: Rechnung"))
        XCTAssertTrue(answer.dialog.contains("Anna: Kaffee"))
    }

    func testAskStripsCitations() async throws {
        let host = FakeHost()
        host.answer = "Die Lieferung kommt Freitag [1]."
        IntentDependencies.register(host)

        let answer = try await IntentLogic.ask(question: "Wann kommt die Lieferung?")

        XCTAssertEqual(host.question, "Wann kommt die Lieferung?")
        XCTAssertEqual(answer.dialog, "Die Lieferung kommt Freitag.")
    }

    func testAskWithoutAIExplainsInsteadOfShowingRawText() async throws {
        let host = FakeHost()
        host.askError = IntentFailure.aiNotConfigured
        IntentDependencies.register(host)

        do {
            _ = try await IntentLogic.ask(question: "Was ist neu?")
            XCTFail("ohne KI muss ein Hinweis kommen")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure.errorDescription, "KI ist nicht eingerichtet (Einstellungen → Intelligenz).")
        }
    }

    func testAnUnknownErrorBecomesAReadableMessage() {
        struct Raw: Error { let text = "dispatch failed: unknown command ai_ask" }
        let mapped = IntentRun.failure(Raw())
        XCTAssertEqual((mapped as? IntentFailure)?.errorDescription,
                       "Das hat nicht geklappt. Bitte in Corax noch einmal versuchen.")
    }

    func testAHostThatIsNotReadySaysSo() async throws {
        let host = FakeHost()
        host.ready = false
        IntentDependencies.register(host)

        do {
            _ = try await IntentLogic.unreadCount()
            XCTFail("ohne bereite Sitzung darf nichts gezählt werden")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure, .notReady)
            XCTAssertEqual(failure.errorDescription, "Corax startet noch – bitte gleich noch einmal.")
        }
    }

    func testWithoutRegisteredHostNothingRuns() async throws {
        do {
            _ = try await IntentLogic.unreadCount()
            XCTFail("ohne Registrierung kein Ergebnis")
        } catch let failure as IntentFailure {
            XCTAssertEqual(failure, .notReady)
        }
    }

    func testComposeOpensADraftAndNeverSends() async throws {
        let host = FakeHost()
        IntentDependencies.register(host)

        _ = try await IntentLogic.compose(to: "a@example.invalid", subject: "Hallo", body: "Text")

        XCTAssertEqual(host.composed?.to, "a@example.invalid")
        XCTAssertEqual(host.composed?.subject, "Hallo")
        XCTAssertEqual(host.composed?.body, "Text")
        XCTAssertFalse(host.didSend, "ein Intent sendet nie")
    }

    func testSearchStartsTheSearch() async throws {
        let host = FakeHost()
        IntentDependencies.register(host)

        _ = try await IntentLogic.search("Rechnung")

        XCTAssertEqual(host.searched, "Rechnung")
    }

    // MARK: Start

    func testStartupRegistersTheHostAndAnnouncesTheShortcuts() {
        let host = FakeHost()
        var announced = 0
        IntentStartup.install(host: host, updateShortcuts: { announced += 1 })
        XCTAssertNotNil(IntentDependencies.host, "der Intent findet die Sitzung")
        XCTAssertEqual(announced, 1, "Apple verlangt den Aufruf beim Start")
    }

    func testTheAppInstallsTheIntentsAtLaunch() throws {
        let source = try String(contentsOf: packageDirectory
            .appendingPathComponent("Sources/Rabe/App/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("func applicationWillFinishLaunching"))
        XCTAssertTrue(source.contains("IntentStartup.install(host: AppIntentHost())"),
                      "ohne diesen Aufruf registriert sich nichts")
    }

    // MARK: Bauschritt

    func testTheBuildScriptProducesTheIntentMetadata() throws {
        let script = try String(contentsOf: packageDirectory.appendingPathComponent("scripts/build-app.sh"),
                                encoding: .utf8)
        XCTAssertTrue(script.contains("appintentsmetadataprocessor"))
        XCTAssertTrue(script.contains("Metadata.appintents"))
        XCTAssertTrue(script.contains("extract.actionsdata"))
        XCTAssertTrue(script.contains("CFBundleDevelopmentRegion"))
        XCTAssertTrue(script.contains("--module-name RabeIntents"))
    }

    // MARK: Hilfen

    private func thread(id: Int64, sender: String, subject: String) throws -> ThreadSummary {
        let json = """
        {"id":\(id),"accountId":1,"accountEmail":"me@example.invalid","subject":"\(subject)",
         "snippet":"","participants":[{"name":"\(sender)","email":"\(sender.lowercased())@example.invalid"}],
         "lastMessageAt":0,"messageCount":1,"unreadCount":1,"isStarred":false,"hasAttachments":false,"labels":[]}
        """
        return try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
    }
}

/// Attrappe der Sitzung: merkt sich, was abgefragt wurde, und kann jeden Fall
/// nachstellen (Treffer, kein Treffer, Fehler, keine Bereitschaft).
private final class FakeHost: IntentHost, @unchecked Sendable {
    private let lock = NSLock()
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var ready = true
    var code: VerificationCode?
    var unread = 0
    var threads: [ThreadSummary] = []
    var answer = ""
    var askError: Error?
    var askFailure: IntentFailure?

    private(set) var requestedMaxAge: Int?
    private(set) var requestedLimit: Int?
    private(set) var copied: String?
    private(set) var question: String?
    private(set) var composed: (to: String?, subject: String?, body: String?)?
    private(set) var searched: String?
    private(set) var didSend = false

    func waitUntilReady(timeout: Duration) async -> Bool { withLock { ready } }

    func latestVerificationCode(maxAgeMinutes: Int) async throws -> VerificationCode? {
        withLock { requestedMaxAge = maxAgeMinutes; return code }
    }

    func copyToClipboard(_ text: String) async { withLock { copied = text } }

    func unreadInboxCount() async throws -> Int { withLock { unread } }

    func unreadInboxThreads(limit: Int) async throws -> [ThreadSummary] {
        withLock { requestedLimit = limit; return threads }
    }

    func ask(_ question: String) async throws -> String {
        if let askError { throw askError }
        return withLock { self.question = question; return answer }
    }

    @MainActor func compose(to: String?, subject: String?, body: String?) {
        composed = (to, subject, body)
    }

    @MainActor func search(_ query: String) {
        searched = query
    }
}
