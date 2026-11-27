import Foundation

/// Watches Amp threads, including threads run by the Amp Mac app on Amp's servers,
/// by running `amp top --stream-jsonl`. The Amp CLI prints the active thread list
/// as one JSON line whenever it changes. Each thread has `working: true` while a
/// turn runs, and a change from true to false means the turn finished.
///
/// Amp has no approval prompt, so Amp rows are only ever "working" or "done".
final class AmpWatcher {
    private let store: Store
    private var process: Process?
    private var buffer = Data()
    private var working: [String: Bool] = [:]
    private var restartDelay: TimeInterval = 5
    /// False after stop(), so a pending restart doesn't bring the watcher back.
    private var enabled = false

    init(store: Store) {
        self.store = store
    }

    /// The Amp CLI, if installed. Lookout starts with a minimal PATH when launched
    /// from Finder or at login, so look in the installer's locations directly.
    static var ampPath: String? {
        let home = NSHomeDirectory()
        return [home + "/.amp/bin/amp", home + "/.local/bin/amp", "/opt/homebrew/bin/amp", "/usr/local/bin/amp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        enabled = true
        guard process == nil, let amp = Self.ampPath else { return }
        let p = Process()
        // A shell wrapper ends `amp top` when Lookout goes away. If Lookout is killed,
        // macOS doesn't stop its children, and amp would keep running on its own.
        let script = """
        lookout=$PPID
        "$0" top --stream-jsonl & amp=$!
        trap 'kill $amp 2>/dev/null; exit 0' TERM INT HUP
        while kill -0 "$lookout" 2>/dev/null && kill -0 "$amp" 2>/dev/null; do sleep 2; done
        kill "$amp" 2>/dev/null
        wait "$amp"
        """
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, amp]
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.restart() }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("Lookout: could not start amp top: \(error)")
            restart()
        }
    }

    func stop() {
        enabled = false
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func restart() {
        process = nil
        buffer.removeAll()
        // Not signed in, offline, or Amp updated itself: try again, waiting longer each time.
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 300)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.enabled else { return }
            self.start()
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let threads = obj["threads"] as? [[String: Any]]
        else { return }
        restartDelay = 5

        for t in threads {
            guard let id = t["id"] as? String, !id.isEmpty else { continue }
            let isWorking = t["working"] as? Bool ?? false
            let wasWorking = working[id]
            working[id] = isWorking

            var event = Event(agent: "amp", state: "", date: Date())
            event.sessionId = id
            if let title = t["title"] as? String, !title.isEmpty, title != "Untitled" { event.title = title }
            if let project = t["project"] as? String, !project.isEmpty { event.cwd = project }

            if isWorking, wasWorking != true {
                event.state = "working"
                store.apply(event)
                store.persist()
            } else if !isWorking, wasWorking == true {
                event.state = "done"
                store.apply(event)
                store.persist()
            } else if isWorking, event.title != nil, store.sessions["amp:\(id)"]?.title == nil {
                // The title arrives a few seconds after the turn starts.
                event.state = "working"
                store.apply(event)
                store.persist()
            }
            // Threads idle on the first line are history, not new rows.
        }
    }
}
