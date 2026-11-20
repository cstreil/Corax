import XCTest
@testable import Rabe
@testable import RabeKit

/// M2.4: the pieces that are pure logic or run off the view — `mailto:` parsing,
/// the streaming throttle, the partial summary, the sender-picture cache, the
/// streamed answer/draft and the two small mail actions. No network, no key, no
/// window: `FakeCore` stands in for the host.
@MainActor
final class M24Tests: XCTestCase {
    // MARK: - mailto: (requirement 3)

    func testMailtoParsesAddressSubjectAndBody() throws {
        let link = try XCTUnwrap(MailtoLink.parse("mailto:test@example.org?subject=Hallo%20Welt&body=Zeile%201"))
        XCTAssertEqual(link.to, ["test@example.org"])
        XCTAssertEqual(link.subject, "Hallo Welt")
        XCTAssertEqual(link.body, "Zeile 1")
        XCTAssertTrue(link.cc.isEmpty)
        XCTAssertFalse(link.isEmpty)
    }

    func testMailtoDecodesUTF8() throws {
        let link = try XCTUnwrap(MailtoLink.parse("mailto:ana@example.org?subject=Gr%C3%BC%C3%9Fe&body=Sch%C3%B6n%2C%20dass%20du%20da%20bist"))
        XCTAssertEqual(link.subject, "Grüße")
        XCTAssertEqual(link.body, "Schön, dass du da bist")
    }

    func testMailtoTakesRecipientListsAndCcAndBcc() throws {
        let link = try XCTUnwrap(MailtoLink.parse(
            "mailto:a@example.org,b@example.org?to=c@example.org&cc=d@example.org,e@example.org&bcc=f@example.org"))
        XCTAssertEqual(link.to, ["a@example.org", "b@example.org", "c@example.org"])
        XCTAssertEqual(link.cc, ["d@example.org", "e@example.org"])
        XCTAssertEqual(link.bcc, ["f@example.org"])
        XCTAssertEqual(link.toAddresses.map(\.email), link.to)
    }

    /// RFC 6068: `+` is a literal plus sign in mailto, not a space. The encoded
    /// comma (`%2C`) is refused since the M2 audit (W1): written unquoted it
    /// turns one recipient into two.
    func testMailtoKeepsPlusAndRefusesEncodedComma() throws {
        let link = try XCTUnwrap(MailtoLink.parse("mailto:list%2Ctag@example.org?body=a+b&subject=x"))
        XCTAssertTrue(link.to.isEmpty, "ein Adress-Komma darf nicht als zweiter Empfänger landen")
        XCTAssertEqual(link.body, "a+b")
        XCTAssertEqual(link.subject, "x")
    }

    /// W1 aus dem Audit M2: `mail-builder` schreibt Adressen roh, deshalb darf
    /// keine Adresse mit Steuerzeichen, Leerzeichen oder spitzen Klammern aus
    /// einem fremden Link in den Entwurf. Der Link selbst bleibt gültig.
    func testMailtoDropsAddressesThatCouldBreakOutOfTheHeader() throws {
        let link = try XCTUnwrap(MailtoLink.parse(
            "mailto:gut@example.org,boese%0D%0ABcc:opfer@example.org,mit%20leer@example.org,"
            + "%3Cx@y%3E,hal%22b@example.org,ohne-at?subject=Hallo"))
        XCTAssertEqual(link.to, ["gut@example.org"])
        XCTAssertEqual(link.subject, "Hallo")
        // Only bad addresses: nothing is left to open a composer for.
        let empty = try XCTUnwrap(MailtoLink.parse("mailto:boese%0D%0ABcc:opfer@example.org"))
        XCTAssertTrue(empty.isEmpty)
    }

    func testMailtoIsCaseInsensitiveAndIgnoresUnknownFields() throws {
        let link = try XCTUnwrap(MailtoLink.parse("MAILTO:A@example.org?subject=x&charset=utf-8&in-reply-to=%3Cid%40x%3E"))
        XCTAssertEqual(link.to, ["A@example.org"])
        XCTAssertEqual(link.subject, "x")
        XCTAssertEqual(link.inReplyTo, "<id@x>")
    }

    func testMailtoRejectsBrokenInput() {
        XCTAssertNil(MailtoLink.parse("https://example.org/?subject=x"))
        XCTAssertNil(MailtoLink.parse("mailto"))
        // An invalid escape would put a wrong address into a draft.
        XCTAssertNil(MailtoLink.parse("mailto:a%zz@example.org"))
        XCTAssertNil(MailtoLink.parse("mailto:a@example.org?subject=100%"))
    }

    func testEmptyMailtoOpensNoDraftFields() throws {
        let link = try XCTUnwrap(MailtoLink.parse("mailto:"))
        XCTAssertTrue(link.isEmpty)
    }

    // MARK: - Throttle (requirement 4)

    func testThrottlePublishesAtMostThirtyTimesASecond() {
        var throttle = TokenThrottle()
        var publishes = 0
        var shown = ""
        // 200 tokens, 5 ms apart = one second of streaming.
        for step in 0..<200 {
            let now = Double(step) * 0.005
            if throttle.append("x", at: now) {
                publishes += 1
                shown += throttle.take()
            }
        }
        if let rest = throttle.flush(at: 1.0) { shown += rest }
        XCTAssertLessThanOrEqual(publishes, 31, "mehr als 30 Updates pro Sekunde")
        XCTAssertGreaterThanOrEqual(publishes, 28, "zu grob gedrosselt")
        XCTAssertEqual(shown.count, 200, "kein Zeichen darf verloren gehen")
    }

    func testThrottleFlushGivesBackTheHeldText() {
        var throttle = TokenThrottle()
        XCTAssertTrue(throttle.append("a", at: 0))
        XCTAssertEqual(throttle.take(), "a")
        XCTAssertFalse(throttle.append("b", at: 0.005))
        XCTAssertTrue(throttle.hasPending)
        XCTAssertEqual(throttle.flush(at: 0.005), "b")
        XCTAssertFalse(throttle.hasPending)
        XCTAssertNil(throttle.flush(at: 0.2))
    }

    // MARK: - Partial summary (requirement 4)

    func testPartialSummaryReadsWhatIsComplete() {
        let raw = #"{"timeline":[{"actor":"Ana","event":"schickt die Rechnung"},{"actor":"Du","ev"#
        let partial = PartialSummary.parse(raw)
        XCTAssertEqual(partial?.timeline.count, 1)
        XCTAssertEqual(partial?.timeline.first?.actor, "Ana")
        XCTAssertEqual(partial?.keyPoints.count, 0)
    }

    func testPartialSummaryReadsKeyPointsOfAnUnfinishedList() {
        let raw = "\"keyPoints\":[\"Rechnung offen\",\"Zahlung bis Freitag\"],\"nextAction\":null"
        let partial = PartialSummary.parse(raw)
        XCTAssertEqual(partial?.keyPoints, ["Rechnung offen", "Zahlung bis Freitag"])
        XCTAssertNil(partial?.nextAction)
    }

    func testPartialSummaryOfAnEmptyStreamIsNil() {
        XCTAssertNil(PartialSummary.parse(""))
        XCTAssertNil(PartialSummary.parse(#"{"timeline":["#))
    }

    func testPartialSummaryTakesTheWholeAnswer() {
        let raw = #"{"timeline":[{"actor":"Ana","event":"schickt die Rechnung"}],"keyPoints":["Rechnung offen"],"nextAction":"Zahlen","proposedReply":"Mache ich.","calendarSuggestion":{"title":"Termin","start":"2026-11-24T14:00:00+01:00","allDay":false}}"#
        let summary = PartialSummary.parse(raw)
        XCTAssertEqual(summary?.keyPoints, ["Rechnung offen"])
        XCTAssertEqual(summary?.nextAction, "Zahlen")
        XCTAssertEqual(summary?.proposedReply, "Mache ich.")
        XCTAssertEqual(summary?.calendarSuggestion?.title, "Termin")
    }

    // MARK: - Sender pictures (requirement 1)

    private func dataURL(_ bytes: [UInt8]) -> String { testDataURL(bytes) }

    func testDataURLDecoding() {
        XCTAssertEqual(AvatarPhotos.decodeDataURL(dataURL([1, 2, 3])), Data([1, 2, 3]))
        // Percent-encoded payloads, foreign schemes and truncation are no picture.
        XCTAssertNil(AvatarPhotos.decodeDataURL("data:image/png,%01%02"))
        XCTAssertNil(AvatarPhotos.decodeDataURL("https://example.org/a.png"))
        XCTAssertNil(AvatarPhotos.decodeDataURL("data:image/png;base64"))
    }

    func testAvatarIsFetchedOnceAndRemembered() async throws {
        let counter = Counter()
        let photos = AvatarPhotos(resolve: { email in
            await counter.bump()
            return email.hasPrefix("a") ? testDataURL([7, 7]) : nil
        })
        photos.request("ana@example.test")
        photos.request("ana@example.test")
        await photos.waitUntilIdle()
        let firstLookups = await counter.value
        XCTAssertEqual(firstLookups, 1, "zweimal gefragt")
        XCTAssertEqual(photos.photo(for: "ANA@example.test"), Data([7, 7]))
        XCTAssertNil(photos.entry(for: "bell@example.test"))
        photos.request("bell@example.test")
        await photos.waitUntilIdle()
        XCTAssertEqual(photos.entry(for: "bell@example.test"), AvatarPhotos.Entry.none)
        // A miss is remembered too: no second network call for the same sender.
        photos.request("bell@example.test")
        await photos.waitUntilIdle()
        let lookups = await counter.value
        XCTAssertEqual(lookups, 2)
    }

    func testAvatarCacheEvictsTheLeastRecentlyRequested() async throws {
        let photos = AvatarPhotos(capacity: 2, resolve: { email in testDataURL([UInt8(email.count % 200)]) })
        photos.request("a@x.test")
        await photos.waitUntilIdle()
        photos.request("b@x.test")
        await photos.waitUntilIdle()
        photos.request("c@x.test")
        await photos.waitUntilIdle()
        XCTAssertNil(photos.photo(for: "a@x.test"), "ältester Eintrag muss weichen")
        XCTAssertNotNil(photos.photo(for: "b@x.test"))
        XCTAssertNotNil(photos.photo(for: "c@x.test"))
    }

    func testAvatarCacheRespectsTheByteBudget() async throws {
        // Three pictures of 100 bytes each, budget for two.
        let photos = AvatarPhotos(capacity: 10, byteBudget: 250, resolve: { _ in testDataURL([UInt8](repeating: 1, count: 100)) })
        for email in ["a@x.test", "b@x.test", "c@x.test"] {
            photos.request(email)
            await photos.waitUntilIdle()
        }
        XCTAssertLessThanOrEqual(photos.bytes, 250)
        XCTAssertNil(photos.photo(for: "a@x.test"))
    }

    func testAvatarLookupsStopWhenTheSettingIsOff() async throws {
        let counter = Counter()
        let photos = AvatarPhotos(enabled: false, resolve: { _ in
            await counter.bump()
            return nil
        })
        photos.request("ana@example.test")
        await photos.waitUntilIdle()
        let noLookups = await counter.value
        XCTAssertEqual(noLookups, 0)
        photos.enabled = true
        photos.request("ana@example.test")
        await photos.waitUntilIdle()
        let oneLookup = await counter.value
        XCTAssertEqual(oneLookup, 1)
    }

    // MARK: - Streaming answers and drafts (requirement 4)

    func testAskStreamsThenTheAnswerReplacesIt() async throws {
        let core = FakeCore()
        await core.setAIDelay(.milliseconds(120))
        let store = AIAssistStore(toasts: ToastCenter())
        store.client = core

        let task = Task { await store.ask("Wann war der Termin?") }
        try? await Task.sleep(for: .milliseconds(30))
        let requestId = try? XCTUnwrap(store.askRequestId)
        let id = try XCTUnwrap(requestId)
        store.receive(AIStreamToken(kind: .ask, requestId: id, delta: "Am "))
        store.receive(AIStreamToken(kind: .ask, requestId: id, delta: "3. März"))
        XCTAssertEqual(store.askStatus, .streaming)
        // The second token waited for the next 33 ms window; the trailing flush
        // publishes it without another token.
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.askAnswer, "Am 3. März")
        await task.value
        // The final answer wins, whatever the stream had buffered.
        XCTAssertEqual(store.askStatus, .done)
        XCTAssertEqual(store.askAnswer, "Am 3. März.")
        XCTAssertEqual(store.askCitations.count, 1)
    }

    func testAskIgnoresTokensOfAnotherRequest() async {
        let core = FakeCore()
        await core.setAIDelay(.milliseconds(120))
        let store = AIAssistStore(toasts: ToastCenter())
        store.client = core
        let task = Task { await store.ask("Frage") }
        try? await Task.sleep(for: .milliseconds(10))
        store.receive(AIStreamToken(kind: .ask, requestId: "andere", delta: "FALSCH"))
        XCTAssertEqual(store.askAnswer, "")
        XCTAssertEqual(store.askStatus, .pending)
        await task.value
        XCTAssertEqual(store.askAnswer, "Am 3. März.")
    }

    func testAskResetDropsThePreamble() async throws {
        let store = AIAssistStore(toasts: ToastCenter())
        store.client = FakeCore()
        let task = Task { await store.ask("Frage") }
        try? await Task.sleep(for: .milliseconds(10))
        let id = try? XCTUnwrap(store.askRequestId)
        store.receive(AIStreamToken(kind: .ask, requestId: id, delta: "Ich schaue nach …"))
        store.receiveAskReset(requestId: try XCTUnwrap(id))
        XCTAssertEqual(store.askAnswer, "")
        XCTAssertEqual(store.askStatus, .pending)
        await task.value
    }

    func testSummaryShowsWhatStreamedIn() async throws {
        let core = FakeCore()
        await core.setAIDelay(.milliseconds(120))
        let store = AIAssistStore(toasts: ToastCenter())
        store.client = core

        let task = Task { await store.summarize(7) }
        try? await Task.sleep(for: .milliseconds(30))
        store.receive(AIStreamToken(kind: .summary, threadId: 7,
                                    delta: #"{"timeline":[{"actor":"Ana","event":"schickt die Rechnung"}],"keyPoints":["Rechnung offen"]"#))
        let state = store.summaryState(7)
        XCTAssertEqual(state?.pending, true)
        XCTAssertEqual(state?.partial?.timeline.count, 1)
        XCTAssertEqual(state?.partial?.keyPoints, ["Rechnung offen"])
        await task.value
        XCTAssertEqual(store.summaryState(7)?.summary?.keyPoints, ["Rechnung offen"])
        XCTAssertNil(store.summaryState(7)?.partial)
    }

    func testDraftStreamsIntoTheBodyAndReplacesIt() async throws {
        let core = FakeCore()
        await core.setAIDelay(.milliseconds(120))
        let draft = ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil,
                                 to: [Address(name: nil, email: "a@b.de")], cc: [], subject: "s", body: "",
                                 client: core, toasts: ToastCenter(), settings: SettingsStore())
        let task = Task { await draft.aiDraft(instruction: "Antworte freundlich") }
        try? await Task.sleep(for: .milliseconds(30))
        let id = try XCTUnwrap(draft.aiRequestId)
        draft.consumeDraftToken(AIStreamToken(kind: .draft, requestId: id, delta: "Guten Tag"))
        XCTAssertEqual(draft.body, "Guten Tag")
        XCTAssertTrue(draft.aiStreaming)
        await task.value
        XCTAssertEqual(draft.body, "Guten Tag, ich sage zu.")
        XCTAssertTrue(draft.canUndoAIChange, "die KI-Änderung muss zurücknehmbar bleiben")
        XCTAssertFalse(draft.aiStreaming)
        XCTAssertNil(draft.aiRequestId)
    }

    func testDraftTakesBackAPartialBodyOnFailure() async throws {
        let core = FakeCore()
        await core.setAIDelay(.milliseconds(100))
        await core.setAIError(.core(code: "network", message: "weg"))
        let draft = ComposeDraft(mode: .new, accountId: 1, inReplyTo: nil,
                                 to: [Address(name: nil, email: "a@b.de")], cc: [], subject: "s", body: "Mein Text",
                                 client: core, toasts: ToastCenter(), settings: SettingsStore())
        let task = Task { await draft.aiDraft(instruction: "Kürzer") }
        try? await Task.sleep(for: .milliseconds(30))
        let id = try XCTUnwrap(draft.aiRequestId)
        draft.consumeDraftToken(AIStreamToken(kind: .draft, requestId: id, delta: "Anfang"))
        XCTAssertEqual(draft.body, "Anfang")
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(draft.body, "Mein Text", "halb gestreamter Text ist nicht der Text des Nutzers")
        XCTAssertFalse(draft.canUndoAIChange)
    }

    // MARK: - Verification codes and unsubscribing (requirement 6)

    func testVerificationCodeIsCopied() async {
        let core = FakeCore()
        await core.setVerificationCode(VerificationCode(code: "123456", messageId: 4, threadId: 9,
                                                       sender: "login@example.test", subject: "Dein Code",
                                                       receivedAt: 1_700_000_000_000))
        let toasts = ToastCenter()
        let store = AuxActionsStore(toasts: toasts)
        store.client = core
        var copied: String?
        store.copyToClipboard = { copied = $0 }
        let ok = await store.copyVerificationCode()
        XCTAssertTrue(ok)
        XCTAssertEqual(copied, "123456")
        XCTAssertEqual(toasts.current?.text, "Code 123456 von login@example.test kopiert")
        let maxAge = await core.verificationCodeMaxAge
        XCTAssertEqual(maxAge, 30, "die Palette fragt die letzten 30 Minuten")
    }

    func testNoVerificationCodeIsSaidOutLoud() async {
        let core = FakeCore()
        let toasts = ToastCenter()
        let store = AuxActionsStore(toasts: toasts)
        store.client = core
        var copied: String?
        store.copyToClipboard = { copied = $0 }
        let ok = await store.copyVerificationCode()
        XCTAssertFalse(ok)
        XCTAssertNil(copied)
        XCTAssertEqual(toasts.current?.text, "Kein Bestätigungscode gefunden")
    }

    /// K3 aus dem Audit M2: `⌘U` meldet nicht mehr sofort ab, sondern fragt.
    func testUnsubscribeAsksBeforeItActs() async {
        let core = FakeCore()
        let toasts = ToastCenter()
        let store = AuxActionsStore(toasts: toasts)
        store.client = core
        await core.setUnsubscribe(messageId: 21, outcome: .oneClick)
        await store.unsubscribe(threadId: 7, sender: "news@example.test")
        XCTAssertEqual(toasts.current?.text, "Von news@example.test abmelden?")
        XCTAssertEqual(toasts.current?.actionTitle, "Abmelden")
        let before = await core.unsubscribeCalls
        XCTAssertTrue(before.isEmpty, "ohne Bestätigung geht nichts raus")
        XCTAssertTrue(toasts.runAction())
        try? await Task.sleep(for: .milliseconds(60))
        let after = await core.unsubscribeCalls
        XCTAssertEqual(after, [21])
        XCTAssertEqual(toasts.current?.text, "Abgemeldet")
    }

    func testUnsubscribeClaimsOnlyWhatHappened() async {
        let core = FakeCore()
        let toasts = ToastCenter()
        let store = AuxActionsStore(toasts: toasts)
        store.client = core
        await core.setUnsubscribe(messageId: 21, outcome: .oneClick)
        let outcome = await store.performUnsubscribe(messageId: 21)
        XCTAssertEqual(outcome, .oneClick)
        XCTAssertEqual(toasts.current?.text, "Abgemeldet")

        await core.setUnsubscribe(messageId: 21, outcome: .mailtoSent)
        _ = await store.performUnsubscribe(messageId: 21)
        XCTAssertEqual(toasts.current?.text, "Abmeldung per E-Mail angefragt")

        // A browser link is not an unsubscribe: it is offered, not claimed.
        await core.setUnsubscribe(messageId: 21, outcome: .needsBrowser(url: "https://example.test/u"))
        var opened: URL?
        store.openURL = { opened = $0 }
        _ = await store.performUnsubscribe(messageId: 21)
        XCTAssertEqual(toasts.current?.text, "Abmeldung im Browser bestätigen")
        toasts.runAction()
        XCTAssertEqual(opened?.absoluteString, "https://example.test/u")

        // K3: the URL comes from a foreign header — only web addresses open.
        await core.setUnsubscribe(messageId: 21, outcome: .needsBrowser(url: "file:///etc/passwd"))
        _ = await store.performUnsubscribe(messageId: 21)
        opened = nil
        toasts.runAction()
        XCTAssertNil(opened, "kein file:-Link an den Browser")
        let calls = await core.unsubscribeCalls
        XCTAssertEqual(calls, [21, 21, 21, 21])
    }

    func testThreadWithoutUnsubscribeSaysSo() async {
        let core = FakeCore()
        let toasts = ToastCenter()
        let store = AuxActionsStore(toasts: toasts)
        store.client = core
        await core.setUnsubscribe(messageId: nil)
        await store.unsubscribe(threadId: 7)
        XCTAssertNil(store.lastUnsubscribeOutcome)
        XCTAssertEqual(toasts.current?.text, "Diese Mail bietet keine Abmeldung")
        let calls = await core.unsubscribeCalls
        XCTAssertTrue(calls.isEmpty, "ohne Link darf nichts abgemeldet werden")
    }

    // MARK: - Event routing (requirement 4)

    func testEventRouterReadsTheStreamingEvents() throws {
        let token = try XCTUnwrap(EventRouter.parse(
            #"{"name":"ai:ask:token","payload":{"requestId":"abc","delta":"Hallo"}}"#))
        guard case .aiToken(let stream) = token else { return XCTFail("kein Token") }
        XCTAssertEqual(stream.kind, .ask)
        XCTAssertEqual(stream.requestId, "abc")
        XCTAssertEqual(stream.delta, "Hallo")

        let summary = try XCTUnwrap(EventRouter.parse(
            #"{"name":"ai:summary:token","payload":{"threadId":7,"delta":"{"}}"#))
        guard case .aiToken(let summaryToken) = summary else { return XCTFail("kein Token") }
        XCTAssertEqual(summaryToken.threadId, 7)

        let reset = try XCTUnwrap(EventRouter.parse(#"{"name":"ai:ask:reset","payload":{"requestId":"abc"}}"#))
        guard case .aiAskReset(let resetId) = reset else { return XCTFail("kein Reset") }
        XCTAssertEqual(resetId, "abc")

        // Reasoning tokens are not shown by the native app (no `other` noise).
        let reasoning = try XCTUnwrap(EventRouter.parse(
            #"{"name":"ai:ask:reasoning","payload":{"requestId":"abc","delta":"denke"}}"#))
        guard case .other(let name) = reasoning else { return XCTFail("kein other") }
        XCTAssertEqual(name, "ai:ask:reasoning")
    }

    func testEventRouterReadsACalendarReminder() throws {
        let json = #"{"name":"calendar:reminder","payload":{"event":{"id":3,"accountId":1,"messageId":null,"summary":"Standup","location":"Raum 2","organizer":null,"description":null,"attendees":[],"joinUrl":null,"rsvpStatus":null,"isLocal":false,"calendarId":null,"rrule":null,"startsAt":1763982000000,"endsAt":null,"allDay":false,"status":null,"method":null},"occurrenceStart":1763982000000}}"#
        let event = try XCTUnwrap(EventRouter.parse(json))
        guard case .calendarReminder(let reminder) = event else { return XCTFail("keine Erinnerung") }
        XCTAssertEqual(reminder.event.summary, "Standup")
        XCTAssertEqual(reminder.occurrenceStart, 1_763_982_000_000)
    }
}

private func testDataURL(_ bytes: [UInt8]) -> String {
    "data:image/png;base64," + Data(bytes).base64EncodedString()
}

/// A tiny counter for the resolver closures (`@Sendable`, so it lives in an
/// actor).
private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
