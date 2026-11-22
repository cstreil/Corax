import AppKit
import CoraxKit
import SwiftUI

// The theme tokens themselves (ThemeID, Theme, RGBA) live in `CoraxKit` as plain
// data; this file is the AppKit/SwiftUI side of them: colour conversion, motion
// and the environment key.

extension RGBA {
    var color: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }
    var ns: NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
    var cg: CGColor { ns.cgColor }
}

/// Mockup motion: `cubic-bezier(.22,.8,.2,1)`, 360 ms. Off with Reduce Motion.
enum Motion {
    static let duration: TimeInterval = 0.36
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.2, 1) }
    static var animation: Animation? { reduce ? nil : .timingCurve(0.22, 0.8, 0.2, 1, duration: duration) }
    static var effectiveDuration: TimeInterval { reduce ? 0 : duration }
    /// The same curve evaluated by hand, for frame-driven animations.
    static func ease(_ t: Double) -> Double {
        let (x1, y1, x2, y2) = (0.22, 0.8, 0.2, 1.0)
        func bez(_ u: Double, _ a: Double, _ b: Double) -> Double { 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u }
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<24 { u = (lo + hi) / 2; if bez(u, x1, x2) < t { lo = u } else { hi = u } }
        return bez(u, y1, y2)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.paper }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Stable avatar colour per sender: hash of the address into a palette taken
/// from the mockup's sender colours (`mail-data.js`, field `c`). The own
/// accounts get the mockup's neutral grey.
enum AvatarColor {
    static let palette: [Int] = [0xc2410c, 0xe2231a, 0xb45309, 0xca8a04, 0x16a34a, 0x0d9488,
                                 0x0a66c2, 0x2563eb, 0x7c3aed, 0xdb2777, 0xf38020, 0x8b8fa3]
    static let own = 0x6d6a64
    static func index(_ s: String) -> Int {
        var h: UInt32 = 2166136261                      // FNV-1a, stable across launches
        for byte in s.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
        return Int(h % UInt32(palette.count))
    }
    @MainActor static func color(for email: String) -> NSColor {
        let key = email.lowercased()
        if AppModel.shared.selfEmails.contains(key) { return RGBA.hex(own).ns }
        return RGBA.hex(palette[index(key)]).ns
    }
    static func initials(_ address: Address) -> String {
        // Letters only: "Telekom Deutschland GmbH {Kundenservice}" → "TK", not "T{".
        let name = String(address.displayName.unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }.map(Character.init))
        let fallback = address.displayName
        let parts = name.split(whereSeparator: \.isWhitespace).filter { !$0.isEmpty }
        if parts.isEmpty { return String(fallback.prefix(2)).uppercased() }
        if parts.count >= 2, let a = parts.first?.first, let b = parts.last?.first { return String([a, b]).uppercased() }
        return String(name.prefix(2)).uppercased()
    }
}
