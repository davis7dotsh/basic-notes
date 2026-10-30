// Rebuild the Basic Notes SVG, app icon family, Raycast icon and menu-bar template.
// Usage: swift scripts/make-icon.swift (AppKit only; no external dependencies).
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("App/Resources/Assets.xcassets")
let set = catalog.appendingPathComponent("AppIcon.appiconset")
let statusSet = catalog.appendingPathComponent("StatusIcon.imageset")
for dir in [set, statusSet] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func render(_ px: Int, canvas: CGFloat = 1024, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(px))
    let scale = CGFloat(px) / canvas
    ctx.scaleBy(x: scale, y: -scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ px: Int) -> Data {
    render(px) {
        let scale = CGFloat(px) / 1024
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x000000, alpha: 0.18)
        shadow.shadowBlurRadius = 20 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.set()
        color(0xEEECE7).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: color(0xFAF9F6), ending: color(0xEAE7E1))!
            .draw(in: tile, angle: 90)
        color(0x000000, alpha: 0.07).setStroke()
        tile.lineWidth = 2
        tile.stroke()

        // A wider, simpler silhouette survives the 16/32pt icon sizes.
        let small = px <= 64
        let panel = NSRect(x: small ? 282 : 302, y: 214, width: small ? 460 : 420, height: 584)
        NSGraphicsContext.saveGraphicsState()
        let lift = NSShadow()
        lift.shadowColor = color(0x000000, alpha: 0.22)
        lift.shadowBlurRadius = 42 * scale
        lift.shadowOffset = NSSize(width: 0, height: -24 * scale)
        if !small { lift.set() }
        rounded(panel, 60, color(0x202124))
        NSGraphicsContext.restoreGraphicsState()
        let inset = panel.minX + 64
        if !small {
            rounded(NSRect(x: inset, y: 310, width: 152, height: 32), 16, color(0xFAF9F6))
            rounded(NSRect(x: inset, y: 378, width: 236, height: 24), 12, color(0x939497))
        }
        if small {
            rounded(NSRect(x: inset, y: 380, width: 200, height: 56), 20, color(0xFAF9F6))
            rounded(NSRect(x: inset + 224, y: 330, width: 64, height: 156), 20, color(0x4DABF7))
        } else {
            rounded(NSRect(x: inset, y: 470, width: 120, height: 24), 12, color(0x939497))
            rounded(NSRect(x: inset + 144, y: 438, width: 24, height: 88), 12, color(0x4DABF7))
        }
    }
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try appIcon(pt * scale).write(to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)", "filename": name])
    }
}
func manifest(_ object: [String: Any], at url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try manifest(["images": images, "info": info], at: set.appendingPathComponent("Contents.json"))
try appIcon(1024).write(to: root.appendingPathComponent("assets/icon.png"))
try appIcon(512).write(to: root.appendingPathComponent("raycast/assets/extension-icon.png"))

// The same portrait-panel silhouette, drawn as a monochrome status-item template.
var statusImages: [[String: String]] = []
for scale in [1, 2] {
    let name = "status\(scale == 2 ? "@2x" : "").png"
    let data = render(18 * scale, canvas: 18) {
        let outline = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 1.5, width: 11, height: 15), xRadius: 2, yRadius: 2)
        NSColor.black.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        rounded(NSRect(x: 6, y: 6, width: 4.5, height: 1.5), 0.75, .black)
        rounded(NSRect(x: scale == 1 ? 12 : 11.25, y: scale == 1 ? 5 : 4.5, width: scale == 1 ? 1 : 1.5, height: scale == 1 ? 4 : 4.5), 0.75, .black)
    }
    try data.write(to: statusSet.appendingPathComponent(name))
    statusImages.append(["idiom": "mac", "scale": "\(scale)x", "filename": name])
}
try manifest(["images": statusImages, "info": info, "properties": ["template-rendering-intent": "template"]],
             at: statusSet.appendingPathComponent("Contents.json"))

// SVG geometry matches the full-size AppKit drawing; no fonts or embedded rasters.
let svg = #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
  <title id="title">Basic Notes</title>
  <defs>
    <linearGradient id="tile" x2="0" y2="1"><stop stop-color="#FAF9F6"/><stop offset="1" stop-color="#EAE7E1"/></linearGradient>
    <filter id="shadow" x="-25%" y="-25%" width="150%" height="160%"><feDropShadow dy="8" stdDeviation="10" flood-opacity=".18"/></filter>
    <filter id="lift" x="-50%" y="-30%" width="200%" height="180%"><feDropShadow dy="24" stdDeviation="21" flood-opacity=".22"/></filter>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#tile)" stroke="#000" stroke-opacity=".07" stroke-width="2" filter="url(#shadow)"/>
  <rect x="302" y="214" width="420" height="584" rx="60" fill="#202124" filter="url(#lift)"/>
  <rect x="366" y="310" width="152" height="32" rx="16" fill="#FAF9F6"/>
  <rect x="366" y="378" width="236" height="24" rx="12" fill="#939497"/>
  <rect x="366" y="470" width="120" height="24" rx="12" fill="#939497"/>
  <rect x="510" y="438" width="24" height="88" rx="12" fill="#4DABF7"/>
</svg>
"""#
try Data((svg + "\n").utf8).write(to: root.appendingPathComponent("assets/icon.svg"))
print("Wrote SVG, PNG, app icon family, Raycast icon and menu-bar template")
