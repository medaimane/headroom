import AppKit

/// The Headroom mark for the menu bar: three bars under a ceiling, drawn as a template image so macOS
/// tints it for light, dark and tinted menu bars. Warning and critical states add a badge.
/// Kept free of HeadroomCore so it can be rendered on its own for previews.
enum MenuBarIcon {
    enum State: Int, CaseIterable {
        case good, warning, critical
    }

    /// The mark is 18 × 18 points, the usual menu bar icon size. With a badge the image is wider,
    /// so the badge sits beside the mark instead of covering it.
    static func size(for state: State) -> NSSize {
        NSSize(width: state == .good ? 18 : 28, height: 18)
    }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: size(for: state), flipped: true) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch state {
        case .good: "Headroom: all good"
        case .warning: "Headroom: needs attention"
        case .critical: "Headroom: critical"
        }
        return image
    }

    private static func draw(_ state: State) {
        NSColor.black.setFill()
        NSColor.black.setStroke()

        // Ceiling and bars, following the logo's proportions (y grows downwards).
        let ceiling = NSRect(x: 2, y: 2.5, width: 14, height: 1.8)
        NSBezierPath(roundedRect: ceiling, xRadius: 0.9, yRadius: 0.9).fill()
        let bottom: CGFloat = 15.5
        let bars: [(x: CGFloat, height: CGFloat)] = [(2, 5), (7.2, 7.6), (12.4, 10)]
        for bar in bars {
            NSBezierPath(roundedRect: NSRect(x: bar.x, y: bottom - bar.height, width: 3.6, height: bar.height), xRadius: 1, yRadius: 1).fill()
        }

        guard state != .good, let context = NSGraphicsContext.current?.cgContext else { return }

        // Badge to the right of the mark: outlined for warning, filled for critical.
        let center = NSPoint(x: 23, y: 10.5)
        let radius: CGFloat = 4.6
        if state == .critical {
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            context.setBlendMode(.clear)
            exclamation(at: center).fill()
            dot(at: center).fill()
            context.setBlendMode(.normal)
        } else {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius + 0.7, y: center.y - radius + 0.7,
                                                   width: (radius - 0.7) * 2, height: (radius - 0.7) * 2))
            ring.lineWidth = 1.4
            ring.stroke()
            exclamation(at: center).fill()
            dot(at: center).fill()
        }
    }

    private static func dot(at center: NSPoint) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - 0.8, y: center.y + 1.6, width: 1.6, height: 1.6))
    }

    private static func exclamation(at center: NSPoint) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: center.x - 0.75, y: center.y - 2.7, width: 1.5, height: 3.6), xRadius: 0.75, yRadius: 0.75)
    }
}
