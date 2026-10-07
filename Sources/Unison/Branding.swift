import AppKit

@MainActor
enum Branding {
    static let applicationIcon: NSImage = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return NSImage(size: NSSize(width: 32, height: 32)) }
        return image
    }()

    // A crisp template version of the icon's U and two faders. macOS tints
    // the alpha mask automatically for light/dark menu bars and selection.
    static let menuIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let rail = NSBezierPath()
            rail.lineWidth = 1.8
            rail.lineCapStyle = .round
            rail.move(to: NSPoint(x: 4.5, y: 15))
            rail.line(to: NSPoint(x: 4.5, y: 7))
            rail.curve(to: NSPoint(x: 13.5, y: 7), controlPoint1: NSPoint(x: 4.5, y: 0.8), controlPoint2: NSPoint(x: 13.5, y: 0.8))
            rail.line(to: NSPoint(x: 13.5, y: 15))
            rail.stroke()
            for point in [NSPoint(x: 4.5, y: 11.7), NSPoint(x: 13.5, y: 8.3)] {
                NSBezierPath(ovalIn: NSRect(x: point.x - 2.3, y: point.y - 2.3, width: 4.6, height: 4.6)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Unison"
        return image
    }()
}
