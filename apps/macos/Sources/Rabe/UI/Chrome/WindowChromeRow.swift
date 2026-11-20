import RabeKit
import SwiftUI

/// M2.9: die eine 52-pt-Zeile über dem Inhalt, für Mail **und** Kalender.
///
/// Vorher zeichnete die Mailliste ihre Werkzeugleiste ins Fensterband, der
/// Kalender setzte per `padding(.top, 52)` darunter an — daher der Sonderfall
/// und die Lücke im Kalender (M2.2). Jetzt malt diese Zeile das Band in beiden
/// Modi, und der Inhalt beginnt immer direkt darunter.
struct WindowChromeRow: View {
    /// Höhe des Bands; der Inhalt beginnt darunter (M2.9).
    static let height: CGFloat = 52

    @Environment(\.theme) private var theme
    private var model: AppModel { AppModel.shared }

    var body: some View {
        // Ein Band über das **ganze** Fenster: links die Ampelzone (und bei
        // sichtbarer Seitenleiste deren Breite mit dem Ausblenden-Knopf), rechts
        // die Werkzeugleiste des Modus. So liegt nie Inhalt unter dem Band, und
        // die Ampel bleibt sichtbar — sie liegt über diesem Band, nicht über
        // einer eigenen Fläche der Seitenleiste.
        HStack(spacing: 0) {
            lead
            if model.calendarOpen {
                CalendarChromeRow()
            } else {
                MailChromeRow()
            }
        }
        .frame(height: Self.height)
        .background(WindowDragArea())
        .background(theme.bar.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 0.5) }
    }

    private var lead: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 64, height: 1)
            Spacer(minLength: 0)
        }
        .frame(width: model.sidebar.isVisible ? SidebarState.width : 104)

    }
}

// MARK: - Mail

/// Werkzeugleiste der Liste: Ausblenden-Knopf (nur ohne Seitenleiste), Titel,
/// Tabs, Sync, Suche, Verfassen mit Zähler, Kalender (nur ohne Seitenleiste)
/// und das `⋯`-Menü.
struct MailChromeRow: View {
    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }
    private var sidebarVisible: Bool { model.sidebar.isVisible }

    var body: some View {
        @Bindable var box = box
        HStack(spacing: 12) {
            if sidebarVisible {
                ToolbarIcon(symbol: "sidebar.left", help: "Seitenleiste ausblenden (\\)") {
                    model.sidebar.toggle()
                }
            }
            titleMenu
            tabs
            Spacer(minLength: 8)
            ToolbarIcon(symbol: "arrow.clockwise", help: "Jetzt synchronisieren") {
                ActionDispatcher.perform(.syncNow)
            }
            searchField
            composeButton
            if !sidebarVisible {
                ToolbarIcon(symbol: "calendar", help: "Kalender (2)") {
                    ActionDispatcher.perform(.calendarToggle)
                }
            }
            overflowMenu
        }
        .padding(.leading, sidebarVisible ? 6 : 14)
        .padding(.trailing, 14)
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: model.searchAIRequest) { _, _ in
            // ⌘O from the menu or the palette: the search field's text is the
            // request to the filter.
            guard model.aiFilterQuestion == nil else { return }
            model.runAISearchFilter()
        }
    }

    /// Title = current view; the menu switches view and account.
    private var titleMenu: some View {
        Menu {
            ForEach(MailView.allCases, id: \.self) { (v: MailView) in
                Button((v == box.view && box.filterLabelId == nil && box.filterFolderId == nil ? "✓ " : "") + Strings.view(v)) {
                    ActionDispatcher.perform(.view(v))
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
                Text(box.title).font(.system(size: 13, weight: .semibold))
                if Instance.isSandbox { Text("Sandbox").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.accent.color) }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
            }
            .foregroundStyle(theme.ink.color)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Ansicht: \(box.title)")
    }

    private var tabs: some View {
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
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.hover.color : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? theme.line.color : .clear, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.title)\(tab.unread > 0 ? ", \(tab.unread) ungelesen" : "")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var searchField: some View {
        @Bindable var box = box
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(searchFocused ? theme.ink2.color : theme.ink3.color)
            TextField(Strings.search, text: $box.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { box.runSearch(); box.focusList() }
                .onKeyPress(.escape) { box.endSearch(); searchFocused = false; box.focusList(); return .handled }
                .accessibilityLabel("Suchen")
            if !searchFocused && box.searchText.isEmpty { KeyCap("/") }
            Button { model.runAISearchFilter() } label: {
                Image(systemName: "sparkles").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink3.color)
            .help("KI-Filter für die Suche (⌘O)")
            .accessibilityLabel("KI-Filter für die Suche")
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
        .padding(.horizontal, 8)
        .frame(width: searchFocused || !box.searchText.isEmpty ? 260 : 180, height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.hover.color))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? theme.accent.color : theme.line.color, lineWidth: searchFocused ? 1 : 0.5))
        .animation(Motion.animation, value: searchFocused)
    }

    /// `square.and.pencil` mit dem Zähler offener Entwürfe (M2.9 §3.4).
    private var composeButton: some View {
        let drafts = model.composeDrafts.count
        return Button { ActionDispatcher.perform(.compose) } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink2.color)
                    .frame(width: 30, height: 28)
                if drafts > 0 {
                    Text("\(drafts)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.accentInk.color)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(theme.accent.color))
                        .offset(x: 4, y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Neue E-Mail (C)")
        .accessibilityLabel(drafts > 0 ? "Neue E-Mail, \(drafts) Entwürfe offen" : "Neue E-Mail")
    }

    private var overflowMenu: some View {
        Menu {
            Button("Tastenkürzel …\t ?") { ActionDispatcher.perform(.shortcuts) }
            Button("Befehlspalette\t ⌘K") { ActionDispatcher.perform(.palette) }
            Button("Fragen an das Postfach\t ⌘⇧K") { ActionDispatcher.perform(.aiAsk) }
            Divider()
            Button("Einstellungen …\t ⌘,") { SettingsNavigation.request(.appearance) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mehr: Kürzel, Palette, KI, Einstellungen")
        .accessibilityLabel("Mehr")
    }
}

// MARK: - Kalender

/// Kalender-Kopf in derselben Zeile: blättern, „Heute", Zeitraum, die drei
/// Ansichten, neuer Termin, Verfassen und das `⋯`-Menü.
struct CalendarChromeRow: View {
    @Environment(\.theme) private var theme
    private var model: AppModel { AppModel.shared }
    private var store: CalendarStore { model.calendar }
    private var sidebarVisible: Bool { model.sidebar.isVisible }

    var body: some View {
        HStack(spacing: 10) {
            if sidebarVisible {
                ToolbarIcon(symbol: "sidebar.left", help: "Seitenleiste ausblenden (\\)") {
                    model.sidebar.toggle()
                }
            }
            ToolbarIcon(symbol: "chevron.left", help: "Zurück (-)") { store.page(-1) }
            ToolbarIcon(symbol: "chevron.right", help: "Weiter (=)") { store.page(1) }
            Button("Heute") { store.jumpToToday() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color, lineWidth: 0.6))
                .help("Heute (T)")
            Text(store.heading())
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            modePicker
            Button { ActionDispatcher.perform(.calendarNewEvent) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                    Text("Neuer Termin").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(theme.accentInk.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent.color))
            }
            .buttonStyle(.plain)
            .help("Neuer Termin (B)")
            ToolbarIcon(symbol: "square.and.pencil", help: "Neue E-Mail (C)") { ActionDispatcher.perform(.compose) }
            Menu {
                Button("Mail") { ActionDispatcher.perform(.calendarClose) }
                Divider()
                Button("Tastenkürzel …\t ?") { ActionDispatcher.perform(.shortcuts) }
                Button("Befehlspalette\t ⌘K") { ActionDispatcher.perform(.palette) }
                Divider()
                Button("Einstellungen …\t ⌘,") { SettingsNavigation.request(.appearance) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.ink2.color)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mehr")
            .accessibilityLabel("Mehr")
        }
        .padding(.leading, sidebarVisible ? 6 : 12)
        .padding(.trailing, 14)
    }

    /// Tag | Woche | Monat — ein eigenes Segment, weil das System-Segment den
    /// Theme-Akzent ignoriert (Entwurf §5).
    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(CalendarStore.Mode.allCases) { mode in
                let active = store.mode == mode
                Button { store.setMode(mode) } label: {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? theme.ink.color : theme.ink2.color)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
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
    }
}
