import Foundation
import Observation

/// Wie ein Entwurf gerade gezeigt wird (Entwurf M2.9 §3.3).
public enum ComposePresentation: Equatable {
    /// Unter dem Thread in der Liste, wie seit M1.
    case inline
    /// Eigenes Fenster (früher der einzige Ort für `C`).
    case window
    /// Angedocktes Panel unten rechts.
    case docked
}

/// M2.9 Stufe B: das angedockte Verfassen-Panel — Reihenfolge, Zustand und
/// Fokus der offenen Entwürfe.
///
/// Der Entwurf selbst liegt in `ComposeStore.swift`; hier steht nur, *wie* er
/// gezeigt wird. Ein Dictionary in der App hatte dafür keine Reihenfolge, die
/// Leisten wären beim Umschalten gesprungen.
///
/// Regeln aus dem Entwurf §3.4:
/// - Höchstens `maxDrafts` Entwürfe, davon höchstens einer offen.
/// - Öffnet man eine Leiste, wird der bisher offene Entwurf zur Leiste.
/// - Der offene Entwurf steht ganz rechts, der zuletzt minimierte links daneben.
@MainActor
@Observable
public final class ComposeDock {
    /// Wie ein Entwurf im Dock hängt. `.window` ist ein eigener Fensterplatz,
    /// kein Platz im Dock (zählt nicht gegen die Obergrenze).
    public enum State: String, Equatable {
        case open, minimized, maximized, window
    }

    public static let maxDrafts = 4

    // MARK: Geometrie (Entwurf §3.1)
    public static let panelWidth: CGFloat = 540
    public static let panelHeight: CGFloat = 560
    public static let minimumWidth: CGFloat = 420
    public static let minimumHeight: CGFloat = 300
    public static let barWidth: CGFloat = 272
    public static let barHeight: CGFloat = 42
    public static let barGap: CGFloat = 10
    /// Platz rechts und unten zur Fensterkante; unten die Höhe der Hinweisleiste.
    public static let trailingInset: CGFloat = 16
    public static let hintBarHeight: CGFloat = 34
    /// Breite des Chips „+n", wenn die Leisten nicht passen.
    public static let overflowChipWidth: CGFloat = 46

    /// Die Entwürfe in Dock-Reihenfolge, links nach rechts; der offene am Ende.
    public private(set) var order: [UUID] = []
    public private(set) var states: [UUID: State] = [:]
    /// Zähler für „zuletzt minimiert": bestimmt nur die Sichtreihenfolge der
    /// Leisten, nicht den Fokus-Ring.
    private var minimizeCounter = 0
    public private(set) var minimizedAt: [UUID: Int] = [:]
    /// `nil` = die Liste hat die Tastatur (§3.6).
    public private(set) var keyboardFocus: UUID?
    /// Der Inline-Entwurf unter dem Thread, falls die Tastatur dort steht.
    /// Menükürzel wie `⌘⇧A` müssen den richtigen Entwurf treffen, und im
    /// Hauptfenster können Panel und Inline-Entwurf gleichzeitig offen sein.
    public private(set) var inlineFocus: UUID?
    /// Bumped when the keyboard should move into a draft's editor.
    public private(set) var focusRequest = 0

    // MARK: Rückrufe in die App
    /// Nach dem Öffnen eines Fenster-Entwurfs (`openWindow`).
    public var onOpenWindow: ((UUID) -> Void)?
    /// Nach Senden, Minimieren, Schließen und Verwerfen (§3.6.3).
    public var onFocusList: (() -> Void)?

    public init() {}

    // MARK: Abfragen

    public var count: Int { order.count }
    /// Entwürfe, die einen Dock-Platz belegen (Fenster nicht mitgezählt).
    public var dockedCount: Int { order.filter { states[$0] != .window }.count }
    public var isFull: Bool { dockedCount >= Self.maxDrafts }
    public var isEmpty: Bool { order.isEmpty }

    public func state(_ id: UUID) -> State? { states[id] }

    /// Der Entwurf, der als Panel offen ist (offen oder maximiert).
    public var openId: UUID? { order.last { states[$0] == .open || states[$0] == .maximized } }

    /// Ist das Panel gerade maximiert?
    public var isMaximized: Bool { openId.map { states[$0] == .maximized } ?? false }

    /// Die Leisten in Anzeigereihenfolge (links nach rechts): zuerst die am
    /// längsten minimierten, der zuletzt minimierte sitzt direkt neben dem
    /// offenen Panel (§3.4).
    public var barIds: [UUID] {
        order.filter { states[$0] == .minimized }
            .sorted { (minimizedAt[$0] ?? 0) < (minimizedAt[$1] ?? 0) }
    }

    public var windowIds: [UUID] { order.filter { states[$0] == .window } }

    /// Hat ein Entwurf die Tastatur? Dann lösen die Listenkürzel nichts aus.
    public var hasDraftFocus: Bool { keyboardFocus != nil }

    /// §3.6.3: nach diesen Aktionen geht die Tastatur zurück an die Liste.
    public func focusList() {
        keyboardFocus = nil
        inlineFocus = nil
        onFocusList?()
    }

    public func takeInlineFocus(_ id: UUID) {
        inlineFocus = id
        keyboardFocus = nil
    }

    public func releaseInlineFocus(_ id: UUID) {
        if inlineFocus == id { inlineFocus = nil }
    }

    /// Welcher Entwurf ein Menükürzel bekommt: der Inline-Entwurf, sonst das
    /// fokussierte bzw. offene Panel.
    public var commandTarget: UUID? { inlineFocus ?? keyboardFocus ?? openId }

    /// Ein Entwurf nimmt die Tastatur (Klick ins Panel, `C`, `⌃Tab`).
    public func takeFocus(_ id: UUID) {
        guard states[id] != nil else { return }
        keyboardFocus = id
        PerfLog.shared.write("compose_focus id=\(id.uuidString.prefix(8)) target=draft")
    }

    /// Die Liste hat die Tastatur wieder (erst wenn sie wirklich klickt/tippt).
    public func takeListFocus() {
        guard keyboardFocus != nil || inlineFocus != nil else { return }
        keyboardFocus = nil
        inlineFocus = nil
        PerfLog.shared.write("compose_focus target=list")
    }

    // MARK: Zustandswechsel

    /// Ein neuer Entwurf hängt sich ans Dock. `false`, wenn es voll ist — dann
    /// legt der Aufrufer nichts an (§3.4).
    @discardableResult
    public func add(_ id: UUID, as state: State = .open) -> Bool {
        if states[id] != nil { return true }
        if state != .window, isFull { return false }
        if state == .open || state == .maximized { minimizeOpen(except: id) }
        order.append(id)
        states[id] = state
        if state == .minimized { stamp(id) }
        if state != .window, state != .minimized { takeFocusOnce(id) }
        PerfLog.shared.write("compose_dock_add slot=\(state.rawValue) n=\(dockedCount)")
        return true
    }

    /// Eine Leiste öffnen: der bisher offene Entwurf wird zur Leiste.
    public func open(_ id: UUID) {
        guard states[id] == .minimized else { return }
        minimizeOpen(except: id)     // der bisher offene wird Leiste
        states[id] = .open
        takeFocusOnce(id)
        PerfLog.shared.write("compose_dock_open n=\(dockedCount)")
    }

    public func minimize(_ id: UUID) {
        guard let state = states[id], state != .window else { return }
        states[id] = .minimized
        stamp(id)
        if keyboardFocus == id { keyboardFocus = nil }
        PerfLog.shared.write("compose_dock_minimize")
    }

    public func maximize(_ id: UUID) {
        guard states[id] == .open else { return }
        states[id] = .maximized
        PerfLog.shared.write("compose_dock_maximize")
    }

    public func unmaximize(_ id: UUID) {
        guard states[id] == .maximized else { return }
        states[id] = .open
        PerfLog.shared.write("compose_dock_unmaximize")
    }

    /// „In eigenem Fenster": der Entwurf verlässt das Dock und öffnet sein
    /// Fenster. Derselbe Entwurf ist nie an beiden Orten (§5).
    public func moveToWindow(_ id: UUID) {
        guard let state = states[id], state != .window else { return }
        minimizeOpen(except: id)
        states[id] = .window
        if keyboardFocus == id { keyboardFocus = nil }
        PerfLog.shared.write("compose_dock_window n=\(dockedCount)")
        onOpenWindow?(id)
    }

    /// „Im Hauptfenster andocken" aus dem Fenster, oder einen Entwurf beim
    /// Schließen des Fensters als Leiste behalten.
    public func dock(_ id: UUID, as state: State = .open) {
        guard states[id] == .window else { return }
        if isFull {
            PerfLog.shared.write("compose_dock_refused full=1")
            return
        }
        if state == .open || state == .maximized { minimizeOpen(except: id) }
        states[id] = state
        if state == .minimized { stamp(id) }
        if state == .open || state == .maximized { takeFocusOnce(id) }
        PerfLog.shared.write("compose_dock_dock n=\(dockedCount) slot=\(state.rawValue)")
    }

    /// Senden, Verwerfen oder Schließen: der Platz wird frei.
    public func remove(_ id: UUID) {
        order.removeAll { $0 == id }
        states[id] = nil
        if keyboardFocus == id { keyboardFocus = nil }
        PerfLog.shared.write("compose_dock_remove n=\(dockedCount)")
    }

    /// `⌘⇧M`: den offenen Entwurf minimieren bzw. den letzten öffnen.
    public func toggleMinimize() {
        if let openId {
            minimize(openId)
            PerfLog.shared.write("compose_dock_toggle action=minimize")
            focusList()
            return
        }
        guard let last = barIds.last else { return }
        open(last)
        PerfLog.shared.write("compose_dock_toggle action=open")
    }

    /// `⌃Tab` / `⌃⇧Tab`: die Liste und die Entwürfe reihum (§3.5).
    ///
    /// Der Ring ist die Anlagereihenfolge der Entwürfe, die Liste steht hinten
    /// dran: Entwurf 1 → … → Entwurf n → Liste → Entwurf 1. Die
    /// Sichtreihenfolge taugt dafür nicht — das Öffnen einer Leiste ändert sie,
    /// und der Ring würde Entwürfe überspringen.
    /// Gibt den Entwurf zurück, der die Tastatur bekommt; `nil` = die Liste.
    @discardableResult
    public func cycleFocus(backward: Bool = false) -> UUID? {
        let ring = order.filter { states[$0] != .window }
        guard !ring.isEmpty else {
            keyboardFocus = nil
            PerfLog.shared.write("compose_cycle target=list empty=1")
            return nil
        }
        let count = ring.count + 1                       // + die Liste
        let step = backward ? -1 : 1
        let current: Int
        if keyboardFocus == nil {
            current = ring.count                          // die Liste
        } else if let focus = keyboardFocus, let index = ring.firstIndex(of: focus) {
            current = index
        } else {
            current = ring.count
        }
        let next = ((current + step) % count + count) % count
        guard next < ring.count else {
            keyboardFocus = nil
            PerfLog.shared.write("compose_cycle target=list")
            return nil
        }
        let id = ring[next]
        if states[id] == .minimized { open(id) }
        keyboardFocus = id
        focusRequest += 1
        PerfLog.shared.write("compose_cycle target=draft n=\(ring.count)")
        return id
    }

    /// Esc im Panel: maximiert → offen, offen → minimiert (§3.3).
    public func escapeOpenPanel() {
        guard let id = openId else { return }
        if states[id] == .maximized {
            states[id] = .open
            PerfLog.shared.write("compose_escape action=unmaximize")
        } else {
            minimize(id)
            PerfLog.shared.write("compose_escape action=minimize")
            focusList()
        }
    }

    /// Nur einer ist offen: alles andere wird zur Leiste.
    private func minimizeOpen(except id: UUID) {
        for other in order where other != id {
            switch states[other] {
            case .open, .maximized:
                states[other] = .minimized
                stamp(other)
            default: break
            }
        }
    }

    private func stamp(_ id: UUID) {
        minimizeCounter += 1
        minimizedAt[id] = minimizeCounter
    }

    private func takeFocusOnce(_ id: UUID) {
        keyboardFocus = id
        focusRequest += 1
    }

    // MARK: Geometrie (Entwurf §3.1, §3.4)

    /// Breite des Panels: `min(540, Inhalt − 32)`, mindestens 420.
    public static func panelWidth(contentWidth: CGFloat) -> CGFloat {
        max(minimumWidth, min(panelWidth, contentWidth - 32))
    }

    /// Höhe: `min(560, Inhalt − 24)`, mindestens 300.
    public static func panelHeight(contentHeight: CGFloat) -> CGFloat {
        max(minimumHeight, min(panelHeight, contentHeight - 24))
    }

    /// Wie viele Leisten passen, wenn `available` pt zur Verfügung stehen; der
    /// Rest landet im Chip „+n" (§3.4).
    public static func barOverflow(count: Int, available: CGFloat) -> (shown: Int, hidden: Int) {
        guard count > 0, available > 0 else { return (0, count) }
        var shown = 0
        var used: CGFloat = 0
        while shown < count {
            let needed = shown == 0 ? barWidth : barWidth + barGap
            // Eine Leiste mehr braucht auch den Chip für die übrigen.
            let chip = shown + 1 < count ? overflowChipWidth + barGap : 0
            if used + needed + chip > available { break }
            used += needed
            shown += 1
        }
        return (shown, count - shown)
    }
}
