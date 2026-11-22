import AppKit
import CoraxKit
import SwiftUI

/// M2.9 Stufe B: das Verfassen-Panel unten rechts und die Leisten der
/// minimierten Entwürfe (Entwurf §3.1–§3.4).
///
/// Liegt im `ZStack` der `MainView` **vor** Toast, Palette und Pickern: die
/// müssen über dem Panel liegen (§3.6.4). Das Panel dockt unten rechts an, die
/// Unterkante sitzt auf der Hinweisleiste.
struct ComposeDockOverlay: View {
    /// Fenstergröße ohne Rücksicht auf die Seitenleiste.
    let windowSize: CGSize
    /// Höhe der Titelbar über dem Band (M2.15 1.1: dort schluckt AppKit Klicks).
    var topInset: CGFloat = 0
    @Environment(\.theme) private var theme
    private var model: AppModel { AppModel.shared }
    private var dock: ComposeDock { model.compose }

    var body: some View {
        content
            .animation(dockAnimation, value: dock.openId)
            .animation(dockAnimation, value: dock.barIds)
            .animation(dockAnimation, value: dock.isMaximized)
    }

    @ViewBuilder private var content: some View {
        let inset = model.sidebar.isVisible ? SidebarState.width : 0
        let contentWidth = max(0, windowSize.width - inset)
        let contentHeight = max(0, windowSize.height - topInset - ComposeDock.hintBarHeight)
        if let id = dock.openId, let draft = model.composeDrafts[id], dock.isMaximized {
            maximized(draft: draft, contentWidth: contentWidth, contentHeight: contentHeight, inset: inset)
        } else {
            docked(contentWidth: contentWidth, contentHeight: contentHeight)
        }
    }

    /// Offen oder minimiert: Leisten links, das Panel rechts.
    private func docked(contentWidth: CGFloat, contentHeight: CGFloat) -> some View {
        let panelWidth = ComposeDock.panelWidth(contentWidth: contentWidth)
        let bars = dock.barIds
        let available = contentWidth - ComposeDock.trailingInset
            - (dock.openId == nil ? 0 : panelWidth + ComposeDock.barGap)
        let fit = ComposeDock.barOverflow(count: bars.count, available: available)
        return HStack(alignment: .bottom, spacing: ComposeDock.barGap) {
            if fit.hidden > 0 {
                ComposeOverflowChip(ids: Array(bars.dropFirst(fit.shown)), hidden: fit.hidden)
            }
            ForEach(Array(bars.prefix(fit.shown)), id: \.self) { id in
                if let draft = model.composeDrafts[id] {
                    ComposeBarView(draft: draft)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if let id = dock.openId, let draft = model.composeDrafts[id] {
                ComposePanelView(draft: draft, width: panelWidth,
                                 height: ComposeDock.panelHeight(contentHeight: contentHeight))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.trailing, ComposeDock.trailingInset)
        .padding(.bottom, ComposeDock.hintBarHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    /// Maximiert: das Panel füllt den Inhaltsbereich mit 24 pt Rand, die Liste
    /// dahinter ist zu 20 % abgedunkelt (§3.3).
    private func maximized(draft: ComposeDraft, contentWidth: CGFloat, contentHeight: CGFloat,
                           inset: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.2))
                .allowsHitTesting(false)
                .padding(.top, topInset)
                .padding(.bottom, ComposeDock.hintBarHeight)
                .padding(.leading, inset)
            ComposePanelView(draft: draft, width: max(ComposeDock.minimumWidth, contentWidth - 48),
                             height: max(ComposeDock.minimumHeight, contentHeight - 48))
                .padding(.bottom, ComposeDock.hintBarHeight + 24)
                .padding(.top, topInset + 24)
                .padding(.leading, inset + 24)
                .padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var dockAnimation: Animation? {
        Motion.reduce ? .easeInOut(duration: 0.12) : .timingCurve(0.22, 0.8, 0.2, 1, duration: 0.22)
    }
}

/// Das Panel selbst: Kopf mit Titel und Fensterknöpfen, darunter der Editor.
/// Der Panel-Körper ist der vorhandene `ComposeView` — hier kommt nur die Hülle
/// dazu (Entwurf §5: „keine dritte Kopie der Felder").
struct ComposePanelView: View {
    @Bindable var draft: ComposeDraft
    let width: CGFloat
    let height: CGFloat
    @Environment(\.theme) private var theme
    private var model: AppModel { AppModel.shared }
    private var dock: ComposeDock { model.compose }

    var body: some View {
        VStack(spacing: 0) {
            head
            Rectangle().fill(theme.line.color).frame(height: 0.5)
            ComposeView(draft: draft, presentation: .docked,
                        onEscape: { dock.escapeOpenPanel() },
                        focusRequest: dock.focusRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: width, height: height)
        .background(panelShape.fill(theme.surface.color))
        .clipShape(panelShape)
        .overlay(panelShape.strokeBorder(dock.keyboardFocus == draft.id ? theme.accent.color.opacity(0.55)
                                                                       : theme.line.color,
                                         lineWidth: dock.keyboardFocus == draft.id ? 1.5 : 0.5))
        .shadow(color: .black.opacity(theme.isDark ? 0.55 : 0.18), radius: 22, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Entwurf: \(draft.panelTitle)")
    }

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
    }

    /// 38 pt: Betreff (sonst „Neue E-Mail"), „Entwurf gesichert", die vier
    /// Fensterknöpfe. Ein Klick auf eine freie Stelle minimiert (wie Gmail).
    private var head: some View {
        HStack(spacing: 8) {
            Text(draft.panelTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(theme.ink.color)
                .accessibilityLabel("Entwurf: \(draft.panelTitle)")
            if draft.savedOnce {
                Text(Strings.draftSaved)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            headButton("minus", help: "Minimieren (Esc)") { dock.minimize(draft.id); dock.focusList() }
            headButton("arrow.up.left.and.arrow.down.right", help: "Maximieren") { dock.maximize(draft.id) }
            headButton("macwindow", help: "In eigenem Fenster öffnen") { dock.moveToWindow(draft.id) }
            headButton("xmark", help: "Entwurf schließen (der Entwurf bleibt erhalten)") { model.closeDockedDraft(draft.id) }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(theme.bar.color)
        .contentShape(Rectangle())
        .onTapGesture { dock.minimize(draft.id); dock.focusList() }
    }

    private func headButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Eine minimierte Leiste: 272 × 42 pt (§3.2 Zustand „minimiert").
struct ComposeBarView: View {
    @Bindable var draft: ComposeDraft
    @Environment(\.theme) private var theme
    @State private var hover = false
    private var model: AppModel { AppModel.shared }
    private var dock: ComposeDock { model.compose }

    var body: some View {
        HStack(spacing: 6) {
            if hasUnsavedWork {
                Circle().fill(theme.accent.color).frame(width: 6, height: 6)
            }
            // Titel und Empfänger teilen sich die Breite; ohne feste Grenze
            // wurde aus „An: Kunde 1" ein einzelnes „A" (Sandbox-Lauf).
            // Feste Anteile statt freier Aufteilung: sonst bekam der Betreff
            // weniger Platz als der Empfänger (Sandbox-Lauf).
            Text(draft.panelTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.ink.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(recipientSummary)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(theme.ink3.color)
                .frame(width: 74, alignment: .trailing)
            barButton("chevron.up", help: "Entwurf öffnen") { dock.open(draft.id) }
            barButton("macwindow", help: "In eigenem Fenster öffnen") { dock.moveToWindow(draft.id) }
            barButton("xmark", help: "Entwurf schließen") { model.closeDockedDraft(draft.id) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: ComposeDock.barWidth, height: ComposeDock.barHeight)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(hover ? theme.sel.color : theme.surface.color)
        )
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.12), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { dock.open(draft.id) }
        .help("Entwurf: \(draft.panelTitle), minimiert")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Entwurf: \(draft.panelTitle), minimiert")
        .accessibilityAddTraits(.isButton)
    }

    private var hasUnsavedWork: Bool {
        !draft.savedOnce && (!draft.to.isEmpty || !draft.aiBodyText.isEmpty || !draft.subject.isEmpty)
    }

    private var recipientSummary: String {
        guard let first = draft.to.first else { return "An: —" }
        let name = first.name ?? first.email
        return draft.to.count > 1 ? "An: \(name) +\(draft.to.count - 1)" : "An: \(name)"
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// „+2": die ältesten Leisten, die nicht mehr in die Breite passen (§3.4).
struct ComposeOverflowChip: View {
    let ids: [UUID]
    let hidden: Int
    @Environment(\.theme) private var theme
    private var model: AppModel { AppModel.shared }

    var body: some View {
        Menu {
            ForEach(ids, id: \.self) { id in
                if let draft = model.composeDrafts[id] {
                    Button(draft.panelTitle) { model.compose.open(id) }
                }
            }
        } label: {
            Text("+\(hidden)")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .frame(width: ComposeDock.overflowChipWidth, height: ComposeDock.barHeight)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                        .fill(theme.surface.color)
                )
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                        .strokeBorder(theme.line.color, lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(hidden) weitere Entwürfe")
        .accessibilityLabel("\(hidden) weitere Entwürfe")
    }
}
