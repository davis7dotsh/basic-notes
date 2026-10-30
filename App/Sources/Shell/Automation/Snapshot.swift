import AppKit
import WebKit

/// In-process PNG of the panel content (native strip + web view). No Screen Recording permission needed.
enum Snapshot {
    static func png(panel: PanelController, webView: WKWebView, scale: CGFloat) async -> Result<Data, BridgeError> {
        let root = panel.root
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let size = root.bounds.size
        guard size.width > 0, size.height > 0 else { return .failure(BridgeError("panel has no size")) }

        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = true
        let webImage: NSImage
        do {
            webImage = try await webView.takeSnapshot(configuration: config)
        } catch {
            return .failure(BridgeError("web snapshot failed: \(error.localizedDescription)"))
        }

        let strip = panel.strip
        guard let stripRep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else {
            return .failure(BridgeError("strip snapshot failed"))
        }
        strip.cacheDisplay(in: strip.bounds, to: stripRep)

        let pixelsWide = Int((size.width * scale).rounded()), pixelsHigh = Int((size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return .failure(BridgeError("bitmap allocation failed")) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            let bounds = NSRect(origin: .zero, size: size)
            let shape = NSBezierPath(roundedRect: bounds, xRadius: PanelRootView.radius, yRadius: PanelRootView.radius)
            shape.addClip()
            MoonstoneCanvas.paint(in: bounds, appearance: root.effectiveAppearance, opaque: true)
            let webFrame = webView.frame
            webImage.draw(in: webFrame, from: .zero, operation: .sourceOver, fraction: 1)
            stripRep.draw(in: strip.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSColor.panelBorder.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: PanelRootView.radius, yRadius: PanelRootView.radius)
            border.lineWidth = 1
            border.stroke()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return .failure(BridgeError("png encoding failed")) }
        return .success(png)
    }

    /// Any AppKit/SwiftUI view (e.g. the settings window) via cacheDisplay.
    static func png(view: NSView, scale: CGFloat) -> Result<Data, BridgeError> {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let viewRep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return .failure(BridgeError("view has no size"))
        }
        view.cacheDisplay(in: bounds, to: viewRep)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return .failure(BridgeError("bitmap allocation failed")) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            viewRep.draw(in: bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return .failure(BridgeError("png encoding failed")) }
        return .success(png)
    }
}
