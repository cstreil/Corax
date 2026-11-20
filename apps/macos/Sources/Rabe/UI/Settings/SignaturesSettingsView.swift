import RabeKit
import SwiftUI

/// Signatures live in the settings object (`signatureList`,
/// `signatureDefaults`) and are written through `SettingsStore`. The editor
/// keeps the HTML source so a rich signature created in the Tauri app survives
/// an edit here; the preview shows the plain text it renders to.
struct SignaturesSettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var s: SettingsStore { model.settings }

    @State private var accountID: Int64?
    @State private var editing: Signature?
    @State private var draftName = ""
    @State private var draftHTML = ""
    @State private var deleteTarget: Signature?
    /// `ai_signature` is running for the open editor.
    @State private var suggesting = false

    private var accounts: [Account] { model.mailbox.accounts }
    private var account: Account? {
        accounts.first { $0.id == accountID } ?? accounts.first
    }
    private var signatures: [Signature] {
        account.map { s.signatures(for: $0.id) } ?? []
    }

    var body: some View {
        Form {
            if accounts.isEmpty {
                Text("Keine Konten verbunden.").foregroundStyle(.secondary)
            } else {
                Section("Signaturen") {
                    SettingPickerRow(title: "Konto", selection: Binding(
                        get: { account?.id ?? 0 },
                        set: { accountID = $0 }
                    )) {
                        ForEach(accounts) { Text($0.label).tag($0.id) }
                    }
                    if signatures.isEmpty {
                        Text("Noch keine Signaturen.").foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    ForEach(signatures) { signature in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(signature.name)
                                Text(Self.plainText(signature.html))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Bearbeiten") { beginEdit(signature) }
                                .buttonStyle(.borderless)
                            Button("Löschen", role: .destructive) { deleteTarget = signature }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        beginNew()
                    } label: {
                        Label("Signatur hinzufügen", systemImage: "plus")
                    }
                    .disabled(account == nil)
                }

                if let account, !signatures.isEmpty {
                    Section("Standard für neue E-Mails") {
                        signaturePicker(accountId: account.id, isNew: true)
                    }
                    Section("Beim Antworten / Weiterleiten") {
                        signaturePicker(accountId: account.id, isNew: false)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!s.loaded)
        .onAppear { if accountID == nil { accountID = accounts.first?.id } }
        .sheet(item: $editing) { signature in
            signatureEditor(signature)
        }
        .alert("Signatur löschen?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Löschen", role: .destructive) {
                if let target = deleteTarget { s.removeSignature(id: target.id) }
                deleteTarget = nil
            }
            Button("Abbrechen", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("„\(deleteTarget?.name ?? "")“ wird aus allen Konten entfernt, die sie verwenden. Laufende Entwürfe bleiben unverändert.")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func signaturePicker(accountId: Int64, isNew: Bool) -> some View {
        let defaults = s.signatureDefaults(for: accountId)
        SettingPickerRow(title: isNew ? "Signatur" : "Signatur",
                         hint: "Wird an E-Mails angehängt, die du von \(account?.email ?? "") sendest.",
                         selection: Binding(
                            get: { (isNew ? defaults.newId : defaults.replyId) ?? "" },
                            set: { value in
                                let id = value.isEmpty ? nil : value
                                s.setSignatureDefaults(accountId: accountId,
                                                       newId: isNew ? id : defaults.newId,
                                                       replyId: isNew ? defaults.replyId : id)
                            }
                         )) {
            Text("Keine Signatur").tag("")
            ForEach(signatures) { Text($0.name).tag($0.id) }
        }
    }

    // MARK: Editor

    private func beginNew() {
        guard let account else { return }
        draftName = "Neue Signatur"
        draftHTML = "<p></p>"
        editing = Signature(id: UUID().uuidString, accountId: account.id, name: draftName, html: draftHTML)
    }

    private func beginEdit(_ signature: Signature) {
        draftName = signature.name
        draftHTML = signature.html
        editing = signature
    }

    @ViewBuilder
    private func signatureEditor(_ signature: Signature) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signatur bearbeiten").font(.headline)
            TextField("Name der Signatur", text: $draftName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Text("Inhalt (HTML)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(suggesting ? "Schlage vor …" : "Per KI vorschlagen") {
                    guard let account else { return }
                    suggesting = true
                    Task {
                        let name = account.displayName ?? account.email
                        if let text = await model.assistant.signature(name: name, email: account.email),
                           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            draftHTML = Self.html(fromPlain: text)
                        }
                        suggesting = false
                    }
                }
                .controlSize(.small)
                .disabled(suggesting)
                .help("Erzeugt eine schlichte Signatur aus Name und Adresse (ein Modellaufruf)")
            }
            TextEditor(text: $draftHTML)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Vorschau").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(Self.plainText(draftHTML))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }

            HStack {
                Spacer()
                Button("Abbrechen") { editing = nil }
                Button("Speichern") {
                    var updated = signature
                    updated.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.html = draftHTML
                    s.upsertSignature(updated)
                    editing = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    // MARK: Text

    /// Plain text from `ai_signature` as simple HTML paragraphs.
    static func html(fromPlain text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let lines = escaped.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { "<p>\($0)</p>" }.joined()
    }

    /// Crude HTML → text for the preview and the list row (no rich text editor
    /// in the native composer yet).
    static func plainText(_ html: String) -> String {
        var text = html
        for (needle, replacement) in [("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"),
                                      ("</p>", "\n"), ("</div>", "\n"), ("&nbsp;", " "),
                                      ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">")] {
            text = text.replacingOccurrences(of: needle, with: replacement, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
