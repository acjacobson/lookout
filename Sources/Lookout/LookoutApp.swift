import SwiftUI
import os

private let log = Logger(subsystem: "lookout", category: "notify")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let notifier = Notifier()
    lazy var listener = Listener(home: store.home, inbox: store.inbox)
    lazy var amp = AmpWatcher(store: store)
    lazy var agents = AgentSettings(amp: amp)

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
        if agents.ampEnabled { amp.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        amp.stop()
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
            MenuContent(store: delegate.store, listener: delegate.listener, agents: delegate.agents,
                        open: delegate.open)
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
