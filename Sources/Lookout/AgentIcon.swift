import AppKit

/// Menu-sized icons of the app each agent belongs to, taken from the installed apps.
enum AgentIcon {
    private static var cache: [String: NSImage] = [:]

    /// Bundle IDs to try for each agent, in order. Codex uses the ChatGPT app's icon
    /// and Hermes the desktop app's (the copy in /Applications is its installer).
    private static let bundles: [String: [String]] = [
        "claude": ["com.anthropic.claudefordesktop"],
        "codex": ["com.openai.codex", "com.openai.chat"],
        "hermes": ["com.nousresearch.hermes", "com.nousresearch.hermes.setup"],
        "amp": ["com.ampcode.amp.macos"],
    ]

    static func image(for agent: String, size: CGFloat = 16) -> NSImage? {
        if let cached = cache[agent] { return cached }
        for id in bundles[agent] ?? [] {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
            icon.size = NSSize(width: size, height: size)
            cache[agent] = icon
            return icon
        }
        return nil
    }
}
