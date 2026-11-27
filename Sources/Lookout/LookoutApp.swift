import SwiftUI
import os

private let log = Logger(subsystem: "lookout", category: "notify")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let notifier = Notifier()
    lazy var listener = Listener(home: store.home, inbox: store.inbox)
    lazy var amp = AmpWatcher(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.onOpen = { [weak self] key in self?.open(key) }
        store.onAttention = { [weak self] s in
            // You are already looking at the app this session runs in, so the alert
            // would only repeat what is on screen. The menu bar badge still counts it.
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               s.agentAppBundles.contains(front) {
                log.notice("no notification for \(s.id, privacy: .public): \(front, privacy: .public) is frontmost")
                return
            }
            log.notice("notifying for \(s.id, privacy: .public)")
            self?.notifier.post(s)
        }
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
            // Installs hooks for every agent found on that machine.
            "python3 ~/.lookout/lookout-hooks.py install",
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
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        let count = store.attentionCount
        if count == 0 {
            Image(systemName: "binoculars")
        } else {
            Image(nsImage: Badge.image(count: count))
                .renderingMode(.original)
        }
    }
}
