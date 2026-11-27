import Foundation
import Combine

/// Holds one row per agent session and keeps it current from the inbox folder
/// that lookout-report writes to.
final class Store: ObservableObject {
    @Published private(set) var sessions: [String: Session] = [:]

    /// Called when a session moves into "needs a decision" or "done".
    var onAttention: ((Session) -> Void)?
    /// Called when a session no longer needs attention, so its notification can go.
    var onCleared: ((String) -> Void)?

    let home: URL
    let inbox: URL
    private let stateFile: URL
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    init() {
        let env = ProcessInfo.processInfo.environment["LOOKOUT_HOME"]
        home = URL(fileURLWithPath: env ?? (NSHomeDirectory() + "/.lookout"))
        inbox = home.appendingPathComponent("inbox")
        stateFile = home.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        load()
    }

    // MARK: Watching the inbox

    func start() {
        // The kernel signals a write on the folder whenever lookout-report renames a
        // file into it. The timer covers missed signals and runs pruning.
        let fd = open(inbox.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.drain() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.drain()
            self?.prune()
        }
        prune()
        drain()
    }

    func drain() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let files = urls.filter { $0.pathExtension == "json" }
            .map { ($0, modified($0)) }
            .sorted { $0.1 < $1.1 }
        guard !files.isEmpty else { return }
        for (url, date) in files {
            if let data = try? Data(contentsOf: url), let event = Event.parse(data, fallbackDate: date) {
                apply(event)
            }
            try? fm.removeItem(at: url)
        }
        save()
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }

    // MARK: State changes

    func apply(_ e: Event) {
        guard let sid = e.sessionId, !sid.isEmpty else { return }
        let key = "\(e.agent):\(sid)"
        var s = sessions[key] ?? Session(id: key, agent: e.agent, sessionId: sid, state: .working, updatedAt: e.date)
        let previous = sessions[key]?.state

        if let v = e.bundle { s.bundle = v }
        if let v = e.term { s.term = v }
        if let v = e.entrypoint { s.entrypoint = v }
        if let v = e.host { s.host = v }
        if let v = e.cwd { s.cwd = v }
        if let v = e.title { s.title = Event.tidy(v, limit: 100) }
        if s.title == nil, e.state == "prompt", let p = e.prompt { s.title = Event.cleanTitle(p) }
        s.updatedAt = max(s.updatedAt, e.date)

        switch e.state {
        case "prompt", "working":
            s.state = .working
            s.detail = nil
            if previous == .needsInput || previous == .done { onCleared?(key) }
        case "needs":
            s.state = .needsInput
            if let d = e.detail { s.detail = d }
            sessions[key] = s
            if previous != .needsInput { onAttention?(s) }
            return
        case "reply":
            // The agent's latest message, from agents whose "done" event has no text
            // (Cursor). It shows once the session is done.
            if let d = e.detail { s.detail = d }
        case "done":
            s.state = .done
            // Keep a message from "reply" unless this event has its own.
            if let d = e.detail { s.detail = d } else if previous != .working { s.detail = nil }
            sessions[key] = s
            if previous != .done { onAttention?(s) }
            return
        case "end":
            // A closed session that still waits to be read stays in the list.
            if s.state == .working || s.state == .read {
                sessions[key] = nil
                return
            }
        default:
            break
        }
        sessions[key] = s
    }

    func markRead(_ key: String) {
        guard var s = sessions[key], s.state == .done || s.state == .needsInput else { return }
        // A session waiting on a decision stays "needs" until the agent moves on;
        // opening it only clears the notification.
        if s.state == .done {
            s.state = .read
            sessions[key] = s
            save()
        }
        onCleared?(key)
    }

    func markAllRead() {
        for (key, s) in sessions where s.state == .done {
            var r = s
            r.state = .read
            sessions[key] = r
            onCleared?(key)
        }
        save()
    }

    /// Removes one row and its notification. The session gets a new row with its
    /// next event, such as the next prompt.
    func dismiss(_ key: String) {
        guard sessions[key] != nil else { return }
        sessions[key] = nil
        onCleared?(key)
        save()
    }

    func clearFinished() {
        for (key, s) in sessions where s.state == .done || s.state == .read {
            sessions[key] = nil
            onCleared?(key)
        }
        save()
    }

    /// Drops rows nobody needs any more: read rows after 12 hours, working rows
    /// with no event for 2 hours (the agent probably exited), everything after 3 days.
    func prune() {
        let now = Date()
        var changed = false
        for (key, s) in sessions {
            let age = now.timeIntervalSince(s.updatedAt)
            let stale: Bool
            switch s.state {
            case .read: stale = age > 12 * 3600
            case .working: stale = age > 2 * 3600
            case .done, .needsInput: stale = age > 3 * 86400
            }
            if stale {
                sessions[key] = nil
                changed = true
            }
        }
        if changed { save() }
    }

    func list(_ state: SessionState) -> [Session] {
        sessions.values.filter { $0.state == state }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var attentionCount: Int {
        sessions.values.filter { $0.state == .needsInput || $0.state == .done }.count
    }

    var needsCount: Int {
        sessions.values.filter { $0.state == .needsInput }.count
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let list = try? decoder.decode([Session].self, from: data) {
            // Titles saved by earlier versions can still hold pasted text or tags.
            let cleaned = list.map { s -> Session in
                var s = s
                s.title = Event.cleanTitle(s.title)
                return s
            }
            sessions = Dictionary(cleaned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Saves after changes made through `apply` from outside the inbox, such as Amp.
    func persist() { save() }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(sessions.values)) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }
}
