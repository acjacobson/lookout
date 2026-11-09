import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let notifier = Notifier()
    lazy var listener = Listener(home: store.home, inbox: store.inbox)
    lazy var amp = AmpWatcher(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.onOpen = { [weak self] key in self?.open(key) }
        store.onAttention = { [weak self] s in self?.notifier.post(s) }
        store.onCleared = { [weak self] key in self?.notifier.remove(key) }
        notifier.setUp()
        store.start()
        listener.start()
        amp.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        amp.stop()
    }

    /// A shell command that sets up another machine to report to this Lookout.
    func copyRemoteSetup() {
        guard let base = listener.baseURL else { return }
        let token = listener.config.token
        let cmd = [
            "mkdir -p ~/.lookout/bin",
            "curl -fsS \(base)/reporter -o ~/.lookout/bin/lookout-report",
            "chmod 755 ~/.lookout/bin/lookout-report",
            "printf 'LOOKOUT_URL=%s\\nLOOKOUT_TOKEN=%s\\n' '\(base)' '\(token)' > ~/.lookout/remote.env",
            "chmod 600 ~/.lookout/remote.env",
            "curl -fsS \(base)/installer -o ~/.lookout/lookout-hooks.py",
            "python3 ~/.lookout/lookout-hooks.py install hermes",
        ].joined(separator: " && ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    func open(_ key: String) {
        guard let s = store.sessions[key] else { return }
        Opener.open(s)
        store.markRead(key)
    }
}

@main
struct LookoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: delegate.store, listener: delegate.listener,
                        open: delegate.open, copyRemoteSetup: delegate.copyRemoteSetup)
        } label: {
            MenuLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        let count = store.attentionCount
        if count == 0 {
            Image(systemName: "binoculars")
        } else {
            let symbol = store.needsCount > 0 ? "exclamationmark.bubble.fill" : "binoculars.fill"
            Text("\(Image(systemName: symbol)) \(count)")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: Store
    @ObservedObject var listener: Listener
    let open: (String) -> Void
    let copyRemoteSetup: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let needs = store.list(.needsInput)
        let done = store.list(.done)
        let working = store.list(.working)
        let read = Array(store.list(.read).prefix(5))

        if needs.isEmpty && done.isEmpty && working.isEmpty && read.isEmpty {
            Text("No agent sessions yet")
        }
        if !needs.isEmpty {
            Section("Needs a decision") { rows(needs) }
        }
        if !done.isEmpty {
            Section("Done, not read") { rows(done) }
        }
        if !working.isEmpty {
            Section("Working") { rows(working) }
        }
        if !read.isEmpty {
            Section("Read") { rows(read) }
        }

        Divider()
        Button("Mark All as Read") { store.markAllRead() }
            .disabled(done.isEmpty)
        Button("Clear Finished") { store.clearFinished() }
            .disabled(done.isEmpty && read.isEmpty)
        Divider()
        if let base = listener.baseURL {
            Text("Remote agents: \(base)")
            Button("Copy Setup Command for Another Machine") { copyRemoteSetup() }
        } else if listener.config.enabled {
            Text("Remote agents: waiting for Tailscale")
        }
        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Lookout: launch at login change failed: \(error)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        ))
        Divider()
        Button("Quit Lookout") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func rows(_ list: [Session]) -> some View {
        ForEach(list) { s in
            Button {
                open(s.id)
            } label: {
                if let icon = AgentIcon.image(for: s.agent) {
                    Label {
                        Text(label(s, withAgent: false))
                    } icon: {
                        Image(nsImage: icon)
                    }
                } else {
                    Text(label(s, withAgent: true))
                }
            }
            .help(s.agentName)
        }
    }

    private func label(_ s: Session, withAgent: Bool) -> String {
        var parts = [withAgent ? "\(s.agentName): \(s.displayTitle)" : s.displayTitle]
        if let folder = s.folder, folder != s.displayTitle { parts.append(folder) }
        if let host = s.remoteHost { parts.append("on \(host)") }
        parts.append(relative(s.updatedAt))
        return parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) d"
    }
}
