import SwiftUI
import ServiceManagement

/// The panel that opens from the menu bar icon: a header, one two-line row per
/// session grouped by state, and a footer with the list actions.
struct MenuContent: View {
    @ObservedObject var store: Store
    @ObservedObject var listener: Listener
    let open: (String) -> Void
    let copyRemoteSetup: () -> Void

    /// Above this many rows the list scrolls instead of growing the panel.
    private let maxRowsWithoutScrolling = 7

    var body: some View {
        let needs = store.list(.needsInput)
        let done = store.list(.done)
        let working = store.list(.working)
        let read = Array(store.list(.read).prefix(5))
        let total = needs.count + done.count + working.count + read.count

        VStack(alignment: .leading, spacing: 0) {
            header(needs: needs.count, done: done.count, working: working.count)
            Divider()

            if total == 0 {
                Text("No agent sessions yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                let list = VStack(alignment: .leading, spacing: 0) {
                    section("Needs a decision", needs)
                    section("Done, not read", done)
                    section("Working", working)
                    section("Read", read)
                }
                .padding(.vertical, 4)

                if total > maxRowsWithoutScrolling {
                    ScrollView { list }.frame(height: 480)
                } else {
                    list
                }
            }

            Divider()
            footer(done: done.count, finished: done.count + read.count)
        }
        .frame(width: 420)
        .background(PanelBackground().ignoresSafeArea())
    }

    // MARK: Parts

    private func header(needs: Int, done: Int, working: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "binoculars.fill")
            Text("Lookout").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(summary(needs: needs, done: done, working: working))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            SettingsMenu(listener: listener, copyRemoteSetup: copyRemoteSetup)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func summary(needs: Int, done: Int, working: Int) -> String {
        var parts: [String] = []
        if needs > 0 { parts.append("\(needs) waiting") }
        if done > 0 { parts.append("\(done) unread") }
        if working > 0 { parts.append("\(working) working") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func section(_ title: String, _ sessions: [Session]) -> some View {
        if !sessions.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(sessions) { s in
                SessionRow(session: s, action: {
                    // Close the panel first: once the target app is active there is
                    // no key window left to close.
                    NSApp.keyWindow?.close()
                    open(s.id)
                }, dismiss: { store.dismiss(s.id) })
            }
        }
    }

    private func footer(done: Int, finished: Int) -> some View {
        HStack(spacing: 14) {
            Button("Mark All as Read") { store.markAllRead() }
                .disabled(done == 0)
            Button("Clear Finished") { store.clearFinished() }
                .disabled(finished == 0)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// One session: agent icon, then folder, session name, host and age on the first
/// line, and the state icon with the last message or pending question on the second.
struct SessionRow: View {
    let session: Session
    let action: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false

    /// Working rows have no dismiss button: the agent's next event would bring them back.
    private var canDismiss: Bool { session.state != .working }

    var body: some View {
        // The dismiss button sits over the row rather than inside its button, so a
        // click on it doesn't also open the session.
        ZStack(alignment: .topTrailing) {
            rowButton
            if hovering && canDismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .padding(.top, 4)
                .padding(.trailing, 10)
            }
        }
        .onHover { hovering = $0 }
    }

    private var rowButton: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                AgentIconView(agent: session.agent, name: session.agentName)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    firstLine
                    secondLine
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .help(session.agentName)
    }

    private var firstLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let folder = session.folder {
                Text(folder)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(2)
            }
            if let host = session.remoteHost {
                Text(host)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let title = session.title, !title.isEmpty, title != session.folder {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(relative(session.updatedAt, now: context.date))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Hidden, not removed, while the dismiss button covers it, so the
            // title doesn't change width on hover.
            .opacity(hovering && canDismiss ? 0 : 1)
            .layoutPriority(2)
        }
    }

    private var secondLine: some View {
        HStack(alignment: .top, spacing: 6) {
            StateIcon(state: session.state)
                .frame(width: 14, height: 16)
            Text(secondLineText)
                .font(.system(size: 12))
                .foregroundStyle(session.state == .needsInput ? Color.primary : Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var secondLineText: String {
        switch session.state {
        case .needsInput: return session.plainDetail ?? "Waiting for your decision"
        case .done, .read: return session.plainDetail ?? "Finished"
        case .working: return "Working…"
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) d"
    }
}

/// The state of a session as a small icon at the start of the second line.
struct StateIcon: View {
    let state: SessionState

    var body: some View {
        switch state {
        case .needsInput:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .working:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        case .read:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The agent's app icon, or its initial in a rounded square when the app isn't installed.
struct AgentIconView: View {
    let agent: String
    let name: String

    var body: some View {
        if let icon = AgentIcon.image(for: agent) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: AgentIcon.size, height: AgentIcon.size)
        } else {
            Text(String(name.prefix(1)))
                .font(.system(size: 11, weight: .bold))
                .frame(width: AgentIcon.size, height: AgentIcon.size)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.12)))
        }
    }
}

/// The gear menu in the header: remote agent setup and Launch at Login.
struct SettingsMenu: View {
    @ObservedObject var listener: Listener
    let copyRemoteSetup: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Menu {
            if let base = listener.baseURL {
                Text("Remote agents: \(base)")
                Button("Copy Setup Command for Another Machine") { copyRemoteSetup() }
                Divider()
            } else if listener.config.enabled {
                Text("Remote agents: waiting for Tailscale")
                Divider()
            }
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
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The menu material behind the panel. The panel's own background follows the
/// window's active state, and Lookout is never the active app, so macOS draws the
/// inactive, nearly transparent version. This one stays active.
struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
