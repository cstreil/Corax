import AppKit
import Observation
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
        // M2.15 1.1: Die Titelbar liegt über dem Inhalt und schluckt dort
        // jeden Klick (`hittest` → `NSTitlebarView`). Das Band beginnt deshalb
        // **unter** ihr; der Streifen darüber bleibt Titelbar (Ampel).
        let titleInset = ChromeMetrics.shared.topInset
        ZStack(alignment: .bottom) {
            // M2.9: Seitenleiste als eigene Spalte, daneben eine gemeinsame
            // 52-pt-Zeile für Mail und Kalender, darunter der Inhalt.
            GeometryReader { geo in
                // Das Band liegt **über** dem Inhalt (ZStack), nicht davor:
                // ein Hintergrund im Inhalt dehnt sich in die Safe Area und
                // deckte das Band sonst zu (im Sandbox-Lauf: Kalender statt
                // Werkzeugleiste). Der Inhalt ist um die Bandhöhe eingerückt,
                // damit nichts Wichtiges darunter liegt.
                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        if model.sidebar.isVisible {
                            SidebarColumn()
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        VStack(spacing: 0) {
                            if model.calendarOpen {
                                CalendarScreenView()
                            } else {
                                listArea
                            }
                            HintBar()
                        }
                    }
                    .padding(.top, titleInset + WindowChromeRow.height)
                    WindowChromeRow()
                        .padding(.top, titleInset)
                        // Färbt auch den Titelbar-Streifen, damit Band und
                        // Ampelzone eine Fläche sind.
                        .background(theme.bar.color)
                    // M2.9 Stufe B: das Verfassen-Panel liegt **vor** Toast,
                    // Palette und Pickern in diesem ZStack und damit unter
                    // ihnen (§3.6.4).
                    ComposeDockOverlay(windowSize: geo.size, topInset: titleInset)
                }
                .onAppear { model.sidebar.update(windowWidth: geo.size.width) }
                .onChange(of: geo.size.width) { _, width in model.sidebar.update(windowWidth: width) }
            }
            ToastView().padding(.bottom, 50)
            if model.paletteOpen { CommandPalette().transition(.opacity) }
            // M2.18m: `G` `O` — Ordner oder Label anspringen.
            if model.goToOpen { GoToPicker().transition(.opacity) }
            // M2.5: die Auswahl-Dialoge (Verschieben, Label, Split, Löschen).
            if model.moveOpen { MovePickerView().transition(.opacity) }
            if model.labelOpen { LabelPickerView().transition(.opacity) }
            if model.splitOpen { SplitPickerView().transition(.opacity) }
            if model.permanentDeleteOpen { PermanentDeleteDialogView().transition(.opacity) }
            if model.askOpen { AskPanelView().transition(.opacity) }
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
        .animation(Motion.animation, value: model.askOpen)
        .animation(Motion.animation, value: model.shortcutsOpen)
        .animation(Motion.animation, value: theme)
        .animation(Motion.animation, value: model.sidebar.isVisible)
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
            if box.searchQuery != nil {
                EmptyState(title: "Keine Treffer", detail: "Esc leert die Suche."
                    // Tauri's InboxZero: the same hint row the list shows.
                    + "\n\nMit / eine neue Suche beginnen.")
            } else {
                InboxZeroView(viewTitle: box.tabs.first(where: { $0.id == box.currentTabID })?.title ?? box.title)
            }
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
        return MailListView(rows: rows, selectedId: box.selectedId, selectedIds: box.selectedIds,
                            expandedId: box.expandedId,
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
        var items: [(String, String)]
        if model.calendarOpen {
            // M2.9: der Kalender hat keine eigene Hinweisleiste mehr, die Zeile
            // zeigt seine Tasten.
            items = [("D/W/M", "Ansicht"), ("- / =", "blättern"), ("T", "heute"),
                     ("B", "neu"), ("\\", "Seitenleiste"), ("1/Esc", "zurück")]
        } else if model.compose.hasDraftFocus {
            // M2.9: das Panel hat die Tastatur.
            items = [("⌘↵", "senden"), ("Esc", "minimieren"), ("⌃Tab", "zur Liste"), ("⌘⇧⌫", "verwerfen")]
        } else if box.inlineCompose != nil {
            items = [("⌘↵", "senden"), ("Esc", "verwerfen"), ("⌘⇧M", "lösen")]
        } else if box.expandedId != nil {
            items = [("J", "nächste"), ("K", "vorige"), ("R", "antworten"), ("E", "archivieren"), ("Esc", "schließen")]
        } else {
            items = [("↑↓", "bewegen"), ("↵", "öffnen"), ("E", "archivieren"), ("Tab", "Split wechseln")]
            if !model.compose.isEmpty { items.append(("⌃Tab", "Entwurf")) }
            items.append(("?", "alle Kürzel"))
        }
        // Eine Zeile statt zweier übereinander: mit fünf Tasten liefen die
        // zentrierten Kürzel in den Sync-Text (Sandbox-Lauf M2.9).
        return HStack(spacing: 12) {
            // M2.18n: `G` allein war unsichtbar — solange die Folge läuft,
            // zeigt die Leiste nur, was zur Wahl steht.
            if model.goSequenceActive {
                goHint
            } else {
            HStack(spacing: 4) {
                if let sync = model.sync.summary {
                    HStack(spacing: 6) {
                        if sync != Strings.offline { ProgressView().controlSize(.mini) } else { Image(systemName: "wifi.slash") }
                        Text(sync).lineLimit(1).truncationMode(.tail)
                    }
                    // Capped so a long sync line never runs into the centred
                    // key hints of the same bar (seen with "Konto muss neu verbunden werden").
                    .frame(maxWidth: model.calendarOpen ? 170 : 200, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: 210, alignment: .leading)
            Spacer(minLength: 6)
            HStack(spacing: 16) {
                ForEach(items, id: \.0) { key, label in
                    HStack(spacing: 6) { KeyCap(key); Text(label) }
                        .fixedSize()
                }
            }
            .layoutPriority(2)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                // P2g: "Nur lesen" while the real instance may not write; a
                // click switches, same as the menu item.
                if model.calendarOpen, model.calendar.meetingReminderMinutes > 0 {
                    Text("Erinnerung \(model.calendar.meetingReminderMinutes) min vorher")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                }
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
            .frame(maxWidth: 240, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .font(.system(size: 12))
        .foregroundStyle(theme.ink3.color)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(theme.bar.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 0.5) }
    }

    /// M2.18n: der Hinweis während der `G`-Folge. Erst alle Ziele, und wenn die
    /// Breite nicht reicht, die wichtigsten mit `O` vorn — der Weg zu Ordner
    /// und Label darf nie abgeschnitten sein.
    private var goHint: some View {
        ViewThatFits(in: .horizontal) {
            goHintRow(Array(GoSequence.targets))
            goHintRow(compactGoTargets)
        }
        .frame(maxWidth: .infinity)
    }

    private var compactGoTargets: [GoSequenceTarget] {
        let keys = ["o", "i", "s", "d", "t"]
        return keys.compactMap { GoSequence.target(for: $0) }
    }

    private func goHintRow(_ targets: [GoSequenceTarget]) -> some View {
        // 11,5 pt und 7 pt Abstand: damit passen alle zehn Ziele in die Leiste
        // neben der Seitenleiste (883 pt breit), statt in die Kompaktform zu
        // fallen.
        HStack(spacing: 7) {
            Text(GoSequence.headline)
                .fontWeight(.medium)
                .foregroundStyle(theme.ink2.color)
            ForEach(targets) { target in
                HStack(spacing: 3.5) {
                    KeyCap(target.key.uppercased())
                    Text(target.title)
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 11.5))
        .fixedSize()
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

/// M2.15 1.1: die Höhe der Titelbar über dem Inhalt. Ohne Werkzeugleiste sind
/// das 32 pt — und genau dort schluckt AppKit jeden Klick (`NSTitlebarView`).
/// Band und Inhalt beginnen deshalb unterhalb; der Wert kommt beim Fenster-
/// aufbau und bei Größenänderungen aus dem Fenster selbst.
@Observable
final class ChromeMetrics: @unchecked Sendable {
    static let shared = ChromeMetrics()
    private(set) var topInset: CGFloat = 32

    func update(_ window: NSWindow) {
        MainActor.assumeIsolated {
            let inset = max(0, window.frame.height - window.contentLayoutRect.maxY)
            guard abs(inset - topInset) > 0.5 else { return }
            topInset = inset
            PerfLog.shared.write("chrome_top_inset h=\(Int(inset))")
        }
    }
}

/// Window setup: transparent title bar over the content, appearance and
/// opacity per theme. Bewusst **ohne** `NSToolbar` — siehe `configure`.
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
        // M2.15 1.1: **keine** `NSToolbar`. Eine leere Werkzeugleiste liegt als
        // `NSToolbarView` über dem 52-pt-Band und schluckt jeden Klick — im
        // Sandbox-Lauf kam an jedem Knopf `NSToolbarView<NSTitlebarView<…` als
        // Treffer, ein AX-Press ging daran vorbei und „funktionierte“ deshalb.
        // Auch ohne Werkzeugleiste bleibt ein 32-pt-Titelbarstreifen, der
        // Treffer abfängt (`NSTitlebarView`). Deshalb beginnt das Band unter
        // der Titelbar; die Ampel bleibt in ihrem Streifen.
        if window.toolbar != nil { window.toolbar = nil }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.title = Instance.title
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("RabeMain")
        ChromeMetrics.shared.update(window)
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
