import AppKit
import Foundation
import RabeIntents
import RabeKit

/// M3.3: die Brücke von den Intents in die laufende App.
///
/// Die Intents leben in `RabeIntents` und kennen nur das Protokoll; die App
/// reicht hier ihre Sitzung (`AppModel`) hinein. Alles, was das Modell
/// braucht, wird über `MainActor.run` geholt, damit die Intents selbst nicht
/// an den Main Actor gebunden sind.
struct AppIntentHost: IntentHost {
    func waitUntilReady(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await MainActor.run(body: { AppModel.shared.coreReady }) { return true }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return await MainActor.run { AppModel.shared.coreReady }
    }

    private func currentClient() async -> RabeClient? {
        await MainActor.run { AppModel.shared.client }
    }

    func latestVerificationCode(maxAgeMinutes: Int) async throws -> VerificationCode? {
        guard let client = await currentClient() else { throw IntentFailure.notReady }
        return try await client.latestVerificationCode(maxAgeMinutes: maxAgeMinutes)
    }

    func copyToClipboard(_ text: String) async {
        await MainActor.run {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }

    func unreadInboxCount() async throws -> Int {
        guard let client = await currentClient() else { throw IntentFailure.notReady }
        return Int(try await client.unreadCounts().inbox)
    }

    func unreadInboxThreads(limit: Int) async throws -> [ThreadSummary] {
        guard let client = await currentClient() else { throw IntentFailure.notReady }
        // Der Posteingang ohne Split — so lädt `MailboxStore.load`, solange in
        // der App kein Split gewählt ist (`splitId: currentSplitId`, dort nil).
        let page = try await client.listThreads(view: .inbox, splitId: nil, accountId: nil,
                                                labelId: nil, folderId: nil, cursor: nil,
                                                limit: max(limit * 3, 12))
        return page.threads.filter(\.isUnread)
    }

    func ask(_ question: String) async throws -> String {
        guard let client = await currentClient() else { throw IntentFailure.notReady }
        let status: AIStatus
        do {
            status = try await client.aiStatus()
        } catch {
            throw IntentFailure.aiUnavailable
        }
        guard status.configured || status.appleIntelligence == "available" else {
            throw IntentFailure.aiNotConfigured
        }
        do {
            let result = try await client.aiAsk(question: question,
                                               requestId: UUID().uuidString,
                                               accountId: nil)
            return result.answer
        } catch {
            throw IntentFailure.aiUnavailable
        }
    }

    @MainActor func compose(to: String?, subject: String?, body: String?) {
        AppModel.shared.composeNew(to: Self.addresses(to),
                                  subject: subject ?? "",
                                  body: body ?? "")
    }

    @MainActor func search(_ query: String) {
        let mailbox = AppModel.shared.mailbox
        mailbox.searchText = query
        mailbox.runSearch()
        mailbox.focusList()
    }

    /// „a@b.de, Max Muster <max@b.de>" → Adressen; ein `Name <…>`-Paar wird
    /// aufgeteilt, alles andere gilt als reine Adresse.
    static func addresses(_ text: String?) -> [Address] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: ",").compactMap { part -> Address? in
            let raw = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if let open = raw.firstIndex(of: "<"), let close = raw.lastIndex(of: ">"), open < close {
                let name = raw[raw.startIndex..<open].trimmingCharacters(in: .whitespaces)
                let email = raw[raw.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                guard !email.isEmpty else { return nil }
                return Address(name: name.isEmpty ? nil : name, email: email)
            }
            return Address(name: nil, email: raw)
        }
    }
}
