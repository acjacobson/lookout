import AppKit

/// The menu bar badge: the attention count in white on a red rounded square.
enum Badge {
    private static var cache: [Int: NSImage] = [:]

    static func image(count: Int) -> NSImage {
        if let cached = cache[count] { return cached }
        let text = (count > 99 ? "99+" : "\(count)") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attrs)
        let height: CGFloat = 17
        let width = max(height, ceil(textSize.width) + 9)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                      withAttributes: attrs)
            return true
        }
        // Not a template image, so the menu bar keeps the red and white.
        image.isTemplate = false
        cache[count] = image
        return image
    }
}
