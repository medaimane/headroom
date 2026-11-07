// Draws docs/assets/social-preview.png (1280 × 640): the image GitHub, Slack, X and LinkedIn
// show when the repository or website link is shared. Uses only macOS tools.
// Usage: swift scripts/make-social-preview.swift   (run from the repository root; `make social` does this)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconURL = root.appending(path: "docs/assets/icon.svg")
let output = root.appending(path: "docs/assets/social-preview.png")
let width = 1280, height = 640

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

guard let icon = NSImage(contentsOf: iconURL),
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write(Data("Could not load \(iconURL.path)\n".utf8))
    exit(1)
}
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

// Background: the icon's night-to-dusk gradient, with a soft mint glow behind the icon.
NSGradient(starting: color(0x1C2B47), ending: color(0x0A111F))!.draw(in: canvas, angle: -60)
NSGradient(colors: [color(0x3DDC97, 0.16), color(0x3DDC97, 0)])!
    .draw(fromCenter: NSPoint(x: 280, y: 320), radius: 0, toCenter: NSPoint(x: 280, y: 320), radius: 380, options: [])

// The "ceiling" motif: a faint line across the top, echoing the mark.
color(0xE8F1FF, 0.10).setFill()
NSBezierPath(roundedRect: NSRect(x: 96, y: 560, width: 1088, height: 4), xRadius: 2, yRadius: 2).fill()

// App icon (its SVG has the macOS margin built in, so the tile is ~80% of this box).
icon.draw(in: NSRect(x: 80, y: 120, width: 400, height: 400))

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at point: NSPoint, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
}

let left: CGFloat = 500
draw("Headroom", size: 108, weight: .heavy, color: color(0xF4F8FF), at: NSPoint(x: left - 4, y: 330), tracking: -3)
draw("Keep your dev Mac fast.", size: 46, weight: .bold, color: color(0x5CF0B2), at: NSPoint(x: left, y: 272), tracking: -0.8)
draw("Disk, memory and dev-cache health for macOS,", size: 27, weight: .regular, color: color(0xB3BFD3), at: NSPoint(x: left, y: 214))
draw("with clean-ups you review before anything goes.", size: 27, weight: .regular, color: color(0xB3BFD3), at: NSPoint(x: left, y: 178))
draw("Free and open source  ·  medaimane.github.io/headroom", size: 21, weight: .medium, color: color(0x8794AC), at: NSPoint(x: left, y: 104))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: output)
print("Wrote \(output.path) (\(width)×\(height))")
