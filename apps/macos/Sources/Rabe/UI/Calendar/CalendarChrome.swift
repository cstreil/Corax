import AppKit
import RabeKit
import SwiftUI

/// Small shared pieces of the calendar views: colour handling, time labels, and
/// the one AppKit view that gives the screen its single-key shortcuts (the mail
/// list uses the same trick: plain keys only while the view has the focus).
enum CalendarChrome {
    /// "#RRGGBB" or "#RRGGBBAA" (CalDAV servers send both) → color; anything
    /// else → nil so callers fall back to the theme accent.
    static func hex(_ raw: String?) -> Color? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        let digits = String(text.dropFirst())
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        let rgb = UInt32(digits.prefix(6), radix: 16) ?? 0
        return Color(.sRGB,
                     red: Double((rgb >> 16) & 0xff) / 255,
                     green: Double((rgb >> 8) & 0xff) / 255,
                     blue: Double(rgb & 0xff) / 255,
                     opacity: 1)
    }

    /// One event's colour: its calendar's hex, else the theme accent.
    static func color(for event: CalendarEvent, calendars: [CalendarCollection],
                      theme: Theme) -> Color {
        guard let id = event.calendarId,
              let calendar = calendars.first(where: { $0.id == id }),
              let color = hex(calendar.color) else { return theme.accent.color }
        return color
    }

    /// `HH:mm` in the system time zone (the invite's wall clock).
    static func time(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func timeRange(_ start: Int64, _ end: Int64) -> String {
        "\(time(start)) – \(time(end))"
    }

    static func weekdayShort(_ ms: Int64, single: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        formatter.dateFormat = single ? "EEEE" : "EEE"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func dayNumber(_ ms: Int64) -> Int {
        Calendar.current.component(.day, from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func longDay(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        formatter.dateFormat = "EEEE, d. MMMM yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func shortDay(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Format.locale
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, d. MMM"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

/// First-responder view for the calendar screen: plain keys (`d`, `w`, `m`,
/// `-`, `=`, `t`, `b`, `\`, `1`, `Esc`) reach `onKey` exactly like the mail
/// list's `keyDown`, so typing in a text field never triggers them.
struct CalendarKeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    /// Bumped by the screen to pull the focus back after a sheet closes.
    var focusRequest: Int = 0

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    }

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.onKey = onKey
        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        // AppKit hands the focus back to the responder that had it *before* the
        // sheet, and it does so after the sheet ends: one runloop turn is too
        // early, so `⌫` landed in the mail list and trashed a mail (M2.8b).
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var lastFocusRequest = -1 }
}

/// Keyboard handling of the calendar screen (M2.9 §7.4).
///
/// Die Karte selbst ist in der Anzeige **kein** erster Responder: die Tasten
/// bleiben hier am Raster, nur das Bearbeiten gibt sie an das Titelfeld.
/// `Esc` bei offener Karte läuft über den lokalen Monitor des Bildschirms, weil
/// auch ein Feld in der Karte Esc bekommen kann.
@MainActor
enum CalendarKeyboard {
    /// Zeichen, die der Kalender als Einzeltaste annimmt. Der Test in
    /// `M213Tests` gleicht sie mit `ShortcutMap` (Kontext Kalender) ab, damit
    /// Tabelle und Auswertung nicht auseinanderlaufen.
    static let handledCharacters: Set<String> = [
        "d", "w", "m", "y", "l", "t", "-", "=", "+", "b", "o", "1", "\\"
    ]
    /// Nur über die Taste erreichbar, nicht über das Zeichen.
    static let keyOnlyTokens: Set<String> = ["Tab", "⇧Tab", "Esc", "↵", "⌫", "↑", "↓"]

    static func handle(_ event: NSEvent, store: CalendarStore,
                       openNew: () -> Void,
                       openCard: (CalendarEvent) -> Void = { _ in },
                       editCard: () -> Void = {},
                       saveCard: () -> Void = {},
                       deleteSelected: (CalendarEvent) -> Void = { _ in },
                       joinMeeting: (CalendarEvent) -> Void = { _ in },
                       close: () -> Void) -> Bool {
        /// Ein Klick/eine Bestätigung öffnet die Karte; im Band der Terminliste
        /// und bei offener Anzeige führt sie in die Bearbeitung.
        func openOrEdit(_ event: CalendarEvent) {
            if store.openEventId == event.id, store.cardMode == .view {
                editCard()
            } else {
                openCard(event)
            }
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) || flags.contains(.option) { return false }
        if flags.contains(.command) {
            // `⌘↵` sichert die Karte in der Bearbeitung (sonst ist es der
            // Menüpunkt „Neue E-Mail“ o. ä.).
            if event.keyCode == 36 || event.keyCode == 76 {
                guard store.cardMode == .edit else { return false }
                saveCard()
                return true
            }
            // M2.13: die Apple-Belegung aus `ShortcutMap` (Kontext Kalender).
            // Sie hängt hier und nicht (nur) im Menü, weil der Bildschirm die
            // Tastatur hält (Anforderung 7) — die Kombis gelten aber immer,
            // auch bei offener Karte oder im Textfeld.
            // ⌘1–5: Tag/Woche/Monat/Jahr/Liste.
            if !store.cardIsOpen {
                switch event.keyCode {
                case 18: store.setMode(.day); return true      // ⌘1
                case 19: store.setMode(.week); return true     // ⌘2
                case 20: store.setMode(.month); return true    // ⌘3
                case 21: store.setMode(.year); return true     // ⌘4
                case 23: store.setMode(.list); return true     // ⌘5
                default: break
                }
            }
            // ⌘T heute, ⌘←/⌘→ blättern, ⌘N neuer Termin.
            switch event.keyCode {
            case 17: store.jumpToToday(); return true          // ⌘T
            case 123: store.page(-1); return true              // ⌘←
            case 124: store.page(1); return true               // ⌘→
            case 45: openNew(); return true                    // ⌘N
            case 14:                                            // ⌘E
                if store.cardIsOpen, store.cardMode == .view { editCard(); return true }
                guard let selected = store.openEvent ?? store.selectedEvent else { return true }
                openOrEdit(selected)
                return true
            case 31:                                            // ⌘O
                guard let meeting = store.openEvent ?? store.selectedEvent else { return true }
                joinMeeting(meeting)
                return true
            default: break
            }
            return false
        }
        switch event.keyCode {
        case 53:                                                // Esc
            // Eine offene Karte schließt der Monitor; hier geht es ohne sie
            // zurück zur Liste (wie in Tauri, wo die Schublade zugeht).
            close()
            return true
        case 123, 124:                                          // ← / →
            // M2.13 §8.3: in der Jahresansicht wandert der gewählte Tag; in
            // Tag/Woche/Monat/Liste blättert nur noch `⌘←`/`⌘→`.
            guard store.mode == .year else { return false }
            store.moveSelectedDay(byDays: event.keyCode == 123 ? -1 : 1)
            return true
        case 125, 126:                                          // ↓ / ↑
            // Jahresansicht: eine Woche weiter; sonst der nächste Termin.
            if store.mode == .year {
                store.moveSelectedDay(byDays: event.keyCode == 125 ? 7 : -7)
                return true
            }
            store.selectAdjacent(event.keyCode == 125 ? 1 : -1)
            return true
        case 48:                                                // Tab / ⇧Tab
            // M2.13 §3.8: die Terminwahl liegt auf Tab (und ↑/↓).
            let back = flags.contains(.shift)
            store.selectAdjacent(back ? -1 : 1)
            return true
        case 36, 76:                                            // ↵
            if store.mode == .year {
                // Jahresansicht: der gewählte Tag geht auf (Doppelklick-Pfad).
                let day = store.selectedDayOrToday
                store.go(to: day)
                store.setMode(.day)
                return true
            }
            if store.cardIsOpen, store.cardMode == .view {
                editCard()
                return true
            }
            guard let selected = store.openEvent ?? store.selectedEvent else { return true }
            openOrEdit(selected)
            return true
        case 51, 117:                                           // ⌫
            guard let selected = store.openEvent ?? store.selectedEvent else { return true }
            deleteSelected(selected)
            return true
        default: break
        }
        guard let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else {
            return false
        }
        switch typed {
        case "1": close()
        case "d": store.setMode(.day)
        case "w": store.setMode(.week)
        case "m":
            if store.mode == .year { store.go(to: store.selectedDayOrToday) }
            store.setMode(.month)
        case "y": store.setMode(.year)
        case "l": store.setMode(.list)
        case "t": store.jumpToToday()
        case "-": store.page(-1)
        case "=", "+": store.page(1)
        case "b": openNew()
        case "o":
            guard let event = store.openEvent ?? store.selectedEvent else { return true }
            joinMeeting(event)
        case "\\": store.sidebarVisible.toggle()
        default: return false
        }
        return true
    }
}

// MARK: - Pointer behaviour (M2.8b)

/// Turns the raw clicks of one surface into "open" or "edit".
///
/// The live test found that a plain click on an event did nothing: the grid's
/// `DragGesture` only started after one point of movement, so a click with no
/// movement never ended. The grid now treats a press without movement as a
/// click, and this decides what a click means — a single one opens the detail
/// popover (after the double-click window, otherwise every double click would
/// open it first), a double one opens the editor.
@MainActor
final class CalendarClickRouter {
    private var sequencer = CalendarClickSequencer()
    private var pending: DispatchWorkItem?

    /// A click on `token` (an event id): runs `onOpen` after the double-click
    /// window, or `onEdit` at once when the second click arrives in time.
    func click(_ token: String, onOpen: @escaping () -> Void, onEdit: @escaping () -> Void) {
        switch sequencer.register(at: ProcessInfo.processInfo.systemUptime, token: token) {
        case .double:
            pending?.cancel()
            pending = nil
            onEdit()
        case .single:
            pending?.cancel()
            let work = DispatchWorkItem(block: onOpen)
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + sequencer.interval, execute: work)
        }
    }

    /// Drops a click the surface still owes (the popover closed, the view went
    /// away): nothing should open afterwards.
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// The right-click menu of one event (M2.8b). Tauri has no context menu on the
/// calendar, so this is ours: the same verbs as the keys, no "Duplizieren" (the
/// core has no such command).
struct EventContextMenu: View {
    let store: CalendarStore
    let event: CalendarEvent
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("Öffnen", action: onOpen)
        if store.canEdit(event) {
            Button("Bearbeiten …", action: onEdit)
        }
        Divider()
        Button(store.canEdit(event) && !event.attendees.isEmpty ? "Absagen …" : "Löschen …",
               role: .destructive, action: onDelete)
    }
}
