import CoraxKit
import SwiftUI

/// Teil B: Ampel und Bedienelemente in **einer** Zeile — die echte Werkzeugleiste
/// in der Titelleiste statt des früheren 52-pt-Bands über dem Inhalt.
///
/// M2.15 hatte `NSToolbar` wieder entfernt, weil das `NSToolbarView` über einem
/// eigenen Band jeden Klick schluckte. Mit Items der Werkzeugleiste tritt das
/// nicht auf: der Treffer landet auf dem Hosting-View des Items (im Sandbox-Lauf
/// `ToolbarItemHostingView`, nicht mehr `NSToolbarView`).
@MainActor
enum WindowToolbar {
    /// Platz, den die Ampelknöpfe links und das Suchfeld rechts belegen. Beides
    /// malt AppKit beziehungsweise SwiftUI, nicht diese Ansicht; für die
    /// Breitenentscheidungen (Tabs, Ansichtswahl) wird es abgezogen.
    ///
    /// Die Werkzeugleiste liegt in der Titelleiste über dem **ganzen** Fenster —
    /// die Seitenleiste beginnt erst darunter und zieht nichts ab (im
    /// Sandbox-Lauf nachgemessen: bei 1240 pt Fenster blieben zwischen Titelmenü
    /// und Aktionsgruppe rund 415 pt frei, mit und ohne Seitenleiste gleich).
    /// Gemessen: Ampelzone bis 103 pt, Suchfeld 186–210 pt.
    static let trafficLightZone: CGFloat = 103
    static let searchSlot: CGFloat = 200

    /// Breite, die den Items tatsächlich bleibt.
    static func rowWidth(windowWidth: CGFloat) -> CGFloat {
        max(0, windowWidth - trafficLightZone - searchSlot)
    }

    /// Darunter passen die Tabs nicht mehr und bleiben nur im Titelmenü
    /// (M2.17). Nachgemessen: bei 837 pt Fenster (≈535 pt Zeile) blieben 146 pt
    /// zwischen Titelmenü und Aktionsgruppe, ein Tab-Streifen braucht rund 190 pt.
    static let tabsMinRowWidth: CGFloat = 600

    static func showsTabs(inRowWidth width: CGFloat) -> Bool {
        width >= tabsMinRowWidth
    }

    /// Kalender: darunter weicht die Ansichtswahl einem Popup (M2.17).
    static let modePickerMinRowWidth: CGFloat = 700

    static func showsModePicker(inRowWidth width: CGFloat) -> Bool {
        width >= modePickerMinRowWidth
    }
}

/// Die Leiste des Hauptfensters; je Modus andere Items (B3).
struct MainToolbar: ToolbarContent {
    private var model: AppModel { AppModel.shared }

    var body: some ToolbarContent {
        if model.calendarOpen {
            CalendarToolbar()
        } else {
            MailToolbar()
        }
    }
}

// MARK: - Mail

struct MailToolbar: ToolbarContent {
    private var model: AppModel { AppModel.shared }

    /// M2.18c: der Schalter steht in beiden Zuständen in der Leiste; der
    /// Hilfetext sagt, was der Klick tut.
    private var sidebarToggle: some View {
        Button {
            model.sidebar.toggle()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .help(model.sidebar.isVisible ? "Seitenleiste ausblenden (\\)" : "Seitenleiste einblenden (\\)")
        .accessibilityLabel("Seitenleiste")
        .accessibilityIdentifier("chrome.sidebarToggle")
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) { sidebarToggle }
        ToolbarItem(placement: .navigation) { MailTitleMenu() }
        if WindowToolbar.showsTabs(inRowWidth: rowWidth) {
            ToolbarItem(placement: .automatic) { MailTabStrip() }
        }
        // Flexibler Abstand (macOS 26+): die Aktionsgruppe sitzt rechts, wie bei Mail.
        ToolbarSpacer()
        ToolbarItem(placement: .primaryAction) {
            Button {
                ActionDispatcher.perform(.syncNow)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Jetzt synchronisieren")
            .accessibilityLabel("Jetzt synchronisieren")
            .accessibilityIdentifier("chrome.sync")
        }
        if !model.sidebar.isVisible {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    ActionDispatcher.perform(.calendarToggle)
                } label: {
                    Image(systemName: "calendar")
                }
                .help("Kalender (⌥⌘2)")
                .accessibilityLabel("Kalender")
                .accessibilityIdentifier("chrome.calendar")
            }
        }
        ToolbarItem(placement: .primaryAction) { ComposeToolbarButton() }
        ToolbarItem(placement: .primaryAction) { OverflowToolbarMenu() }
        // Ganz rechts, direkt vor dem Suchfeld: der KI-Filter (⌘O). Vorher saß
        // er als Knopf **im** Suchfeld des 52-pt-Bands; das Feld gehört jetzt
        // SwiftUI, seine Frage braucht deshalb einen eigenen Platz.
        ToolbarItem(placement: .primaryAction) { AIFilterToolbarButton() }
        // Ganz rechts das Suchfeld. `.searchable` füllt die restliche Breite und
        // drückt damit die Aktionsgruppe nach links; ein eigenes Item bleibt
        // schmal und sitzt wie bei Mail am rechten Rand.
        ToolbarItem(placement: .primaryAction) { SearchToolbarField() }
    }

    private var rowWidth: CGFloat {
        WindowToolbar.rowWidth(windowWidth: model.sidebar.windowWidth)
    }
}

/// Titel = aktuelle Ansicht; das Menü wechselt Ansicht, Tab und Konto.
struct MailTitleMenu: View {
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }
    private var theme: Theme { model.theme }

    var body: some View {
        Menu {
            ForEach(MailView.allCases, id: \.self) { (v: MailView) in
                Button((v == box.view && box.filterLabelId == nil && box.filterFolderId == nil ? "✓ " : "") + Strings.view(v)) {
                    ActionDispatcher.perform(.view(v))
                }
            }
            if !box.tabs.isEmpty {
                Divider()
                ForEach(box.tabs) { tab in
                    Button((tab.id == box.currentTabID ? "✓ " : "") + tab.title) {
                        box.setTab(tab.id)
                        box.focusList()
                    }
                }
            }
            if box.accounts.count > 1 {
                Divider()
                Button("Alle Konten") { ActionDispatcher.perform(.account(nil)) }
                ForEach(Array(box.accounts.enumerated()), id: \.element.id) { i, account in
                    Button(account.label + (i < 9 ? "  ⌃\(i + 1)" : "")) { ActionDispatcher.perform(.account(account.id)) }
                }
            }
            Divider()
            Button("Konto hinzufügen …") { ActionDispatcher.perform(.addAccount) }
        } label: {
            HStack(spacing: 4) {
                Text(box.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if Instance.isSandbox { Text("Sandbox").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.accent.color) }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
            }
            .foregroundStyle(theme.ink.color)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ansicht und Konto")
        .accessibilityLabel("Ansicht: \(box.title)")
        .accessibilityIdentifier("chrome.titleMenu")
    }
}

/// Die Tabs als kompakte Auswahl; unter `WindowToolbar.tabsMinRowWidth` stehen
/// sie nur im Titelmenü (M2.17).
struct MailTabStrip: View {
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }
    private var theme: Theme { model.theme }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(box.tabs) { tab in
                let selected = tab.id == box.currentTabID
                Button { box.setTab(tab.id); box.focusList() } label: {
                    HStack(spacing: 6) {
                        Text(tab.title).fontWeight(.medium)
                        if tab.unread > 0 {
                            Text("\(tab.unread)").font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.ink3.color)
                        }
                    }
                    .foregroundStyle(selected ? theme.ink.color : theme.ink2.color)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.hover.color : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.title)\(tab.unread > 0 ? ", \(tab.unread) ungelesen" : "")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("chrome.tabs")
    }
}

/// `square.and.pencil` mit dem Zähler offener Entwürfe (M2.9 §3.4).
struct ComposeToolbarButton: View {
    private var model: AppModel { AppModel.shared }
    private var theme: Theme { model.theme }

    var body: some View {
        let drafts = model.composeDrafts.count
        Button {
            ActionDispatcher.perform(.compose)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.pencil")
                if drafts > 0 {
                    Text("\(drafts)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.accentInk.color)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(theme.accent.color))
                }
            }
        }
        .help("Neue E-Mail (C)")
        .accessibilityLabel(drafts > 0 ? "Neue E-Mail, \(drafts) Entwürfe offen" : "Neue E-Mail")
        .accessibilityIdentifier("chrome.compose")
    }
}

/// `⋯`: Kürzel, Palette, KI-Frage und Einstellungen.
struct OverflowToolbarMenu: View {
    var body: some View {
        Menu {
            Button("Tastenkürzel …\t ?") { ActionDispatcher.perform(.shortcuts) }
            Button("Befehlspalette\t ⌘K") { ActionDispatcher.perform(.palette) }
            Button("Fragen an das Postfach\t ⌘⇧K") { ActionDispatcher.perform(.aiAsk) }
            Divider()
            Button("Einstellungen …\t ⌘,") { SettingsNavigation.request(.appearance) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help("Mehr: Kürzel, Palette, KI, Einstellungen")
        .accessibilityLabel("Mehr")
        .accessibilityIdentifier("chrome.overflow")
    }
}

/// Der KI-Filter der Suche (⌘O). Vorher saß er im Suchfeld des Bands; das Feld
/// gehört jetzt SwiftUI, die Rückfrage hängt deshalb an diesem Item.
struct AIFilterToolbarButton: View {
    private var model: AppModel { AppModel.shared }
    private var theme: Theme { model.theme }

    var body: some View {
        Button {
            model.runAISearchFilter()
        } label: {
            Image(systemName: "sparkles")
        }
        .help("KI-Filter für die Suche (⌥⌘K)")
        .accessibilityLabel("KI-Filter für die Suche")
        .accessibilityIdentifier("chrome.aiFilter")
        .popover(isPresented: Binding(
            get: { model.aiFilterQuestion != nil },
            set: { if !$0 { model.aiFilterQuestion = nil } })) {
            if let question = model.aiFilterQuestion {
                AISearchFilterCard(question: question,
                                   onAnswer: { answer in model.answerAIFilter(question, answer: answer) },
                                   onCancel: { model.aiFilterQuestion = nil })
                    .environment(\.theme, theme)
            }
        }
    }
}

/// Das Suchfeld der Werkzeugleiste (Mail-Modus). Dieselben Aktionen wie im
/// früheren Band-Feld: Return sucht, Esc verlässt die Suche, `/` und ⌘F setzen
/// den Fokus über `model.searchFocusRequest`, ⌘O startet den KI-Filter.
///
/// Das Feld ist ein eigenes `NSTextField` (nicht `TextField`): `@FocusState`
/// greift in einem Toolbar-Item nicht — im Sandbox-Lauf blieb der Fokus nach `/`
/// bei der Liste. Über `makeFirstResponder` funktioniert es.
struct SearchToolbarField: View {
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }
    private var theme: Theme { model.theme }

    var body: some View {
        @Bindable var box = box
        // Der Wert wird hier gelesen, damit die Ansicht ihm folgt (Fokus-Anforderung).
        let focusToken = model.searchFocusRequest
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.ink3.color)
            PlainSearchField(text: $box.searchText,
                             focusToken: focusToken,
                             onSubmit: { box.runSearch(); box.focusList() },
                             onCancel: { box.endSearch(); box.focusList() })
                .frame(width: box.searchText.isEmpty ? 150 : 170, height: 17)
            if !box.searchText.isEmpty {
                Button {
                    box.endSearch()
                    box.searchText = ""
                    box.focusList()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.ink3.color)
                .help("Suche leeren")
                .accessibilityLabel("Suche leeren")
            }
        }
        .padding(.horizontal, 6)
        .frame(width: box.searchText.isEmpty ? 186 : 210, height: 24)
        .onChange(of: model.searchAIRequest) { _, _ in
            guard model.aiFilterQuestion == nil else { return }
            model.runAISearchFilter()
        }
        .animation(Motion.animation, value: box.searchText.isEmpty)
        .accessibilityIdentifier("chrome.search")
    }
}

/// Schmales Suchfeld ohne Rahmen — die Kapsel malt das Toolbar-Item.
struct PlainSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlainSearchField
        var lastFocusToken: Int

        init(_ parent: PlainSearchField) {
            self.parent = parent
            lastFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = Strings.search
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Auch bei aktivem Feldeditor übernehmen: `endSearch()` (Esc, Knopf
        // „Suche leeren“) setzt `searchText` im Modell auf "", das Feld muss
        // mitgehen, sonst bliebe der alte Text stehen.
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        // `/` und ⌘F: Fokus nur bei einer **neuen** Anforderung setzen.
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }
}

// MARK: - Kalender

/// Dieselbe Leiste im Kalender: blättern, „Heute", Überschrift, Ansichtswahl,
/// neuer Termin, Verfassen und das `⋯`-Menü.
struct CalendarToolbar: ToolbarContent {
    private var model: AppModel { AppModel.shared }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.sidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(model.sidebar.isVisible ? "Seitenleiste ausblenden (\\)" : "Seitenleiste einblenden (\\)")
            .accessibilityLabel("Seitenleiste")
            .accessibilityIdentifier("chrome.sidebarToggle")
        }
        ToolbarItem(placement: .automatic) { CalendarPagingItems() }
        ToolbarSpacer()
        ToolbarItem(placement: .primaryAction) { CalendarModeItem() }
        ToolbarItem(placement: .primaryAction) {
            Button {
                ActionDispatcher.perform(.calendarNewEvent)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Neuer Termin")
                }
            }
            .help("Neuer Termin (B)")
            .accessibilityLabel("Neuer Termin")
            .accessibilityIdentifier("chrome.newEvent")
        }
        ToolbarItem(placement: .primaryAction) { ComposeToolbarButton() }
        ToolbarItem(placement: .primaryAction) { CalendarOverflowMenu() }
    }
}

/// Zurück/Weiter, „Heute" und die Überschrift des Zeitraums.
struct CalendarPagingItems: View {
    private var model: AppModel { AppModel.shared }
    private var store: CalendarStore { model.calendar }
    private var theme: Theme { model.theme }

    var body: some View {
        HStack(spacing: 6) {
            Button { store.page(-1) } label: { Image(systemName: "chevron.left") }
                .help("Zurück (-)")
                .accessibilityLabel("Zurück")
                .accessibilityIdentifier("chrome.calendarBack")
            Button { store.page(1) } label: { Image(systemName: "chevron.right") }
                .help("Weiter (=)")
                .accessibilityLabel("Weiter")
                .accessibilityIdentifier("chrome.calendarForward")
            Button("Heute") { store.jumpToToday() }
                .help("Heute (T)")
                .accessibilityIdentifier("chrome.calendarToday")
            Text(store.heading())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .padding(.leading, 4)
                .accessibilityIdentifier("chrome.calendarHeading")
        }
    }
}

/// Tag | Woche | Monat | Jahr | Liste — als Segment, wenn es passt, sonst als
/// Popup mit dem aktuellen Titel (M2.17).
struct CalendarModeItem: View {
    private var model: AppModel { AppModel.shared }
    private var store: CalendarStore { model.calendar }
    private var theme: Theme { model.theme }

    var body: some View {
        if WindowToolbar.showsModePicker(inRowWidth: rowWidth) {
            picker
        } else {
            menu
        }
    }

    private var rowWidth: CGFloat {
        WindowToolbar.rowWidth(windowWidth: model.sidebar.windowWidth)
    }

    private var menu: some View {
        Menu {
            ForEach(CalendarStore.Mode.allCases) { mode in
                Button {
                    store.setMode(mode)
                } label: {
                    Text((store.mode == mode ? "✓ " : "") + mode.title)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.mode.title).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
            }
            .foregroundStyle(theme.ink.color)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ansicht (\(store.mode.shortcut))")
        .accessibilityLabel("Ansicht: \(store.mode.title)")
        .accessibilityIdentifier("chrome.calendarModeMenu")
    }

    /// Eigenes Segment, weil das System-Segment den Theme-Akzent ignoriert.
    private var picker: some View {
        HStack(spacing: 2) {
            ForEach(CalendarStore.Mode.allCases) { mode in
                let active = store.mode == mode
                Button { store.setMode(mode) } label: {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? theme.ink.color : theme.ink2.color)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(active ? theme.surface.color : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(mode.title) (\(mode.shortcut))")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.hover.color))
        .accessibilityIdentifier("chrome.calendarModePicker")
    }
}

struct CalendarOverflowMenu: View {
    var body: some View {
        Menu {
            Button("Mail") { ActionDispatcher.perform(.calendarClose) }
            Divider()
            Button("Tastenkürzel …\t ?") { ActionDispatcher.perform(.shortcuts) }
            Button("Befehlspalette\t ⌘K") { ActionDispatcher.perform(.palette) }
            Divider()
            Button("Einstellungen …\t ⌘,") { SettingsNavigation.request(.appearance) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help("Mehr")
        .accessibilityLabel("Mehr")
        .accessibilityIdentifier("chrome.overflow")
    }
}
