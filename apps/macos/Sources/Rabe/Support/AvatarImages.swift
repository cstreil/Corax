import AppKit
import RabeKit

/// `NSImage`s for the avatar circles (M2.4).
///
/// `AvatarPhotos` (RabeKit) keeps the decoded bytes; this cache turns them into
/// the drawable image once per sender. Both are bounded, and neither touches the
/// network: a miss simply draws the initials as before.
@MainActor
enum AvatarImages {
    private static var images: [String: NSImage] = [:]
    private static var order: [String] = []
    private static let capacity = 200

    /// The picture of a sender, or nil while it is unknown (initials then).
    static func image(for email: String) -> NSImage? {
        let key = AvatarPhotos.key(email)
        if let image = images[key] { return image }
        guard let data = AppModel.shared.avatars.photo(for: email),
              let image = NSImage(data: data) else { return nil }
        images[key] = image
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            images[oldest] = nil
        }
        return image
    }

    /// Draws an image filling a square, cropped (not stretched).
    static func fill(_ image: NSImage, in rect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        image.draw(in: NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
    }

    /// The round avatar: the sender's picture when there is one, else the
    /// initials in the address-derived colour (`AvatarColor`).
    static func draw(_ address: Address, in rect: NSRect, initialsFontSize: CGFloat,
                     enabled: Bool, theme: Theme, whiteText: Bool = true) {
        if enabled, let image = image(for: address.email) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: rect).addClip()
            fill(image, in: rect)
            NSGraphicsContext.restoreGraphicsState()
            // A hairline keeps light pictures from bleeding into the row.
            NSColor.black.withAlphaComponent(theme.isDark ? 0.35 : 0.08).setStroke()
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 0.5
            border.stroke()
            return
        }
        AvatarColor.color(for: address.email).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: initialsFontSize, weight: .semibold),
            .foregroundColor: whiteText ? NSColor.white : theme.ink.ns,
            .kern: 0.2,
        ]
        let initials = NSAttributedString(string: AvatarColor.initials(address), attributes: attributes)
        let size = initials.size()
        initials.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}


#if DEBUG || RABE_TEST_HOOKS
/// Walkthrough probe: one plain `NSStatusItem`, so a screenshot can tell
/// whether the menu bar shows status items at all (see `DebugAutomation`).
@MainActor
enum MenuBarProbe {
    private static var item: NSStatusItem?

    static func install() {
        guard item == nil else {
            PerfLog.shared.write("statusprobe exists \(item?.button?.frame ?? .zero)")
            return
        }
        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        created.button?.title = "PROBE"
        created.button?.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        item = created
        PerfLog.shared.write("statusprobe installed frame=\(created.button?.frame ?? .zero) "
                             + "visible=\(created.button?.window?.isVisible == true ? 1 : 0)")
    }
}
#endif
