import AppKit

/// Brings up the app a session runs in, on that session where the app has a link for it.
enum Opener {
    static func open(_ s: Session) {
        // A session on another machine has no app or folder here. Hermes keeps its
        // link, since the Hermes desktop app can be connected to a Hermes elsewhere.
        if s.remoteHost != nil, s.agent != "hermes" { return }
        switch s.agent {
        case "claude":
            if s.entrypoint == "claude-desktop" || s.bundle == "com.anthropic.claudefordesktop" {
                // The Claude app's continue link takes only its own session IDs
                // (local_…), so look up the one that maps to this Claude Code session.
                if let local = claudeAppSessionID(forCLISession: s.sessionId),
                   openURL("claude://code/continue?session=\(local)") { return }
                if openURL("claude://code/needs-input") { return }
            }
        case "codex":
            // Threads started in ChatGPT.app (com.openai.codex) run hooks without a
            // terminal and without __CFBundleIdentifier, so no terminal means the app.
            if s.bundle == "com.openai.codex" || (s.term == nil && s.bundle == nil) {
                if openURL("codex://threads/\(escaped(s.sessionId))") { return }
            }
        case "amp":
            // The Amp Mac app intercepts ampcode.com thread links once it has run once.
            if openURL("https://ampcode.com/threads/\(escaped(s.sessionId))") { return }
        case "hermes":
            // The Hermes desktop app routes hermes://open/<path> to its page at <path>.
            if openURL("hermes://open/sessions/\(escaped(s.sessionId))") { return }
            if activate(bundle: s.bundle) || activate(bundle: "com.nousresearch.hermes")
                || activate(bundle: "com.nousresearch.hermes.setup") { return }
        case "cursor":
            // Cursor's own menu bar icon opens a chat with this link, which brings up
            // the Agents window on that chat. Not documented by Cursor.
            if s.bundle == Session.cursorApp,
               openURL("cursor://anysphere.cursor-deeplink/agent?id=\(query(s.sessionId))") { return }
        case "antigravity":
            // Antigravity has no link to a conversation, so bring its app forward.
            if let app = Session.antigravityApps[s.entrypoint ?? ""], activate(bundle: app) { return }
        default:
            break
        }
        // A terminal or editor session: bring that app forward.
        if activate(bundle: s.bundle) { return }
        if let cwd = s.cwd, FileManager.default.fileExists(atPath: cwd) {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        }
    }

    /// Finds the Claude app's session file whose cliSessionId matches, and returns
    /// its sessionId. The app keeps one JSON file per session under
    /// ~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/.
    static func claudeAppSessionID(forCLISession cli: String) -> String? {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        let needle = Data(cli.utf8)
        for case let url as URL in files where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            guard let data = try? Data(contentsOf: url), data.range(of: needle) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let local = obj["sessionId"] as? String
            else { continue }
            if obj["cliSessionId"] as? String == cli || obj["lastAssistantCliSessionId"] as? String == cli {
                return local
            }
        }
        return nil
    }

    private static func query(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? s
    }

    private static func escaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    @discardableResult
    private static func openURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        if url.scheme != "https", NSWorkspace.shared.urlForApplication(toOpen: url) == nil { return false }
        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    private static func activate(bundle: String?) -> Bool {
        guard let bundle, !bundle.isEmpty else { return false }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            return running.activate(options: [.activateAllWindows])
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
