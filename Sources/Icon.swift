import AppKit

/// Menu bar icon: the network glyph with an optional notification-style badge
/// (e.g. "CF") knocked out of its bottom-right corner. Template image, so it follows
/// the menu bar's light/dark colour like every other icon.
enum Icon {
    /// Fixed canvas and pill size (wide enough for any 2-letter badge), so the icon is the
    /// same width whatever the badge says, or with no badge at all.
    static func metrics(_ glyph: NSImage) -> (size: NSSize, pillW: CGFloat) {
        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        let widest = ("MW" as NSString).size(withAttributes: [.font: font]).width
        let pillW = ceil(widest) + 5
        let overhang = max(0, pillW - 12)  // pill overlaps the glyph's corner, rest hangs past it
        return (NSSize(width: glyph.size.width + overhang, height: max(glyph.size.height, 16)), pillW)
    }

    static func make(badge: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let glyph = NSImage(systemSymbolName: "network", accessibilityDescription: "DNS")!
            .withSymbolConfiguration(config)!
        guard !badge.isEmpty else {
            // Same canvas as the badged icon, so the menu bar item never changes width;
            // the globe is centred so the empty state doesn't look lopsided.
            let img = NSImage(size: metrics(glyph).size, flipped: false) { r in
                glyph.draw(at: NSPoint(x: (r.width - glyph.size.width) / 2, y: (r.height - glyph.size.height) / 2), from: .zero,
                           operation: .sourceOver, fraction: 1)
                return true
            }
            img.isTemplate = true
            img.accessibilityDescription = "DNS"
            return img
        }

        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        let text = NSAttributedString(string: badge, attributes: [.font: font, .foregroundColor: NSColor.black])
        let textSize = text.size()
        let (size, pillW) = metrics(glyph)
        let pillH: CGFloat = 10
        let gap: CGFloat = 1.5  // clear ring between pill and glyph

        let img = NSImage(size: size, flipped: false) { _ in
            let glyphY = (size.height - glyph.size.height) / 2
            glyph.draw(at: NSPoint(x: 0, y: glyphY), from: .zero, operation: .sourceOver, fraction: 1)

            let pill = NSRect(x: size.width - pillW, y: 0, width: pillW, height: pillH)
            let ctx = NSGraphicsContext.current!
            ctx.compositingOperation = .clear
            NSBezierPath(roundedRect: pill.insetBy(dx: -gap, dy: -gap),
                         xRadius: pillH / 2 + gap, yRadius: pillH / 2 + gap).fill()
            ctx.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
            // Knock the label out of the pill.
            ctx.compositingOperation = .destinationOut
            text.draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2 + 0.5))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "DNS: \(badge)"
        return img
    }

    /// The same icon painted in a fixed colour (e.g. red for packet loss). Not a template, since
    /// the menu bar would otherwise repaint it in its own monochrome.
    static func tinted(_ icon: NSImage, _ color: NSColor) -> NSImage {
        let img = NSImage(size: icon.size, flipped: false) { r in
            icon.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = icon.accessibilityDescription
        return img
    }
}
