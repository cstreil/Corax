import CoraxKit
import SwiftUI

/// Organisation group → Textbausteine: create, edit, delete (`list_snippets`,
/// `save_snippet`, `delete_snippet`). The `;shortcut` expansion itself lives in
/// the composer, not here.
struct SnippetsSettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var store: SnippetsStore { model.snippets }

    @State private var editorOpen = false
    @State private var editingID: Int64?
    @State private var name = ""
    @State private var shortcut = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var deleteTarget: Snippet?

    var body: some View {
        Form {
            Section {
                if store.items.isEmpty {
                    Text(store.loaded ? "Noch keine Textbausteine. Lege einen an, um schneller zu antworten."
                                      : "Wird geladen …")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                ForEach(store.items) { snippet in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(snippet.name).fontWeight(.medium)
                                if let shortcut = snippet.shortcut, !shortcut.isEmpty {
                                    Text(";\(shortcut)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                                }
                            }
                            Text(snippet.bodyText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if snippet.usageCount > 0 {
                                Text("\(snippet.usageCount)× verwendet")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Bearbeiten") { beginEdit(snippet) }.buttonStyle(.borderless)
                        Button("Löschen", role: .destructive) { deleteTarget = snippet }.buttonStyle(.borderless)
                    }
                }
                Button { beginNew() } label: { Label("Neuer Textbaustein", systemImage: "plus") }
            } footer: {
                Text("Tippe beim Verfassen ;kürzel, um einen Textbaustein einzufügen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editorOpen) { editor }
        .alert("Textbaustein löschen?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Löschen", role: .destructive) {
                if let target = deleteTarget {
                    Task { _ = await store.delete(target.id) }
                }
                deleteTarget = nil
            }
            Button("Abbrechen", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget.map { SettingsConfirm.deleteRow($0.name, what: "Textbaustein") } ?? "")
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editingID == nil ? "Neuer Textbaustein" : "Textbaustein bearbeiten").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("z. B. Terminabsprache"))
                TextField("Kürzel", text: $shortcut, prompt: Text("termin"))
                TextField("Betreff (optional)", text: $subject, prompt: Text("Füllt den Betreff, wenn er leer ist"))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Text").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $bodyText)
                        .font(.system(size: 12))
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }
            }
            .formStyle(.grouped)
            .frame(height: 340)

            HStack {
                Spacer()
                Button("Abbrechen") { editorOpen = false }
                Button(editingID == nil ? "Textbaustein anlegen" : "Änderungen speichern") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func beginNew() {
        editingID = nil
        name = ""; shortcut = ""; subject = ""; bodyText = ""
        editorOpen = true
    }

    private func beginEdit(_ snippet: Snippet) {
        editingID = snippet.id
        name = snippet.name
        shortcut = snippet.shortcut ?? ""
        subject = snippet.subject ?? ""
        bodyText = snippet.bodyText
        editorOpen = true
    }

    private func save() async {
        let input = SnippetInput(
            id: editingID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            shortcut: emptyToNil(shortcut),
            subject: emptyToNil(subject),
            bodyText: bodyText
        )
        if await store.save(input) { editorOpen = false }
    }

    private func emptyToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
