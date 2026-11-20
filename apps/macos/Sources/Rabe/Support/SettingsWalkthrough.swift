import AppKit
import Foundation
import RabeKit

#if DEBUG || RABE_TEST_HOOKS

/// M2.1 walkthrough helpers. Hook builds only (`RABE_TEST_HOOKS=1`), and only
/// against the sandbox: the real instance refuses every step, so a hook build
/// started by mistake cannot touch a real mailbox.
@MainActor
enum SettingsWalkthrough {
    /// Opens ⌘, on one page (the window shows it on appear or via the
    /// notification when it is already open).
    static func open(_ page: SettingsPage) {
        guard Instance.isSandbox else { log("page refused=not_sandbox"); return }
        SettingsNavigation.request(page)
        log("page \(page.rawValue)")
    }

    /// Creates, changes and deletes one row per editor through the stores —
    /// the same path the buttons use (policy → host → core → reload).
    static func run() async {
        guard Instance.isSandbox else { log("scenario refused=not_sandbox"); return }
        let model = AppModel.shared
        await model.settings.load()
        await model.labels.load()
        await model.splits.load()
        await model.snippets.load()
        await model.mcp.load()
        log("scenario accounts=\(model.mailbox.accounts.count)")

        // Textbausteine
        let snippetOK = await model.snippets.save(
            SnippetInput(id: nil, name: "M2.1 Testbaustein", shortcut: "m21", subject: nil, bodyText: "Erster Text"))
        log("snippet create ok=\(snippetOK)")
        if let created = model.snippets.items.first(where: { $0.name == "M2.1 Testbaustein" }) {
            let changed = await model.snippets.save(
                SnippetInput(id: created.id, name: "M2.1 Testbaustein geändert", shortcut: "m21",
                             subject: "Betreff", bodyText: "Zweiter Text"))
            log("snippet update ok=\(changed) id=\(created.id)")
            let deleted = await model.snippets.delete(created.id)
            log("snippet delete ok=\(deleted) left=\(model.snippets.items.count)")
        } else {
            log("snippet missing_after_create")
        }

        // Labels
        let labelOK = await model.labels.save(
            LabelInput(id: nil, name: "M2.1 Testlabel", color: "#2563eb", position: model.labels.nextPosition))
        log("label create ok=\(labelOK)")
        if let created = model.labels.items.first(where: { $0.name == "M2.1 Testlabel" }) {
            let changed = await model.labels.save(
                LabelInput(id: created.id, name: "M2.1 Testlabel geändert", color: "#16a34a",
                           position: created.position))
            log("label update ok=\(changed) id=\(created.id)")
            let deleted = await model.labels.delete(created.id)
            log("label delete ok=\(deleted) left=\(model.labels.items.count)")
        } else {
            log("label missing_after_create")
        }

        // Kategorie (Auto-Label)
        if let category = await model.labels.createCategory(
            name: "M2.1 Kategorie", color: "#dc2626", description: "Testbeschreibung fürs Modell") {
            log("category create ok=1 keyword=\(category.keyword)")
            model.settings.setCategoryDescription(category.keyword, "Geänderte Beschreibung")
            await model.settings.waitForPendingWrites()
            log("category describe ok=1 text=\(model.settings.categoryDescription(for: category.keyword))")
            let deleted = await model.labels.delete(category.id)
            log("category delete ok=\(deleted)")
        } else {
            log("category create ok=0")
        }

        // Splits und Regeln
        let splitOK = await model.splits.save(
            SplitInput(id: nil, name: "M2.1 Testregel", position: model.splits.nextPosition,
                       condition: .sender(.contains, "@sandbox.invalid"), target: nil, countAll: true))
        log("split create ok=\(splitOK != nil) count=\(model.splits.splits.count) tabs=\(model.splits.tabs.count)")
        if let created = model.splits.splits.first(where: { $0.name == "M2.1 Testregel" }) {
            let changed = await model.splits.save(
                SplitInput(id: created.id, name: "M2.1 Testregel geändert", position: created.position,
                           condition: .subject(.contains, "Test"), target: "other", countAll: false))
            log("split update ok=\(changed != nil) target=\(changed?.target ?? "-")")
            if let preview = await model.splits.preview(.sender(.contains, "@sandbox.invalid")) {
                log("split preview total=\(preview.total) scanned=\(preview.scanned)")
            } else {
                log("split preview ok=0")
            }
            let moved = await model.splits.move(from: 0, to: max(0, model.splits.tabs.count - 1))
            log("split move ok=\(moved) tabs=\(model.splits.tabs.map(\.name).joined(separator: ","))")
            let deleted = await model.splits.delete(created.id)
            log("split delete ok=\(deleted) left=\(model.splits.splits.count)")
        } else {
            log("split missing_after_create")
        }
        log("relabel count=\(await model.splits.relabelAutoLabels() ?? -1)")

        // Signaturen
        if let account = model.mailbox.accounts.first {
            let signature = Signature(id: "walkthrough-\(UUID().uuidString)", accountId: account.id,
                                      name: "M2.1 Signatur", html: "<p>Viele Grüße</p>")
            model.settings.upsertSignature(signature)
            await model.settings.waitForPendingWrites()
            log("signature create ok=1 account=\(account.id) count=\(model.settings.signatures(for: account.id).count)")
            var edited = signature
            edited.name = "M2.1 Signatur geändert"
            edited.html = "<p>Viele Grüße, geändert</p>"
            model.settings.upsertSignature(edited)
            model.settings.setSignatureDefaults(accountId: account.id, newId: edited.id, replyId: nil)
            await model.settings.waitForPendingWrites()
            log("signature update ok=1 default=\(model.settings.signatureDefaults(for: account.id).newId ?? "-")")
            model.settings.removeSignature(id: edited.id)
            await model.settings.waitForPendingWrites()
            log("signature delete ok=1 left=\(model.settings.signatures(for: account.id).count)")
        } else {
            log("signature no_account")
        }

        // MCP (Status und Snippet; das Token wird nicht geloggt)
        if let status = model.mcp.status {
            log("mcp status running=\(status.running) port=\(status.port) clients=\(status.clientCount)")
        } else {
            log("mcp status missing")
        }
        log("mcp clients=\(model.mcp.clients.count) activity=\(model.mcp.activity.count)")

        log("scenario done")
    }

    /// Signs the first sandbox account out (removes it) — the destructive step
    /// at the end of the walkthrough; the folder is restored from the backup.
    static func signOutFirstAccount() async {
        guard Instance.isSandbox else { log("signout refused=not_sandbox"); return }
        let model = AppModel.shared
        await model.mailbox.refreshAccounts()
        guard let account = model.mailbox.accounts.first else { log("signout no_account"); return }
        log("signout start id=\(account.id) email=\(account.email) accounts=\(model.mailbox.accounts.count)")
        let ok = await model.mailbox.removeAccount(account.id)
        log("signout done ok=\(ok) remaining=\(model.mailbox.accounts.count)")
    }

    /// `settings:language:system|de` — the picker's own path for "Sprache"
    /// (M2.8b): pick "System" on a German Mac and the core must receive "de",
    /// not "system" (which would leave the model without a language).
    static func setLanguage(_ choice: String) async {
        guard Instance.isSandbox else { log("language refused=not_sandbox"); return }
        let store = AppModel.shared.settings
        await store.load()
        store.preferredLanguages = { ["de-DE", "en-US"] }
        let before = store.language
        store.setLanguage(choice)
        await store.waitForPendingWrites()
        log("language choice=\(choice) stored=\(store.language) before=\(before) "
            + "picker=\(store.languageChoice) resolved=\(AILanguage.stored(choice, preferred: ["de-DE"]))")
    }

    private static func log(_ text: String) {
        PerfLog.shared.write("walkthrough \(text)")
    }
}

#endif
