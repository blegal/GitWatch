// Dessine l'icône de GitWatch (PNG 1024 px) : swift Tools/make-icon.swift sortie.png
// Puis Tools/make-icon.sh produit Resources/AppIcon.icns.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Forme macOS : carré à coins arrondis de 824 px, ombre douce.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
color(0x1E2A44).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [color(0x2B3D63), color(0x161E33)])!.draw(in: rect, angle: -90)

// Branche : un tronc et un embranchement, nœuds ronds (style « git graph »).
let line = NSBezierPath()
line.lineWidth = 46
line.lineCapStyle = .round
line.move(to: NSPoint(x: 400, y: 250))
line.line(to: NSPoint(x: 400, y: 770))
line.move(to: NSPoint(x: 400, y: 390))
line.curve(to: NSPoint(x: 640, y: 600), controlPoint1: NSPoint(x: 400, y: 520), controlPoint2: NSPoint(x: 640, y: 470))
color(0xE8EDF7).setStroke()
line.stroke()
func node(_ center: NSPoint, _ radius: CGFloat, _ fill: NSColor) {
    let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    color(0x1B2540).setFill()
    circle.fill()
    circle.lineWidth = 34
    fill.setStroke()
    circle.stroke()
}
node(NSPoint(x: 400, y: 250), 52, color(0xE8EDF7))
node(NSPoint(x: 400, y: 770), 52, color(0xE8EDF7))
node(NSPoint(x: 640, y: 640), 60, color(0xFFA53A))

// Pastille « à jour » : coche verte en bas à droite.
let badge = NSRect(x: 590, y: 170, width: 230, height: 230)
color(0x34C759).setFill()
NSBezierPath(ovalIn: badge).fill()
let check = NSBezierPath()
check.lineWidth = 34
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.move(to: NSPoint(x: 645, y: 288))
check.line(to: NSPoint(x: 690, y: 240))
check.line(to: NSPoint(x: 770, y: 335))
NSColor.white.setStroke()
check.stroke()

// Reflet discret en haut.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 600, width: 824, height: 324), angle: -90)
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
