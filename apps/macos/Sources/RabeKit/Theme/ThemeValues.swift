import Foundation
import RabeBindings

/// Design tokens from the mockup's `<style>` (`body[data-theme=…]`), as plain
/// data: no AppKit, no SwiftUI. The app turns `RGBA` into `NSColor`/`Color`
/// (`UI/Theme/Theme.swift` keeps those conversions), so themes can be resolved
/// and tested without a UI toolkit.
///
/// Settings IDs. `carbon` and `snow` are existing IDs (Graphit and Glas) and
/// stay as they are; `paper` is new.
public enum ThemeID: String, CaseIterable, Identifiable, Sendable {
    case system, paper, carbon, snow
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .paper: "Papier"
        case .carbon: "Graphit"
        case .snow: "Glas"
        }
    }
}

public struct Theme: Equatable, Sendable {
    public let id: ThemeID           // resolved (never .system)
    public let isDark: Bool
    public let page: RGBA
    public let win: RGBA
    public let bar: RGBA
    public let surface: RGBA
    public let ink: RGBA
    public let ink2: RGBA
    public let ink3: RGBA
    public let line: RGBA
    public let accent: RGBA
    public let accentInk: RGBA
    public let sel: RGBA
    public let hover: RGBA
    public let kbd: RGBA
    /// Real material behind the window (Glas).
    public let usesGlass: Bool

    public init(id: ThemeID, isDark: Bool, page: RGBA, win: RGBA, bar: RGBA, surface: RGBA, ink: RGBA,
                ink2: RGBA, ink3: RGBA, line: RGBA, accent: RGBA, accentInk: RGBA, sel: RGBA, hover: RGBA,
                kbd: RGBA, usesGlass: Bool) {
        self.id = id
        self.isDark = isDark
        self.page = page
        self.win = win
        self.bar = bar
        self.surface = surface
        self.ink = ink
        self.ink2 = ink2
        self.ink3 = ink3
        self.line = line
        self.accent = accent
        self.accentInk = accentInk
        self.sel = sel
        self.hover = hover
        self.kbd = kbd
        self.usesGlass = usesGlass
    }

    public static let paper = Theme(
        id: .paper, isDark: false,
        page: .hex(0xe9e5de), win: .hex(0xfbfaf7), bar: .hex(0xf6f4f0), surface: .hex(0xffffff),
        ink: .hex(0x1c1b19), ink2: .hex(0x5f5b55), ink3: .hex(0x9d988f),
        line: RGBA(30, 20, 10, 0.08), accent: .hex(0xd4602a), accentInk: .hex(0xffffff),
        sel: RGBA(212, 96, 42, 0.07), hover: RGBA(30, 20, 10, 0.035), kbd: .hex(0xffffff), usesGlass: false)

    public static let graphite = Theme(
        id: .carbon, isDark: true,
        page: .hex(0x0b0b0d), win: .hex(0x18181b), bar: .hex(0x1d1d21), surface: .hex(0x232328),
        ink: .hex(0xededf0), ink2: .hex(0xa3a3ad), ink3: .hex(0x6b6b75),
        line: RGBA(255, 255, 255, 0.07), accent: .hex(0xff8d52), accentInk: .hex(0x1a0d05),
        sel: RGBA(255, 141, 82, 0.09), hover: RGBA(255, 255, 255, 0.035), kbd: .hex(0x2b2b31), usesGlass: false)

    public static let glass = Theme(
        id: .snow, isDark: false,
        page: .hex(0xeef0f6), win: RGBA(255, 255, 255, 0.58), bar: RGBA(255, 255, 255, 0.35),
        surface: RGBA(255, 255, 255, 0.86),
        ink: .hex(0x14161c), ink2: .hex(0x535866), ink3: .hex(0x8d93a1),
        line: RGBA(20, 30, 60, 0.08), accent: .hex(0x2f62ff), accentInk: .hex(0xffffff),
        sel: RGBA(47, 98, 255, 0.08), hover: RGBA(20, 30, 60, 0.04), kbd: RGBA(255, 255, 255, 0.9), usesGlass: true)

    /// Hintergrund der Seitenleiste (M2.9, Entwurf §4): eine Spur dunkler als
    /// `win`, in Glas liegt sie über dem Material und bleibt deshalb heller.
    public var side: RGBA {
        switch id {
        case .paper: .hex(0xf1eee8)
        case .carbon: .hex(0x141417)
        case .snow: RGBA(255, 255, 255, 0.22)
        case .system: bar
        }
    }

    /// `system` follows the appearance: light → Papier, dark → Graphit.
    public static func resolve(_ id: ThemeID, systemDark: Bool, accentKey: String) -> Theme {
        let base: Theme
        switch id {
        case .system: base = systemDark ? .graphite : .paper
        case .paper: base = .paper
        case .carbon: base = .graphite
        case .snow: base = .glass
        }
        return base.withAccent(key: accentKey)
    }

    /// `settings.accent_color`. The default `violet` keeps the theme's own
    /// mockup accent (the same rule the Tauri themes use for the desktop accent);
    /// any other preset or a custom hex replaces it (`src/lib/accent.ts`).
    func withAccent(key: String) -> Theme {
        guard key != "violet", !key.isEmpty else { return self }
        let presets: [String: (Int, Int)] = [
            "blue": (0x2f6bd0, 0x6c9ff0), "teal": (0x0f7f86, 0x4cbcc0), "green": (0x3c8650, 0x74b381),
            "amber": (0xa8690e, 0xe3a64a), "orange": (0xc4561c, 0xec8a55), "rose": (0xc03b69, 0xe57399),
            "graphite": (0x4a5260, 0xaab1bd),
        ]
        var color: RGBA?
        if let preset = presets[key] {
            color = .hex(isDark ? preset.1 : preset.0)
        } else if key.hasPrefix("#"), key.count == 7, let value = Int(key.dropFirst(), radix: 16) {
            color = .hex(value)
        }
        guard let color else { return self }
        return Theme(id: id, isDark: isDark, page: page, win: win, bar: bar, surface: surface, ink: ink, ink2: ink2,
                     ink3: ink3, line: line, accent: color, accentInk: color.luminance > 0.6 ? .hex(0x111111) : .hex(0xffffff),
                     sel: color.with(alpha: isDark ? 0.09 : 0.07), hover: hover, kbd: kbd, usesGlass: usesGlass)
    }

    /// Colours handed to `wrapForDisplay` for HTML mail.
    public var displayTheme: DisplayThemeJSON {
        DisplayThemeJSON(text: ink.css, textMuted: ink2.css, accent: accent.css,
                         colorScheme: isDark ? "dark" : "light", fontFamily: nil)
    }
}

/// sRGB colour with alpha, as numbers. The toolkits' colour types are built
/// from it in the app (`RGBA+AppKit.swift`).
public struct RGBA: Equatable, Sendable {
    public let r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static func hex(_ v: Int) -> RGBA { RGBA(Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255)) }
    public func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
    var css: String { String(format: "#%02x%02x%02x", Int(r), Int(g), Int(b)) }
    var luminance: Double { (0.299 * r + 0.587 * g + 0.114 * b) / 255 }
}
