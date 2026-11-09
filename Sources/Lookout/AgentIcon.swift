import AppKit

/// Menu-sized icons of the app each agent belongs to, taken from the installed apps.
enum AgentIcon {
    static let size: CGFloat = 20
    private static var cache: [String: NSImage] = [:]

    /// Bundle IDs to try for each agent, in order. Codex uses the ChatGPT app's icon
    /// and Hermes the desktop app's (the copy in /Applications is its installer).
    private static let bundles: [String: [String]] = [
        "claude": ["com.anthropic.claudefordesktop"],
        "codex": ["com.openai.codex", "com.openai.chat"],
        "hermes": ["com.nousresearch.hermes", "com.nousresearch.hermes.setup"],
        "amp": ["com.ampcode.amp.macos"],
    ]

    static func image(for agent: String) -> NSImage? {
        if let cached = cache[agent] { return cached }
        for id in bundles[agent] ?? [] {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let icon = cropped(NSWorkspace.shared.icon(forFile: url.path), to: size)
            cache[agent] = icon
            return icon
        }
        return nil
    }

    /// Removes the transparent margin around an icon's artwork, so icons with wide
    /// margins (Amp's) appear as large as the others, then scales to `size` points.
    private static func cropped(_ icon: NSImage, to size: CGFloat) -> NSImage {
        let px = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return resized(icon, size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()

        // Bounding box of pixels that aren't almost fully transparent.
        var minX = px, minY = px, maxX = -1, maxY = -1
        for y in 0..<px {
            for x in 0..<px {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, let cg = rep.cgImage else { return resized(icon, size) }

        // Keep the crop square, centered on the artwork.
        let side = min(px, max(maxX - minX + 1, maxY - minY + 1) + 6)  // 3 px margin per side
        let cx = (minX + maxX + 1) / 2, cy = (minY + maxY + 1) / 2
        let x0 = max(0, min(px - side, cx - side / 2))
        let y0 = max(0, min(px - side, cy - side / 2))
        // colorAt uses top-left origin, and so does CGImage cropping.
        guard let crop = cg.cropping(to: CGRect(x: x0, y: y0, width: side, height: side)) else {
            return resized(icon, size)
        }
        let out = NSImage(cgImage: crop, size: NSSize(width: size, height: size))
        return out
    }

    private static func resized(_ icon: NSImage, _ size: CGFloat) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}
