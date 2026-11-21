import RabeKit
import SwiftUI

/// M2.9: die Seitenleiste des Hauptfensters (`ENTWURF-M2.9.md` §1, Mockup 1).
///
/// Sie ist der Ort für das *Wohin*: Konto, Mail/Kalender, Ansichten, Labels und
/// Ordner. Im Kalender zeigt dieselbe Spalte das Minimonat und die Kalenderliste
/// — die eigene Kalender-Seitenleiste entfällt.
///
/// Oben läuft ein 52-pt-Band mit: dort sitzen die Fensterampeln (AppKit malt sie
/// über die Spalte) und rechts der Knopf zum Ausblenden.
struct SidebarColumn: View {
    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }
    @Environment(\.theme) private var theme
    @State private var labelsOpen = true
    /// M2.18k: der Aufklappzustand der Gruppe bleibt erhalten (eigener Schlüssel
    /// für die Sandbox, wie bei `sidebarVisible`).
    @AppStorage(Instance.isSandbox ? "foldersOpen.sandbox" : "foldersOpen")
    private var foldersOpen = true
    @State private var expandedFolders: Set<String> = []
    @State private var disclosureLoaded = false
    @State private var accountOpen = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    accountMenu
                    modeSwitch
                    if model.calendarOpen {
                        CalendarSidebarContent(store: model.calendar, accounts: box.accounts)
                    } else {
                        viewsSection
                        labelsSection
                        foldersSection
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            Divider().overlay(theme.line.color)
            footer
        }
        .frame(width: SidebarState.width)
        .background(sideBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.line.color).frame(width: 0.5)
        }
        // M2.15 1.3: die eigenen Ordner kamen nie an, weil `loadFolders` lief,
        // bevor die Konten geladen waren (`folders_loaded n=0 accounts=0`) und
        // sich der Schlüssel danach nicht mehr änderte. Die Kontenliste gehört
        // deshalb in den Schlüssel; sobald sie da ist, lädt die Zeile erneut.
        .task(id: "\(box.accountId ?? -1)|\(box.accounts.map(\.id))") { await box.loadFolders() }
    }

    /// Glas zeigt das Fenstermaterial, Papier und Graphit ihre eigene Fläche.
    @ViewBuilder private var sideBackground: some View {
        if theme.usesGlass {
            ZStack {
                VisualEffect(material: .sidebar, blending: .behindWindow)
                theme.side.color
            }
        } else {
            theme.side.color
        }
    }

    // MARK: Konto

    /// Kontowahl als Knopf mit Popover: ein `Menu`-Label mit eigenem Rahmen
    /// kollabiert in SwiftUI auf die Größe des Indikators (im Sandbox-Lauf blieb
    /// nur der Chevron übrig, AX 29 × 15 pt). Ein `Button` behält seinen Rahmen.
    private var accountMenu: some View {
        Button { accountOpen.toggle() } label: {
            HStack(spacing: 8) {
                Text(avatarLetters)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.accentInk.color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.accent.color))
                VStack(alignment: .leading, spacing: 0) {
                    Text(accountTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(accountHint)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(accountOpen ? theme.sel.color : theme.hover.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Konto wechseln")
        .accessibilityLabel("Konto: \(accountTitle)")
        .accessibilityValue(accountOpen ? "offen" : "zu")
        .popover(isPresented: $accountOpen, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 1) {
                accountRow(nil, title: "Alle Konten", hint: nil)
                if !box.accounts.isEmpty { Divider().padding(.vertical, 3) }
                ForEach(Array(box.accounts.enumerated()), id: \.element.id) { i, account in
                    accountRow(account.id, title: account.label, hint: i < 9 ? "⌃\(i + 1)" : nil)
                }
                Divider().padding(.vertical, 3)
                Button {
                    accountOpen = false
                    ActionDispatcher.perform(.addAccount)
                } label: {
                    Text("Konto hinzufügen …")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink.color)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .frame(width: 230)
            .environment(\.theme, theme)
        }
    }

    private func accountRow(_ id: Int64?, title: String, hint: String?) -> some View {
        let active = box.accountId == id
        return Button {
            accountOpen = false
            ActionDispatcher.perform(.account(id))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: active ? "checkmark" : " ")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let hint {
                    Text(hint).font(.system(size: 10)).foregroundStyle(theme.ink3.color)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(active ? theme.sel.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accountTitle: String {
        guard let id = box.accountId, let account = box.accounts.first(where: { $0.id == id }) else {
            return box.accounts.count > 1 ? "Alle Konten" : (box.accounts.first?.label ?? "Kein Konto")
        }
        return account.label
    }

    private var accountHint: String {
        guard box.accounts.count > 1 else { return Instance.isSandbox ? "Sandbox" : "Postfach" }
        return box.accountId == nil ? "Alle Konten · ⌃1–\(min(box.accounts.count, 9))" : "Konto wechseln · ⌃1–\(min(box.accounts.count, 9))"
    }

    private var avatarLetters: String {
        let source = accountTitle
        let letters = source.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "R" : String(letters).uppercased()
    }

    // MARK: Mail | Kalender

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            modeButton("Mail", symbol: "envelope", active: !model.calendarOpen) {
                if model.calendarOpen { ActionDispatcher.perform(.calendarClose) }
            }
            modeButton("Kalender", symbol: "calendar", active: model.calendarOpen) {
                if !model.calendarOpen { ActionDispatcher.perform(.calendarToggle) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.hover.color))
    }

    private func modeButton(_ title: String, symbol: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? theme.ink.color : theme.ink2.color)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.surface.color)
                        .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.08), radius: 1.5, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(title == "Mail" ? "1" : "2"))")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: Ansichten

    private var viewsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(MailView.allCases) { view in
                viewRow(view)
            }
        }
    }

    private func viewRow(_ view: MailView) -> some View {
        let selected = box.view == view && !model.calendarOpen && box.searchQuery == nil
        let badge = box.badge(for: view)
        return Button {
            ActionDispatcher.perform(.view(view))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: SidebarColumn.symbol(for: view))
                    .font(.system(size: 12.5))
                    .frame(width: 18)
                    .foregroundStyle(selected ? theme.accent.color : theme.ink2.color)
                Text(Strings.view(view))
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                // M2.18n: Zähler **und** Folge. Vorher ersetzte der Zähler den
                // Hinweis (`else if`), und ohne `fixedSize` wurde „G I“ bei
                // schmaler Leiste zu „G“ zusammengedrückt. Der Name kürzt
                // zuerst, die Folge nie.
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? theme.accent.color : theme.ink3.color)
                        .fixedSize()
                }
                if let hint = Self.goHint(for: view) {
                    Text(hint)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.ink3.color.opacity(0.75))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.sel.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(Strings.view(view)), \(badge)" : Strings.view(view))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func symbol(for view: MailView) -> String {
        switch view {
        case .inbox: "tray"
        case .starred: "star"
        case .snoozed: "clock"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .done: "checkmark.circle"
        case .trash: "trash"
        case .spam: "xmark.octagon"
        case .all: "tray.2"
        }
    }

    /// Die Folge der Zeile („G I“), aus derselben Tabelle wie Auswertung und
    /// Statuszeile (`GoSequence`) — so kann sie nicht mehr auseinanderlaufen.
    static func goHint(for view: MailView) -> String? {
        guard let target = GoSequence.targets.first(where: { $0.view == view }) else { return nil }
        return "G " + target.key.uppercased()
    }

    // MARK: Labels

    /// M2.18n: eigene Labels zuerst, automatische Kategorien danach — dieselbe
    /// Reihenfolge wie in Liste und Mail (`MailLabelDisplay`).
    private var labels: [RabeKit.Label] {
        MailLabelDisplay.sorted(Array(box.labels.values))
    }

    @ViewBuilder private var labelsSection: some View {
        if !labels.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                sectionHeader("Labels", open: $labelsOpen)
                if labelsOpen {
                    ForEach(labels) { label in
                        let selected = box.filterLabelId == label.id
                        Button {
                            box.selectLabel(label.id)
                            box.focusList()
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(CalendarChrome.hex(label.color) ?? theme.accent.color)
                                    .frame(width: 7, height: 7)
                                    .frame(width: 18)
                                Text(label.name)
                                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                                    .foregroundStyle(theme.ink.color)
                                    .lineLimit(1)
                                // M2.18n: automatische Kategorien mit Funkeln.
                                if label.isAuto == true {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(theme.ink3.color)
                                }
                                Spacer(minLength: 0)
                                let badge = box.labelBadge(label.id)
                                if badge > 0 {
                                    Text("\(badge)")
                                        .font(.system(size: 10.5))
                                        .monospacedDigit()
                                        .foregroundStyle(theme.ink3.color)
                                }
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.sel.color : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label.isAuto == true
                                            ? "Automatische Kategorie \(label.name)"
                                            : "Label \(label.name)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    // MARK: Ordner

    @ViewBuilder private var foldersSection: some View {
        let rows = Pickers.folderTree(box.folders)
        let visible = FolderDisclosure.visible(rows, open: expandedFolders)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                sectionHeader("Ordner", open: $foldersOpen)
                if foldersOpen {
                    ForEach(visible) { row in
                        folderRow(row, selected: box.filterFolderId == row.folder.id)
                    }
                }
            }
            // M2.18k: der letzte Aufklappzustand wird beim Start wiederhergestellt.
            // Beim ersten Mal stehen die vorhandenen Ordner offen (sonst sähe der
            // Baum nach dem Umbau nur noch die Wurzelordner); später neue Ordner
            // sind eingeklappt.
            .task(id: rows.count) {
                guard !disclosureLoaded else { return }
                expandedFolders = FolderDisclosure.loadOrSeed(rows: rows)
                disclosureLoaded = true
            }
        }
    }

    /// Eine Zeile des Ordnerbaums: Aufklapp-Dreieck (nur bei Ordnern mit
    /// Kindern), Symbol und Name. Ein Zwischenknoten ohne echten Ordner
    /// (Elternordner fehlt in der Serverliste) ist nicht wählbar.
    @ViewBuilder
    private func folderRow(_ row: FolderRow, selected: Bool) -> some View {
        let open = FolderDisclosure.isOpen(accountId: row.folder.accountId, path: row.path,
                                           open: expandedFolders)
        HStack(spacing: 4) {
            if row.hasChildren {
                Button { toggleFolder(row) } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.ink3.color)
                        .frame(width: 12, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.name) \(open ? "zuklappen" : "aufklappen")")
            } else {
                Color.clear.frame(width: 12, height: 26)
            }
            if row.isSelectable {
                Button { box.selectFolder(row.folder); box.focusList() } label: {
                    folderLabel(row, selected: selected)
                }
                .buttonStyle(.plain)
                .help(row.folder.imapName)
                .accessibilityLabel("Ordner \(row.name)")
            } else {
                folderLabel(row, selected: false)
                    .help("Elternordner von „\(row.name)“ fehlt in der Serverliste")
            }
        }
        .padding(.leading, 7 + CGFloat(row.depth) * 12)
        .padding(.trailing, 7)
    }

    private func folderLabel(_ row: FolderRow, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11.5))
                .frame(width: 18)
                .foregroundStyle(theme.ink3.color)
            Text(row.name)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(row.isSelectable
                                 ? (selected ? theme.ink.color : theme.ink2.color)
                                 : theme.ink3.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
    }

    private func toggleFolder(_ row: FolderRow) {
        expandedFolders = FolderDisclosure.toggle(accountId: row.folder.accountId,
                                                  path: row.path, in: expandedFolders)
        FolderDisclosure.save(expandedFolders)
    }

    private func sectionHeader(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.ink3.color)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.ink3.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.top, 4)
            .padding(.bottom, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(open.wrappedValue ? "offen" : "geschlossen")
    }

    // MARK: Fußzeile

    private var footer: some View {
        Button {
            SettingsNavigation.request(.appearance)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .frame(width: 18)
                    .foregroundStyle(theme.ink2.color)
                Text("Einstellungen")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.ink.color)
                Spacer(minLength: 0)
                Text("⌘,")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.ink3.color.opacity(0.75))
            }
            .padding(.horizontal, 17)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Einstellungen (⌘,)")
        .accessibilityLabel("Einstellungen")
    }
}
