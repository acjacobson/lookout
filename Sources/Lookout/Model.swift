import Foundation

enum SessionState: String, Codable {
    case working
    case needsInput
    case done
    case read
}

struct Session: Codable, Identifiable {
    var id: String          // "<agent>:<sessionId>"
    var agent: String
    var sessionId: String
    var state: SessionState
    var updatedAt: Date
    var cwd: String?
    var title: String?
    var detail: String?
    var bundle: String?
    var term: String?
    var entrypoint: String?
    var host: String?

    /// The machine name, shown only for sessions on a machine other than this Mac.
    var remoteHost: String? {
        guard let host, !host.isEmpty else { return nil }
        let local = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init)
        return host.caseInsensitiveCompare(local ?? "") == .orderedSame ? nil : host
    }

    var agentName: String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "hermes": return "Hermes"
        case "amp": return "Amp"
        case "antigravity": return "Antigravity"
        default: return agent.capitalized
        }
    }

    /// A short name for the working folder: the repository for a worktree under
    /// `<repo>/.claude/worktrees/…`, none for the Claude app's scratch folders (their
    /// names are generated and say nothing about the session), otherwise the last path
    /// component without a date or a generated ID suffix.
    var folder: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let parts = cwd.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: "worktrees"), i >= 2, parts[i - 1].hasPrefix(".") {
            return parts[i - 2]
        }
        if parts.contains("scratch-workspaces") { return nil }
        guard let last = parts.last else { return nil }
        return Session.trimGenerated(last)
    }

    /// Removes `-2026-11-10` dates and a trailing six-character hex ID such as
    /// `-834281` or `-e14425`. The ID must contain a digit, so `-facade` stays.
    static func trimGenerated(_ name: String) -> String {
        var s = name.replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"-(?=[0-9a-f]*[0-9])[0-9a-f]{6}$"#, with: "", options: .regularExpression)
        return s.isEmpty ? name : s
    }

    /// Bundle IDs of the agent's own app when the session runs inside it, such as
    /// the Claude app or the ChatGPT app for Codex. Empty for sessions in a
    /// terminal or editor, where the frontmost app does not tell which tab is in view.
    var agentAppBundles: [String] {
        guard remoteHost == nil else { return [] }
        switch agent {
        case "claude":
            if entrypoint == "claude-desktop" || bundle == "com.anthropic.claudefordesktop" {
                return ["com.anthropic.claudefordesktop"]
            }
        case "codex":
            // Same test as Opener: no terminal and no bundle means the app.
            if bundle == "com.openai.codex" || (term == nil && bundle == nil) {
                return ["com.openai.codex", "com.openai.chat"]
            }
        case "amp":
            if term == nil && bundle == nil { return ["com.ampcode.amp.macos"] }
        case "hermes":
            if term == nil {
                return ["com.nousresearch.hermes", "com.nousresearch.hermes.setup"] + [bundle].compactMap { $0 }
            }
        case "antigravity":
            if let app = Session.antigravityApps[entrypoint ?? ""] { return [app] }
        default:
            break
        }
        return []
    }

    /// Antigravity's apps by the data folder name its hooks report in `transcriptPath`,
    /// which Event stores as the entrypoint. The CLI ("antigravity-cli") runs in a terminal.
    static let antigravityApps = [
        "antigravity": "com.google.antigravity",
        "antigravity-ide": "com.google.antigravity-ide",
    ]

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return folder ?? String(sessionId.prefix(8))
    }

    /// `detail` as one line of plain text: Markdown links, code marks, emphasis and
    /// list or heading markers removed.
    var plainDetail: String? {
        guard var text = detail else { return nil }
        let rules: [(String, String)] = [
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),   // [text](url) -> text
            (#"`+"#, ""),
            (#"\*\*|__"#, ""),
            (#"^(?:[-*+]|#+|\d+\.)\s+"#, ""),     // leading list or heading marker
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

/// One file from the inbox: a header line written by lookout-report, then the
/// agent's raw hook payload.
struct Event {
    var agent: String
    var state: String
    var date: Date
    var bundle: String?
    var term: String?
    var entrypoint: String?
    var host: String?
    var sessionId: String?
    var cwd: String?
    var prompt: String?
    var title: String?
    var detail: String?

    static func parse(_ data: Data, fallbackDate: Date) -> Event? {
        let newline = data.firstIndex(of: 0x0A) ?? data.endIndex
        guard let header = (try? JSONSerialization.jsonObject(with: data[..<newline])) as? [String: Any],
              let agent = header["agent"] as? String,
              let state = header["state"] as? String
        else { return nil }

        let body = newline < data.endIndex ? data[data.index(after: newline)...] : Data()
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        var event = Event(agent: agent, state: isHermesTeardown(agent, state, payload) ? "end" : state,
                          date: fallbackDate)
        if let ts = header["ts"] as? Double, ts > 0, fallbackDate.timeIntervalSince1970 - ts > 5 {
            event.date = Date(timeIntervalSince1970: ts)
        }
        event.bundle = nonEmpty(header["bundle"] as? String)
        event.term = nonEmpty(header["term"] as? String)
        event.entrypoint = nonEmpty(header["entrypoint"] as? String)
        event.host = nonEmpty(header["host"] as? String)

        let idKeys = ["session_id", "thread_id", "thread-id", "threadId", "sessionId", "conversationId"]
        event.sessionId = string(payload, idKeys)
        if event.sessionId == nil, !body.isEmpty {
            // Payload cut off at 1 MB or not JSON: look for the id in the raw text.
            event.sessionId = regexID(in: body)
        }
        event.cwd = string(payload, ["cwd", "workspace"]) ?? (payload["workspacePaths"] as? [String])?.first
        event.title = string(payload, ["title"])
        event.prompt = stripInjected(string(payload, ["prompt", "user_message", "lastUserInput"]))
        if agent == "antigravity" {
            event.entrypoint = antigravityDataFolder(payload) ?? event.entrypoint
            event.detail = antigravityDetail(for: state, payload)
        } else {
            event.detail = detail(for: state, payload)
        }
        return event
    }

    /// Hermes fires `on_session_end` after every turn, and also when the gateway or CLI
    /// closes a session it holds, for example on shutdown. The closing call passes
    /// `interrupted: true` and no `turn_id`, while the end-of-turn call always passes
    /// a `turn_id`. A closed session has not finished anything new, so it counts as "end".
    static func isHermesTeardown(_ agent: String, _ state: String, _ payload: [String: Any]) -> Bool {
        guard agent == "hermes", state == "done" else { return false }
        let extra = payload["extra"] as? [String: Any] ?? [:]
        let interrupted = (extra["interrupted"] as? Bool) ?? (payload["interrupted"] as? Bool) ?? false
        let turnID = extra["turn_id"] ?? payload["turn_id"]
        return interrupted && (turnID == nil || turnID is NSNull)
    }

    private static func detail(for state: String, _ p: [String: Any]) -> String? {
        switch state {
        case "needs":
            if let tool = string(p, ["tool_name"]) {
                let input = p["tool_input"] as? [String: Any] ?? [:]
                if tool == "AskUserQuestion",
                   let questions = input["questions"] as? [[String: Any]],
                   let q = questions.first?["question"] as? String {
                    return tidy(q)
                }
                if let what = string(input, ["description", "command", "file_path", "path"]) {
                    return tidy("\(tool): \(what)")
                }
                return tool
            }
            return tidy(string(p, ["message", "prompt", "description"]))
        case "done":
            return tidy(string(p, ["last_assistant_message", "last-assistant-message", "summary"]))
        default:
            return nil
        }
    }

    /// The name of the data folder in Antigravity's `transcriptPath`, which tells the
    /// app, the IDE and the CLI apart: `~/.gemini/<folder>/brain/<id>/…/transcript.jsonl`.
    static func antigravityDataFolder(_ p: [String: Any]) -> String? {
        guard let path = string(p, ["transcriptPath"]) else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(of: "brain"), i > 0 else { return nil }
        return parts[i - 1]
    }

    private static func antigravityDetail(for state: String, _ p: [String: Any]) -> String? {
        switch state {
        case "needs":
            // PreToolUse for the ask_question tool: show the question.
            let call = p["toolCall"] as? [String: Any] ?? [:]
            let args = call["args"] as? [String: Any] ?? [:]
            if let q = string(args, ["question", "Question", "prompt", "Prompt", "title", "Title"]) {
                return tidy(q)
            }
            for key in ["questions", "Questions"] {
                if let list = args[key] as? [[String: Any]], let first = list.first,
                   let q = string(first, ["question", "Question", "text", "Text"]) {
                    return tidy(q)
                }
            }
            return tidy(call["name"] as? String)
        case "done":
            if string(p, ["terminationReason"]) == "error" {
                return tidy("Error: \(string(p, ["error"]) ?? "the agent stopped")")
            }
            return tidy(lastAntigravityReply(string(p, ["transcriptPath"])))
        default:
            return nil
        }
    }

    /// The agent's last reply, from the end of the conversation's transcript.jsonl.
    /// Each line is one step; replies have source MODEL and type PLANNER_RESPONSE,
    /// with the text in `content` (null for steps that only call tools).
    static func lastAntigravityReply(_ path: String?) -> String? {
        guard let path, let handle = FileHandle(forReadingAtPath: (path as NSString).expandingTildeInPath)
        else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["source"] as? String == "MODEL", obj["type"] as? String == "PLANNER_RESPONSE",
                  let content = obj["content"] as? String, !content.isEmpty
            else { continue }
            return content
        }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Looks up the first non-empty string among `keys`, at the top level and in
    /// Hermes's "extra" dictionary.
    static func string(_ d: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let s = d[key] as? String, !s.isEmpty { return s }
        }
        if let extra = d["extra"] as? [String: Any] {
            for key in keys {
                if let s = extra[key] as? String, !s.isEmpty { return s }
            }
        }
        return nil
    }

    static func tidy(_ s: String?, limit: Int = 160) -> String? {
        guard let s else { return nil }
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    /// Removes blocks an app adds to the user's prompt before the hook sees it, such as
    /// the Claude app's `<system-reminder>…</system-reminder>`, so the title is what you typed.
    static func stripInjected(_ s: String?) -> String? {
        guard var text = s else { return nil }
        let pattern = #"<(system-reminder|system|context|environment_context|user_instructions|command-[a-z-]+|local-command-[a-z-]+)\b[^>]*>[\s\S]*?</\1>"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The title shown for a session, made from the user's prompt: injected blocks,
    /// pasted text and code fences removed, file mentions shortened to the file name.
    /// Handles titles cut off mid-block, as saved titles are cut at a length limit.
    static func cleanTitle(_ s: String?) -> String? {
        guard var text = stripInjected(s) else { return nil }
        let rules: [(String, String)] = [
            (#"<pasted_content\b[\s\S]*?(?:</pasted_content>|$)"#, " "),
            (#"```[\s\S]*?(?:```|$)"#, " "),
            (#"<[A-Za-z_][^>]*$"#, " "),                              // tag cut off at the end
            (#"@"?(?:/[^\s"/]+)*/([^\s"/]+)"?"#, "@$1"),           // @"/a/b/file.py" -> @file.py
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return tidy(text, limit: 100) ?? "[pasted text]"
    }

    private static func regexID(in body: Data) -> String? {
        guard let text = String(data: body.prefix(4096), encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #""(?:session_id|thread_id|thread-id|conversationId)"\s*:\s*"([^"]+)""#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }
}
