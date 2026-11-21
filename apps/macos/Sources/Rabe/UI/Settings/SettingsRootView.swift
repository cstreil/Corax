import AppKit
import RabeKit
import SwiftUI

extension Notification.Name {
    /// Selects a page in the settings window (already open or about to open).
    static let rabeSettingsPage = AppIdentity.notification("settings.page")
    /// Asks the main window to open ⌘, (it owns the `openSettings` action).
    static let rabeOpenSettings = AppIdentity.notification("settings.open")
}

/// Opens the settings window on one page. Used by the AI hints ("Einrichten …",
/// the KI menu) and by the M2.1 walkthrough.
@MainActor
enum SettingsNavigation {
    /// Read by `SettingsView` when the window appears.
    static var pendingPage: SettingsPage?

    static func request(_ page: SettingsPage) {
        pendingPage = page
        NotificationCenter.default.post(name: .rabeSettingsPage, object: page.rawValue)
        NotificationCenter.default.post(name: .rabeOpenSettings, object: nil)
    }
}

/// Settings window (⌘,): sidebar with the three groups of the Tauri panel and
/// one page per section. The search field filters the sections through the same
/// flat index (`SettingsPanel.tsx`'s `INDEX`).
struct SettingsView: View {
    private var model: AppModel { AppModel.shared }
    @State private var selection: SettingsPage? = .appearance
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            await model.loadSettingsEditors()
            if let page = SettingsNavigation.pendingPage {
                selection = page
                SettingsNavigation.pendingPage = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rabeSettingsPage)) { note in
            if let raw = note.object as? String, let page = SettingsPage(rawValue: raw) { selection = page }
        }
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Einstellungen durchsuchen …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Suche leeren")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .padding(8)

            List(selection: $selection) {
                if query.isEmpty {
                    ForEach(SettingsPage.Group.allCases) { group in
                        Section(group.title) {
                            ForEach(SettingsPage.pages(in: group)) { page in
                                Label(page.title, systemImage: page.icon)
                                    .tag(page)
                            }
                        }
                    }
                } else {
                    searchResults
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsIndex.results(for: query)
        if results.isEmpty {
            Text("Keine Einstellung passt zu „\(query)“.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            Section("Treffer") {
                ForEach(results) { entry in
                    Button {
                        selection = entry.page
                        query = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.label)
                            Text(entry.page.title)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .appearance {
        case .appearance, .notifications, .reading, .compose:
            GeneralSettingsView(page: selection ?? .appearance)
        case .signatures:
            SignaturesSettingsView()
        case .accounts:
            AccountsSettingsView()
        case .splits:
            SplitsSettingsView()
        case .snippets:
            SnippetsSettingsView()
        case .labels:
            LabelsSettingsView()
        case .calendar:
            CalendarSettingsView()
        case .intelligence:
            IntelligenceSettingsView()
        case .mcp:
            McpSettingsView()
        case .updates:
            UpdatesSettingsView()
        }
    }
}

/// Banner shown while the write switch is off (P2g), above the general pages.
struct WriteGateHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
            Text("Nur-Lesen-Modus: Postfach → Änderungen erlauben, um Einstellungen zu ändern.")
                .font(.system(size: 11))
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
    }
}
