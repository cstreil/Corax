import RabeKit
import SwiftUI

/// Full calendar screen (Tauri `CalendarScreen`): header with navigation and the
/// day/week/month switch, the sidebar (`\`), and the grid or month layout.
/// Reached with `2` or `m` from the mail list, `1`/`Esc` goes back.
struct CalendarScreenView: View {
    /// Height of the window's toolbar/titlebar band (see `WindowConfigurator`).
    private static let titlebarBand: CGFloat = 52

    private var model: AppModel { AppModel.shared }
    private var store: CalendarStore { model.calendar }
    @Environment(\.theme) private var theme
    @State private var editor: EventEditorRequest?
    @State private var detail: CalendarEvent?
    @State private var focusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    CalendarSidebarView(store: store, accounts: model.mailbox.accounts)
                }
                content
            }
            hintBar
        }
        // The window keeps 52 pt for its unified toolbar row (where the mail
        // list draws its toolbar and the traffic lights live). The calendar
        // starts below that band — content drawn under it is not visible.
        .padding(.top, Self.titlebarBand)
        .background(theme.win.color)
        .background(
            CalendarKeyCatcher(onKey: { event in
                CalendarKeyboard.handle(event, store: store, openEditor: { openEditor() },
                                        close: { model.calendarOpen = false; model.mailbox.focusList() })
            }, focusRequest: focusRequest)
        )
        .task {
            store.settings = model.settings
            await store.loadCalendars()
            if !store.loaded { await store.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rabeCalendarNewEvent)) { _ in
            openEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .rabeCalendarPrefill)) { note in
            let info = note.userInfo ?? [:]
            let startsAt = (info["startsAt"] as? NSNumber)?.int64Value
                ?? Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
            let endsAt = (info["endsAt"] as? NSNumber)?.int64Value ?? startsAt + 3_600_000
            let location = info["location"] as? String ?? ""
            editor = EventEditorRequest(
                startsAt: startsAt, endsAt: endsAt,
                allDay: info["allDay"] as? Bool ?? false,
                title: info["summary"] as? String,
                location: location.isEmpty ? nil : location)
        }
        .sheet(item: $editor, onDismiss: { focusRequest += 1 }) { request in
            CalendarEventEditorView(store: store, accounts: model.mailbox.accounts, request: request) {
                editor = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                store.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12))
                    .foregroundStyle(store.sidebarVisible ? theme.ink.color : theme.ink3.color)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Seitenleiste ein/aus (\\)")

            Button("Heute") { store.jumpToToday() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color, lineWidth: 0.6))
                .help("Heute (T)")

            HStack(spacing: 2) {
                chevron("chevron.left", help: "Zurück (-)") { store.page(-1) }
                chevron("chevron.right", help: "Weiter (=)") { store.page(1) }
            }

            Text(store.heading())
                .font(.system(size: 16.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)

            Spacer(minLength: 8)

            Picker("Ansicht", selection: Binding(
                get: { store.mode },
                set: { store.setMode($0) }
            )) {
                ForEach(CalendarStore.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .help("Tag (D), Woche (W), Monat (M)")

            Button {
                openEditor()
            } label: {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func chevron(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.loaded && store.loading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Termine werden geladen …")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3.color)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Group {
                if store.mode == .month {
                    CalendarMonthView(store: store, editor: $editor, detail: $detail)
                } else {
                    CalendarTimeGridView(store: store, editor: $editor, detail: $detail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hintBar: some View {
        HStack(spacing: 14) {
            hint("D / W / M", "Ansicht")
            hint("- / =", "blättern")
            hint("T", "heute")
            hint("B", "neu")
            hint("\\", "Seitenleiste")
            hint("1 / Esc", "zurück")
            Spacer()
            if store.meetingReminderMinutes > 0 {
                Text("Erinnerung \(store.meetingReminderMinutes) min vorher")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.ink3.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(theme.win.color)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line.color).frame(height: 0.5)
        }
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(keys)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.ink2.color)
        }
    }

    private func openEditor() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let base = store.math.startOfDay(store.anchor)
        let start: Int64
        if store.math.isSameDay(base, now) {
            start = store.math.at(base, hour: store.math.hour(now), minute: 0) + 3_600_000
        } else {
            start = store.math.at(base, hour: 9)
        }
        editor = EventEditorRequest(startsAt: start, endsAt: start + 30 * 60_000)
    }
}
