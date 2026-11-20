import Foundation
import Observation

/// M2.9: die Seitenleiste des Hauptfensters — Sichtbarkeit, Breite und die
/// Auto-Regel aus dem Entwurf (§1.3).
///
/// Die Leiste ist 232 pt breit. Bleibt neben ihr weniger als 640 pt Inhalt
/// (Fenster schmaler als 872 pt), klappt sie von selbst ein. Gespeichert wird
/// nur der Wunsch des Nutzers; wer sie bei schmalem Fenster ausdrücklich
/// einblendet, bekommt sie für diese Sitzung auch dort.
@MainActor
@Observable
public final class SidebarState {
    public static let width: CGFloat = 232
    /// Content width the window should keep beside the sidebar.
    public static let minimumContentWidth: CGFloat = 640
    /// Window width below which the sidebar hides by itself.
    public static var autoHideWidth: CGFloat { width + minimumContentWidth }

    /// Persisted choice (`UserDefaults["sidebarVisible"]`).
    public private(set) var userWantsVisible: Bool
    /// Set by the shell as the window resizes.
    public private(set) var windowWidth: CGFloat
    /// The user asked for the sidebar despite a narrow window (this session).
    public private(set) var forcedVisible = false

    private let defaults: UserDefaults
    private let key: String

    /// `key` separates the sandbox from the real instance: both share one
    /// UserDefaults domain (the bundle id), and a walkthrough must not change
    /// how the user's own app starts.
    public init(defaults: UserDefaults = .standard, key: String = "sidebarVisible") {
        self.defaults = defaults
        self.key = key
        let stored = defaults.object(forKey: key) as? Bool
        userWantsVisible = stored ?? true
        windowWidth = 1200
    }

    /// The rule on its own, so it can be tested without a window.
    /// A narrow window only hides the sidebar while the user has not asked for
    /// it explicitly.
    public static func visible(userWants: Bool, forced: Bool, windowWidth: CGFloat) -> Bool {
        guard userWants else { return false }
        return windowWidth >= autoHideWidth || forced
    }

    public var isVisible: Bool {
        Self.visible(userWants: userWantsVisible, forced: forcedVisible, windowWidth: windowWidth)
    }

    /// True when the width rule is what hides it (the toggle then forces it).
    public var isHiddenByWidth: Bool {
        userWantsVisible && !forcedVisible && windowWidth < Self.autoHideWidth
    }

    public func update(windowWidth: CGFloat) {
        guard abs(windowWidth - self.windowWidth) >= 0.5 else { return }
        let before = isVisible
        self.windowWidth = windowWidth
        if before != isVisible {
            PerfLog.shared.write("sidebar_auto visible=\(isVisible ? 1 : 0) width=\(Int(windowWidth))"
                                 + " auto=\(isHiddenByWidth ? 1 : 0)")
        }
    }

    /// `\`, `⌃⌘S`, the button in the sidebar band and the menu item.
    /// Turning it on under the auto-hide width counts as an explicit wish.
    public func toggle() {
        if isVisible {
            userWantsVisible = false
            forcedVisible = false
        } else {
            userWantsVisible = true
            forcedVisible = windowWidth < Self.autoHideWidth
        }
        defaults.set(userWantsVisible, forKey: key)
        PerfLog.shared.write("sidebar_toggle visible=\(isVisible ? 1 : 0) width=\(Int(windowWidth))"
                             + " wants=\(userWantsVisible ? 1 : 0) forced=\(forcedVisible ? 1 : 0)")
    }
}
