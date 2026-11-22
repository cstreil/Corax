import CoraxKit
import SwiftUI

/// `CoraxKit.Label` (a mail label) and SwiftUI's `Label` view share a name.
/// The settings views mean the mail label whenever they say `MailLabel`.
typealias MailLabel = CoraxKit.Label

/// The pages of the settings window, grouped like the Tauri panel plus the
/// M2.3 "Intelligenz" group (status, keys, model, usage, index, decisions).
enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance, notifications, reading, compose, signatures
    case splits, snippets, labels, calendar
    case accounts, mcp, updates
    case intelligence

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case general, organization, system, intelligence
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "Allgemein"
            case .organization: "Organisation"
            case .system: "System"
            case .intelligence: "Intelligenz"
            }
        }
    }

    var group: Group {
        switch self {
        case .appearance, .notifications, .reading, .compose, .signatures: .general
        case .splits, .snippets, .labels, .calendar: .organization
        case .accounts, .mcp, .updates: .system
        case .intelligence: .intelligence
        }
    }

    var title: String {
        switch self {
        case .appearance: "Darstellung"
        case .notifications: "Mitteilungen"
        case .reading: "Lesen"
        case .compose: "Verfassen"
        case .signatures: "Signaturen"
        case .splits: "Geteilte Inbox"
        case .snippets: "Textbausteine"
        case .labels: "Labels"
        case .calendar: "Kalender"
        case .accounts: "Konten"
        case .mcp: "KI-Clients (MCP)"
        case .updates: "Updates"
        case .intelligence: "Intelligenz"
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintbrush"
        case .notifications: "bell"
        case .reading: "envelope.open"
        case .compose: "square.and.pencil"
        case .signatures: "signature"
        case .splits: "rectangle.split.3x1"
        case .snippets: "text.badge.plus"
        case .labels: "tag"
        case .calendar: "calendar"
        case .accounts: "person.2"
        case .mcp: "app.connected.to.app.below.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .intelligence: "sparkles"
        }
    }

    /// Pages of one group, in sidebar order.
    static func pages(in group: Group) -> [SettingsPage] { allCases.filter { $0.group == group } }
}

/// One searchable setting: `SettingsPanel.tsx`'s flat `INDEX`, covering the
/// pages of this package.
struct SettingsIndexEntry: Identifiable {
    let page: SettingsPage
    let label: String
    let keywords: String

    var id: String { "\(page.rawValue)#\(label)" }

    func score(_ query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let haystack = (label + " " + keywords).lowercased()
        guard let range = haystack.range(of: q) else { return nil }
        // A hit in the label ranks above one in the keywords.
        let inLabel = label.lowercased().contains(q)
        let atStart = haystack.distance(from: haystack.startIndex, to: range.lowerBound) == 0
        return (inLabel ? 100 : 40) + (atStart ? 10 : 0) - haystack.distance(from: haystack.startIndex, to: range.lowerBound) / 8
    }
}

enum SettingsIndex {
    static let all: [SettingsIndexEntry] = [
        // Allgemein
        .init(page: .appearance, label: "Design", keywords: "theme dark light hell dunkel graphit papier carbon farbe appearance"),
        .init(page: .appearance, label: "Akzentfarbe", keywords: "accent color colour highlight brand tint akzent"),
        .init(page: .appearance, label: "Sprache", keywords: "language locale translation deutsch german"),
        .init(page: .appearance, label: "Inbox-Ansicht", keywords: "inbox ui layout avatar classic liste rows look design"),
        .init(page: .appearance, label: "Fotos und Logos von Absendern zeigen", keywords: "sender photos avatars gravatar bimi logos absender fotos"),
        .init(page: .appearance, label: "Nach Datum gruppieren", keywords: "group date today yesterday timeline headers sections datum"),
        .init(page: .notifications, label: "Desktop-Benachrichtigungen", keywords: "notify alerts desktop benachrichtigungen mitteilungen"),
        .init(page: .notifications, label: "Ton", keywords: "sound chime audio new mail ton"),
        .init(page: .notifications, label: "Bestätigungscodes kopieren", keywords: "verification code otp 2fa copy clipboard bestätigungscode"),
        .init(page: .notifications, label: "Dock-Badge", keywords: "dock badge unread count icon red important"),
        .init(page: .reading, label: "Nach Auswahl weiter", keywords: "select advance next selection auswahl"),
        .init(page: .reading, label: "Externe Bilder laden", keywords: "images privacy tracking pixels remote bilder"),
        .init(page: .reading, label: "Automatisch weiter", keywords: "auto advance next thread cursor weiter"),
        .init(page: .compose, label: "Zeitfenster für „Senden rückgängig“", keywords: "undo send delay cancel rückgängig sekunden"),
        .init(page: .compose, label: "Kontakte aus allen Konten vorschlagen", keywords: "contacts autocomplete suggestions recipients account kontakte"),
        .init(page: .signatures, label: "Signaturen", keywords: "signature sign-off footer signatur"),
        // Organisation
        .init(page: .splits, label: "Auto-Labels", keywords: "auto labels categorize kategorien"),
        .init(page: .splits, label: "Geteilte Inbox", keywords: "split inbox tabs rules important other sender subject regeln"),
        .init(page: .splits, label: "Regeln", keywords: "rules condition filter sort actions regel bedingung"),
        .init(page: .snippets, label: "Textbausteine", keywords: "snippets templates canned responses shortcuts bausteine"),
        .init(page: .labels, label: "Labels", keywords: "labels tags colors folders label"),
        .init(page: .labels, label: "Kategorien", keywords: "categories auto labels marketing news social pitch kategorien"),
        .init(page: .calendar, label: "Kalender", keywords: "calendar termine events wochenbeginn week start erinnerung reminder standard default farbe color sync synchronisieren"),
        // System
        .init(page: .accounts, label: "Konten", keywords: "accounts add remove gmail microsoft imap oauth color name konten konto abmelden"),
        .init(page: .mcp, label: "KI-Clients (MCP)", keywords: "mcp model context protocol claude code desktop chatgpt cursor vscode copilot agent schnittstelle"),
        .init(page: .updates, label: "Updates", keywords: "update sparkle appcast version build aktualisieren automatisch neu installieren upgrade"),
        // Intelligenz
        .init(page: .intelligence, label: "KI-Status", keywords: "ai status konfiguriert configured key schlüssel api openrouter apple intelligence modelle"),
        .init(page: .intelligence, label: "API-Schlüssel", keywords: "api key token schlüssel openrouter openai commandcode securefield schlüsselbund"),
        .init(page: .intelligence, label: "Modell und Anbieter", keywords: "model provider anbieter base url endpunkt openrouter commandcode apple eigenes"),
        .init(page: .intelligence, label: "Schnellantworten", keywords: "quick replies antwortvorschläge schnellantworten"),
        .init(page: .intelligence, label: "Schreibstil", keywords: "voice style stimme schreibstil profil lernen drafting"),
        .init(page: .intelligence, label: "Nutzung", keywords: "usage tokens kosten statistik verbrauch nutzung"),
        .init(page: .intelligence, label: "Semantischer Index", keywords: "embedding semantic index reindex vektoren suche fragen"),
        .init(page: .intelligence, label: "Entscheidungen", keywords: "decision provider entscheidungen jev categories regeln splits test"),
    ]

    static func results(for query: String) -> [SettingsIndexEntry] {
        all.compactMap { entry in entry.score(query).map { (entry, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

// MARK: - Small row building blocks

/// Title plus an explanatory hint, without a control.
struct SettingHintRow: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// A switch with a hint underneath.
struct SettingToggleRow: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

/// A picker with a hint underneath.
struct SettingPickerRow<Value: Hashable, Content: View>: View {
    let title: String
    var hint: String?
    @Binding var selection: Value
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker(title, selection: $selection) { content() }
                .pickerStyle(.menu)
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Placement of a control next to a title inside a `Form`.
struct SettingRow<Trailing: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

/// Confirmation text shared by the delete buttons of the list editors.
enum SettingsConfirm {
    static func deleteRow(_ item: String, what: String) -> String {
        "\(what) „\(item)“ wirklich löschen? Das lässt sich nicht rückgängig machen."
    }
}
