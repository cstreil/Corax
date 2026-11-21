import RabeKit
import SwiftUI

/// M2.18m: „Gehe zu Ordner/Label …“ (`G` `O`, `⇧⌘O`) — eine Liste mit Suchfeld
/// über alle eigenen Ordner und Labels aller Konten. Die Wahl setzt denselben
/// Filter wie ein Klick in der Seitenleiste; die Einträge sind dieselben, die
/// auch in der Befehlspalette (`⌘K`) stehen.
struct GoToPicker: View {
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var model: AppModel { AppModel.shared }
    private var box: MailboxStore { model.mailbox }

    private var entries: [GoToEntry] {
        GoToEntries.make(folders: box.folders,
                         labels: Array(box.labels.values),
                         accounts: Dictionary(uniqueKeysWithValues: box.accounts.map { ($0.id, $0.label) }),
                         showsAccount: box.accounts.count > 1)
    }

    private var matches: [GoToEntry] { GoToEntries.matches(entries, query: query) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(theme.ink3.color)
                    TextField("Ordner oder Label …", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .focusWhenShown($focused)
                        .onSubmit { run() }
                        .onKeyPress(.downArrow) {
                            index = GoToEntries.stepped(index, by: 1, count: matches.count)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            index = GoToEntries.stepped(index, by: -1, count: matches.count)
                            return .handled
                        }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: query) { _, _ in index = 0 }
                        .accessibilityLabel("Gehe zu Ordner oder Label")
                }
                .padding(14)
                Divider().overlay(theme.line.color)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if matches.isEmpty {
                                Text("Kein Ordner, kein Label gefunden")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.ink3.color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                            }
                            ForEach(Array(matches.enumerated()), id: \.element.id) { i, entry in
                                Button { index = i; run() } label: {
                                    row(entry, selected: i == index)
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                                .accessibilityLabel(entry.detail == nil
                                                    ? entry.title
                                                    : "\(entry.title), \(entry.detail ?? "")")
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: index) { _, i in
                        guard matches.indices.contains(i) else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(matches[i].id) }
                    }
                }
            }
            .foregroundStyle(theme.ink.color)
            .frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.line.color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
            .padding(.top, 90)
        }
        .onAppear {
            focused = true
            PerfLog.shared.write("go_to_picker open entries=\(entries.count)")
        }
    }

    private func row(_ entry: GoToEntry, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: entry.kind == .folder ? "folder" : "tag")
                .font(.system(size: 11.5))
                .frame(width: 18)
                .foregroundStyle(entry.kind == .label ? color(entry) : theme.ink3.color)
            Text(entry.title)
                .lineLimit(1)
            if let detail = entry.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if selected {
                Text("↵").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.sel.color : .clear))
        .contentShape(Rectangle())
    }

    private func color(_ entry: GoToEntry) -> Color {
        guard entry.kind == .label, let label = box.labels[entry.targetId] else {
            return theme.accent.color
        }
        return CalendarChrome.hex(label.color) ?? theme.accent.color
    }

    private func run() {
        guard matches.indices.contains(index) else { close(); return }
        let entry = matches[index]
        close()
        ActionDispatcher.perform(entry.kind == .folder
                                 ? .goToFolder(entry.targetId)
                                 : .goToLabel(entry.targetId))
    }

    private func close() {
        model.goToOpen = false
        box.focusList()
    }
}
