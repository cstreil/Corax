import AppKit
import RabeKit
import SwiftUI

/// Main window content: toolbar (traffic lights, title menu, tabs, search,
/// new, shortcuts), list, hint bar, toast, sheets.
struct MainView: View {
    @Environment(\.openWindow) private var openWindow
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }

    var body: some View {
        let theme = model.theme
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                ToolbarRow()
                listArea
                HintBar()
            }
            ToastView().padding(.bottom, 50)
            if model.paletteOpen { CommandPalette().transition(.opacity) }
            if model.shortcutsOpen { ShortcutSheet().transition(.opacity) }
            if model.perfOverlay { PerfOverlayView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 60).padding(.trailing, 14) }
        }
        .environment(\.theme, theme)
        .background(WindowBackground(theme: theme))
        .background(WindowConfigurator(theme: theme))
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: Binding(get: { model.accountSheetOpen }, set: { model.accountSheetOpen = $0 })) {
            AccountSheet().environment(\.theme, theme)
        }
        .animation(Motion.animation, value: model.paletteOpen)
        .animation(Motion.animation, value: model.shortcutsOpen)
        .animation(Motion.animation, value: theme)
        .onAppear {
            model.openComposeWindow = { id in openWindow(id: "compose", value: id) }
            PerfLog.shared.write("first_paint ms=\(PerfLog.shared.elapsedMilliseconds)")
        }
    }

    @ViewBuilder private var listArea: some View {
        if let error = model.startError {
            EmptyState(title: "Start fehlgeschlagen", detail: error)
        } else if !box.loadedOnce {
            EmptyState(title: model.coreReady ? "Liste wird geladen …" : "Rabe startet …", detail: nil, spinner: true)
        } else if !box.hasThreads && !box.isLoading {
            EmptyState(title: box.searchQuery != nil ? "Keine Treffer" : "Alles erledigt",
                       detail: box.searchQuery != nil ? "Esc leert die Suche." : "Inbox Zero. Gönn dir einen Kaffee.")
        } else {
            MailListContainer()
        }
    }
}

/// Reads exactly what the table needs, so the table updates for those changes only.
struct MailListContainer: View {
    private var box: MailboxStore { AppModel.shared.mailbox }
    var body: some View {
        let t0 = CACurrentMediaTime()
        let rows = box.rows
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 4 { PerfLog.shared.write("slow_rows ms=\(Int(ms)) rows=\(rows.count)") }
        return MailListView(rows: rows, selectedId: box.selectedId, expandedId: box.expandedId,
                     theme: AppModel.shared.theme, contentStamp: stamp, focusStamp: box.focusListRequest)
            .onAppear { PerfLog.shared.write("first_list_visible ms=\(PerfLog.shared.elapsedMilliseconds) rows=\(box.threads.count)") }
    }

    /// Changes whenever a row's visible content changes.
    private var stamp: Int { box.contentVersion &* 31 &+ box.labels.count }
}

struct EmptyState: View {
    let title: String
    let detail: String?
    var spinner = false
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 6) {
            if spinner { ProgressView().controlSize(.small).padding(.bottom, 6) }
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.ink2.color)
            if let detail { Text(detail).foregroundStyle(theme.ink3.color).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Toolbar

struct ToolbarRow: View {
    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }

    var body: some View {
        @Bindable var box = box
        HStack(spacing: 14) {
            Color.clear.frame(width: 64, height: 1)   // traffic lights
            titleMenu
            tabs
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(searchFocused ? theme.ink2.color : theme.ink3.color)
                TextField(Strings.search, text: $box.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { box.runSearch(); box.focusList() }
                    .onKeyPress(.escape) { box.endSearch(); searchFocused = false; box.focusList(); return .handled }
                    .accessibilityLabel("Suchen")
                if !searchFocused && box.searchText.isEmpty { KeyCap("/") }
            }
            .padding(.horizontal, 8)
            .frame(width: searchFocused || !box.searchText.isEmpty ? 260 : 180, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.hover.color))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? theme.accent.color : theme.line.color, lineWidth: searchFocused ? 1 : 0.5))
            .animation(Motion.animation, value: searchFocused)
            ToolbarIcon(symbol: "square.and.pencil", help: "Neue E-Mail (C)") { ActionDispatcher.perform(.compose) }
            ToolbarIcon(symbol: "keyboard", help: "Tastenkürzel (?)") { ActionDispatcher.perform(.shortcuts) }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(WindowDragArea())
        .background(theme.bar.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 0.5) }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
    }

    /// Title = current view; the menu switches view and account (no sidebar).
    private var titleMenu: some View {
        Menu {
            ForEach(MailView.allCases, id: \.self) { (v: MailView) in
                Button((v == box.view ? "✓ " : "") + Strings.view(v)) { ActionDispatcher.perform(.view(v)) }
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
}

struct ToolbarIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover ? theme.hover.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Hint bar (mockup `.hintbar`) with sync state

struct HintBar: View {
    @Environment(\.theme) private var theme
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let box = model.mailbox
        let items: [(String, String)]
        if box.inlineCompose != nil {
            items = [("⌘↵", "senden"), ("Esc", "verwerfen")]
        } else if box.expandedId != nil {
            items = [("J", "nächste"), ("K", "vorige"), ("R", "antworten"), ("E", "archivieren"), ("Esc", "schließen")]
        } else {
            items = [("↑↓", "bewegen"), ("↵", "öffnen"), ("E", "archivieren"), ("Tab", "Inbox wechseln"), ("?", "alle Kürzel")]
        }
        return ZStack {
            HStack(spacing: 16) {
                ForEach(items, id: \.0) { key, label in
                    HStack(spacing: 6) { KeyCap(key); Text(label) }
                }
            }
            HStack {
                if let sync = model.sync.summary {
                    HStack(spacing: 6) {
                        if sync != Strings.offline { ProgressView().controlSize(.mini) } else { Image(systemName: "wifi.slash") }
                        Text(sync)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                // P2g: "Nur lesen" while the real instance may not write; a
                // click switches, same as the menu item.
                if model.writeAccess.showsReadOnlyHint {
                    Button { model.writeAccess.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.fill").font(.system(size: 10))
                            Text("Nur lesen")
                        }
                        .foregroundStyle(theme.ink2.color)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Änderungen erlauben (Postfach → Änderungen erlauben)")
                    .accessibilityLabel("Nur lesen. Klicken schaltet Änderungen frei")
                    .padding(.trailing, 10)
                }
                if box.isLoading && box.loadedOnce { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 14)
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.ink3.color)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(theme.bar.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 0.5) }
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(\.theme) private var theme
    private var toasts: ToastCenter { AppModel.shared.toasts }

    var body: some View {
        ZStack {
            if let toast = toasts.current {
                HStack(spacing: 12) {
                    Text(toast.text).fontWeight(.medium)
                    if let title = toast.actionTitle {
                        Button { toasts.runAction() } label: {
                            HStack(spacing: 6) {
                                Text(title)
                                Text("Z").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 5)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1)).opacity(0.7)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(theme.isDark ? Color.black : Color.white)
                .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: toast.actionTitle == nil ? 14 : 10))
                .background(RoundedRectangle(cornerRadius: 10).fill(toast.isError ? Color(red: 0.75, green: 0.25, blue: 0.2) : (theme.isDark ? Color(white: 0.945) : Color(red: 0.11, green: 0.106, blue: 0.098))))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(Motion.animation, value: toasts.current?.id)
    }
}

// MARK: - Window plumbing

/// Background per theme. Glas uses the real material behind the window.
struct WindowBackground: View {
    let theme: Theme
    var body: some View {
        if theme.usesGlass {
            // Mockup `glass`: the window (`--win`, white 58 %) lies over a
            // blurred page with a blue and a peach glow. Natively the page is
            // the real desktop behind a translucent material; the two glows
            // from `--page` tint it so the theme reads the same on any wallpaper.
            ZStack {
                VisualEffect(material: .sidebar, blending: .behindWindow)
                GeometryReader { geo in
                    let r = max(geo.size.width, geo.size.height)
                    ZStack {
                        RadialGradient(colors: [RGBA.hex(0xc9d8ff).color, .clear], center: UnitPoint(x: 0.15, y: 0.1),
                                       startRadius: 0, endRadius: r * 0.95)
                        RadialGradient(colors: [RGBA.hex(0xffd9c7).color, .clear], center: UnitPoint(x: 0.9, y: 0.8),
                                       startRadius: 0, endRadius: r * 0.75)
                    }
                }
                theme.win.color
            }
            .ignoresSafeArea()
        } else {
            theme.win.color.ignoresSafeArea()
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Window setup: transparent title bar over the content, an empty unified
/// toolbar so the traffic lights sit in the middle of the 52 pt toolbar row,
/// appearance and opacity per theme.
struct WindowConfigurator: NSViewRepresentable {
    let theme: Theme
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { configure(v.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if window.toolbar == nil {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            let toolbar = NSToolbar(identifier: "rabe.main")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.title = Instance.title
            window.tabbingMode = .disallowed
            window.setFrameAutosaveName("RabeMain")
        }
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.isOpaque = !theme.usesGlass
        window.backgroundColor = theme.usesGlass ? .clear : theme.win.ns
    }
}

/// Lets the toolbar row move the window like a title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
