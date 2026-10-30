// Generates App/Resources/Assets.xcassets/AppIcon.appiconset from the design in assets/icon.svg
// (pink rounded square, white "RN"), drawn natively so text renders correctly.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
try Data(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#.utf8)
    .write(to: root.appendingPathComponent("App/Resources/Assets.xcassets/Contents.json"))

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824pt body centered in 1024 with room for the shadow.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0xDB / 255, green: 0x27 / 255, blue: 0x77 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    let font = NSFont.systemFont(ofSize: 330 * s, weight: .semibold)
    let text = NSAttributedString(string: "RN", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -6 * s])
    let size = text.size()
    // Center on cap height rather than the line box.
    let y = body.midY - (font.capHeight / 2) + font.descender
    text.draw(at: NSPoint(x: body.midX - size.width / 2, y: y))
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try render(pt * scale).write(to: set.appendingPathComponent(name))
        images.append(#"{ "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(pt)x\#(pt)", "filename" : "\#(name)" }"#)
    }
}
try Data(#"{ "images" : [ \#(images.joined(separator: ", ")) ], "info" : { "author" : "xcode", "version" : 1 } }"#.utf8)
    .write(to: set.appendingPathComponent("Contents.json"))
print("wrote \(set.path)")
