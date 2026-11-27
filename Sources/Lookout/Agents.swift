import AppKit

/// The agents Lookout can report on, and whether each one is connected. Connecting
/// or disconnecting runs the installer that the app bundles in its Resources folder
/// (lookout-hooks.py), so a user never has to open a terminal for it.
///
/// Amp is the exception: Lookout watches Amp itself with `amp top`, so its toggle
/// starts and stops that watcher, remembered in UserDefaults.
final class AgentSettings: ObservableObject {
    struct Agent: Identifiable {
        let id: String
        let name: String
    }

    /// In menu order: the agents most people use first.
    static let all = [
        Agent(id: "claude", name: "Claude Code"),
        Agent(id: "codex", name: "Codex"),
        Agent(id: "cursor", name: "Cursor"),
        Agent(id: "antigravity", name: "Antigravity"),
        Agent(id: "amp", name: "Amp"),
        Agent(id: "hermes", name: "Hermes"),
    ]

    @Published private(set) var connected: [String: Bool] = [:]
    @Published private(set) var found: [String: Bool] = [:]
    @Published private(set) var busy: Set<String> = []

    private static let ampKey = "agents.amp.enabled"
    private let amp: AmpWatcher
    private let queue = DispatchQueue(label: "lookout.agents")

    init(amp: AmpWatcher) {
        self.amp = amp
        // Before this setting existed, Lookout always watched Amp. Keep it on for
        // people who installed the Amp plugin; everyone else turns it on in the menu.
        if UserDefaults.standard.object(forKey: Self.ampKey) == nil {
            let plugin = NSHomeDirectory() + "/.config/amp/plugins/lookout.ts"
            UserDefaults.standard.set(FileManager.default.fileExists(atPath: plugin), forKey: Self.ampKey)
        }
        refresh()
    }

    var ampEnabled: Bool { UserDefaults.standard.bool(forKey: Self.ampKey) }

    /// Reads which agents are connected and installed, from `lookout-hooks.py status --json`.
    func refresh() {
        run(["status", "--json"]) { [weak self] _, output in
            guard let self,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: [String: Any]]
            else { return }
            var connected: [String: Bool] = [:]
            var found: [String: Bool] = [:]
            for (id, row) in obj {
                connected[id] = row["connected"] as? Bool ?? false
                found[id] = row["found"] as? Bool ?? false
            }
            connected["amp"] = self.ampEnabled
            found["amp"] = AmpWatcher.ampPath != nil
            self.connected = connected
            self.found = found
        }
    }

    func set(_ id: String, on: Bool) {
        guard !busy.contains(id), let agent = Self.all.first(where: { $0.id == id }) else { return }
        if id == "amp" {
            UserDefaults.standard.set(on, forKey: Self.ampKey)
            connected["amp"] = on
            if on {
                amp.start()
                return
            }
            amp.stop()
            // Also removes the optional Amp plugin, which reports the same threads.
        }
        busy.insert(id)
        run([on ? "install" : "uninstall", id]) { [weak self] status, output in
            guard let self else { return }
            self.busy.remove(id)
            self.refresh()
            if id != "amp" { Self.report(agent.name, on: on, status: status, output: output) }
        }
    }

    /// Shows what the installer did, including any step left for the user, such as
    /// trusting the hooks in Codex or restarting Hermes.
    private static func report(_ name: String, on: Bool, status: Int32, output: String) {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("backup:") && !$0.hasPrefix("reporter:") && $0 != name }
        let failed = status != 0 || lines.contains { $0.hasPrefix("skipped") }
        let alert = NSAlert()
        alert.messageText = failed
            ? "Couldn't \(on ? "connect" : "disconnect") \(name)"
            : "\(name) \(on ? "connected" : "disconnected")"
        // On success the title says what happened; keep only the follow-up steps,
        // joined back into sentences (the installer wraps them for a terminal).
        alert.informativeText = failed
            ? lines.joined(separator: "\n")
            : lines.filter { !$0.hasPrefix("installed:") && !$0.hasPrefix("removed:") }.joined(separator: " ")
        alert.alertStyle = failed ? .warning : .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Runs the bundled installer with the system Python and calls back on the main
    /// queue with its exit status and combined output.
    private func run(_ args: [String], done: @escaping (Int32, String) -> Void) {
        guard let script = Bundle.main.url(forResource: "lookout-hooks", withExtension: "py") else {
            done(1, "The installer is missing from Lookout.app. Rebuild the app with scripts/build-app.sh.")
            return
        }
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var status: Int32 = 1
            var output = ""
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                status = p.terminationStatus
                output = String(data: data, encoding: .utf8) ?? ""
            } catch {
                output = "Couldn't run /usr/bin/python3: \(error.localizedDescription). "
                    + "Install the Xcode Command Line Tools with xcode-select --install."
            }
            DispatchQueue.main.async { done(status, output) }
        }
    }
}
