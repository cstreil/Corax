import RabeKit
import SwiftUI

/// Organisation group → Labels: user labels (create, rename, recolor, delete)
/// and the auto categories (rename, model guidance, add, remove, restore).
/// Everything goes through `save_label`/`delete_label`/`create_category`/
/// `restore_auto_labels`; the guidance strings are part of the settings object.
struct LabelsSettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var store: LabelsStore { model.labels }
    private var settings: SettingsStore { model.settings }

    /// Tauri's one label palette (`src/lib/labelColors.ts`).
    private let palette = ["#2563eb", "#16a34a", "#d97706", "#dc2626", "#7c3aed", "#0891b2", "#db2777", "#6b7280"]
    private let builtinKeywords: Set<String> = ["ComailAutoMarketing", "ComailAutoNews",
                                                "ComailAutoSocial", "ComailAutoPitch"]

    @State private var editorOpen = false
    @State private var editingID: Int64?
    @State private var name = ""
    @State private var color = "#2563eb"
    @State private var deleteTarget: MailLabel?

    @State private var categorySheet = false
    @State private var categoryName = ""
    @State private var categoryDescription = ""
    @State private var categoryDelete: MailLabel?
    @State private var descriptions: [Int64: String] = [:]

    private var userLabels: [MailLabel] { store.sorted.filter { $0.isAuto != true } }
    private var autoLabels: [MailLabel] { store.sorted.filter { $0.isAuto == true } }

    var body: some View {
        Form {
            Section("Deine Labels") {
                if userLabels.isEmpty {
                    Text(store.loaded ? "Noch keine Labels. Lege eins an, um deine E-Mails zu kennzeichnen und zu filtern."
                                      : "Wird geladen …")
                        .foregroundStyle(.secondary).font(.system(size: 12))
                }
                ForEach(userLabels) { label in
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: label.color) ?? .gray).frame(width: 10, height: 10)
                        Text(label.name)
                        Spacer()
                        Button("Bearbeiten") { beginEdit(label) }.buttonStyle(.borderless)
                        Button("Löschen", role: .destructive) { deleteTarget = label }.buttonStyle(.borderless)
                    }
                }
                Button { beginNew() } label: { Label("Neues Label", systemImage: "plus") }
            }

            Section("Kategorien") {
                Text("Kategorien sind Auto-Labels. Die Beschreibung sagt dem Modell, was in die Kategorie gehört.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(autoLabels) { label in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: label.color) ?? .gray).frame(width: 10, height: 10)
                            Text(label.name)
                            if !builtinKeywords.contains(label.keyword) {
                                Text("Eigene")
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            Spacer()
                            Button("Umbenennen") { beginEdit(label) }.buttonStyle(.borderless)
                            if !builtinKeywords.contains(label.keyword) {
                                Button("Löschen", role: .destructive) { categoryDelete = label }
                                    .buttonStyle(.borderless)
                            }
                        }
                        TextField("Beschreibung fürs Modell",
                                  text: Binding(get: { descriptions[label.id] ?? settings.categoryDescription(for: label.keyword) },
                                                set: { descriptions[label.id] = $0 }),
                                  prompt: Text(builtinPrompt(label.keyword)))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .onSubmit { saveDescription(label) }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Button { categoryName = ""; categoryDescription = ""; categorySheet = true } label: {
                        Label("Neue Kategorie", systemImage: "plus")
                    }
                    Spacer()
                    Button("Standard-Kategorien wiederherstellen") {
                        Task {
                            if let count = await store.restoreAutoLabels() {
                                model.toasts.show("\(count) Kategorien wiederhergestellt")
                            }
                        }
                    }
                    .disabled(store.busy)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            // Committed descriptions are written on submit/blur only; flush the
            // ones the user typed and left with Tab/click.
            for label in autoLabels { saveDescription(label) }
        }
        .sheet(isPresented: $editorOpen) { labelEditor }
        .sheet(isPresented: $categorySheet) { categoryEditor }
        .alert("Label löschen?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Löschen", role: .destructive) {
                if let target = deleteTarget {
                    Task {
                        if await store.delete(target.id) { await model.reloadOrganisation() }
                    }
                }
                deleteTarget = nil
            }
            Button("Abbrechen", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget.map { "„\($0.name)“ wird auch von allen E-Mails entfernt, die es tragen." } ?? "")
        }
        .alert("Kategorie löschen?", isPresented: Binding(
            get: { categoryDelete != nil },
            set: { if !$0 { categoryDelete = nil } }
        )) {
            Button("Löschen", role: .destructive) {
                if let target = categoryDelete {
                    Task {
                        if await store.delete(target.id) { await model.reloadOrganisation() }
                    }
                }
                categoryDelete = nil
            }
            Button("Abbrechen", role: .cancel) { categoryDelete = nil }
        } message: {
            Text(categoryDelete.map { "„\($0.name)“ wird entfernt. E-Mails, die sie tragen, verlieren das Label." } ?? "")
        }
    }

    private func builtinPrompt(_ keyword: String) -> String {
        switch keyword {
        case "ComailAutoMarketing": "Werbung, Newsletter-Angebote, Aktionen"
        case "ComailAutoNews": "Nachrichten, Digest, Pressemeldungen"
        case "ComailAutoSocial": "Benachrichtigungen von sozialen Netzwerken"
        case "ComailAutoPitch": "Kaltakquise, Vertriebs-Anfragen"
        default: "Beschreibung fürs Modell"
        }
    }

    // MARK: Label editor

    private var labelEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editingID == nil ? "Neues Label" : "Label bearbeiten").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("z. B. Arbeit"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Farbe").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(palette, id: \.self) { hex in
                            Button { color = hex } label: {
                                Circle().fill(Color(hex: hex) ?? .gray)
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(Color.primary.opacity(color == hex ? 0.7 : 0),
                                                             lineWidth: color == hex ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Abbrechen") { editorOpen = false }
                Button(editingID == nil ? "Label anlegen" : "Änderungen speichern") { Task { await saveLabel() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private var categoryEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Neue Kategorie").font(.headline)
            TextField("Name", text: $categoryName, prompt: Text("z. B. Rechnungen"))
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 3) {
                Text("Beschreibung fürs Modell").font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $categoryDescription)
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            Text("Kategorien werden beim Abruf vom Modell zugeordnet; ohne eingerichtetes Modell bleiben sie leer.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") { categorySheet = false }
                Button("Kategorie anlegen") {
                    Task {
                        let color = palette[(autoLabels.count + 4) % palette.count]
                        if let created = await store.createCategory(
                            name: categoryName.trimmingCharacters(in: .whitespacesAndNewlines),
                            color: color,
                            description: categoryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        ) {
                            settings.setCategoryDescription(created.keyword, categoryDescription)
                            categorySheet = false
                            await model.reloadOrganisation()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: Actions

    private func beginNew() {
        editingID = nil
        name = ""
        color = palette[userLabels.count % palette.count]
        editorOpen = true
    }

    private func beginEdit(_ label: MailLabel) {
        editingID = label.id
        name = label.name
        color = label.color
        editorOpen = true
    }

    private func saveLabel() async {
        guard let existing = store.items.first(where: { $0.id == editingID }) else {
            let input = LabelInput(id: nil, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                   color: color, position: store.nextPosition)
            if await store.save(input) { editorOpen = false; await model.reloadOrganisation() }
            return
        }
        let input = LabelInput(id: existing.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                               color: color, position: existing.position)
        if await store.save(input) { editorOpen = false; await model.reloadOrganisation() }
    }

    private func saveDescription(_ label: MailLabel) {
        guard let text = descriptions.removeValue(forKey: label.id) else { return }
        settings.setCategoryDescription(label.keyword, text)
    }
}

// MARK: - Hex colours

extension Color {
    /// `#rrggbb` from the label palette.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((number >> 16) & 0xff) / 255,
                  green: Double((number >> 8) & 0xff) / 255,
                  blue: Double(number & 0xff) / 255,
                  opacity: 1)
    }
}
