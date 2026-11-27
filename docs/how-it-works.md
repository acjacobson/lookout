# How Lookout works

## Reporting events

1. Each agent runs `~/.lookout/bin/lookout-report <agent> <state>` from its hooks. The script writes the hook's JSON payload, plus a one-line header, as a file in `~/.lookout/inbox`, then exits. It never waits for the app and never prints a decision, so it can't hold up or change what the agent does.
2. Lookout watches that folder, keeps one row per session (working, needs a decision, done and unread, read), and stores the rows in `~/.lookout/state.json`.
3. When a session changes to "needs a decision" or "done", Lookout posts a macOS notification. Clicking the notification or the menu row opens the session.

| Agent | Done | Needs a decision | Click opens |
|---|---|---|---|
| Claude Code | `Stop` | `PermissionRequest`, `Notification`, `PreToolUse` for `AskUserQuestion` | the session in the Claude app (`claude://code/continue?session=local_…`); for terminal sessions, the terminal |
| Codex | `Stop` | `PermissionRequest` | the thread in ChatGPT.app (`codex://threads/<id>`); for terminal sessions, the terminal |
| Hermes | `on_session_end` (fires after every turn) | `on_human_input_request` | the session in the Hermes desktop app (`hermes://open/sessions/<id>`) |
| Amp | `working` changes from true to false in `amp top --stream-jsonl` | not available, since Amp doesn't stop for approval | `https://ampcode.com/threads/<id>`, which the Amp app intercepts |
| Antigravity | `Stop` | `PreToolUse` for `ask_question` | the Antigravity app or IDE, without opening the conversation; for terminal sessions, the terminal |
| Cursor | `stop` | not available, since Cursor has no hook event for approval prompts | the Cursor app, without opening the chat |

Amp has no hooks, and threads in the Amp Mac app run on Amp's servers, not on this Mac. Lookout instead runs the Amp CLI's `amp top --stream-jsonl`, which prints the active thread list, with a `working` flag per thread, whenever it changes. This covers threads from the Mac app and from the CLI. It needs the Amp CLI installed and signed in (`amp login`). Lookout looks for it in `~/.amp/bin`, `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, and retries with increasing delays if `amp` exits. The Amp plugin from `lookout-hooks.py` is optional; it reports the same threads under the same IDs.

The app an agent runs in comes from the `__CFBundleIdentifier` environment variable. macOS sets it for processes started from an app bundle, and the hook process inherits it. ChatGPT.app doesn't pass it to Codex hooks, so a Codex session with no terminal is treated as a ChatGPT.app thread.

Antigravity has no hook event for approval prompts, so a tool waiting for your approval shows as working. Its `PreToolUse` and `Stop` hooks must print a decision, so the Antigravity hook command prints `{"decision":"allow"}` or `{"decision":"stop"}` after the reporter. "allow" leaves the tool to Antigravity's own permission rules, and any `Stop` decision other than "continue" lets the agent stop, so neither changes what the agent does. Antigravity's `antigravity://` links can start a new prompt but can't open an existing conversation, so clicking a row only brings the app forward. Lookout tells the app, the IDE and the CLI apart by the data folder in the hook's `transcriptPath` (`~/.gemini/antigravity`, `antigravity-ide` or `antigravity-cli`), and reads the agent's last reply from that transcript.

Cursor's `stop` event carries no text, so Lookout also listens to `afterAgentResponse` and shows the agent's last message on the "done" row. Cursor treats hook output it can't parse as a refusal for some events, so each Cursor hook prints a valid reply after the reporter: `{"continue":true}` for `beforeSubmitPrompt`, which lets the prompt through, and `{}` for the rest. Cursor documents no link to a chat, so clicking a row brings Cursor forward.

The Claude app's link takes only its own session IDs (`local_…`), not the Claude Code session ID that hooks report. Lookout finds the matching ID in the app's session files under `~/Library/Application Support/Claude/claude-code-sessions`, where each file holds both (`sessionId` and `cliSessionId`).

## Installing hooks from a terminal

The Agents section of the gear menu connects and disconnects agents. It does this by running `scripts/lookout-hooks.py`, which you can also run yourself:

```bash
python3 scripts/lookout-hooks.py install
```

The app keeps a copy of the script in `Lookout.app/Contents/Resources`. With no agent names, `install` copies the reporter to `~/.lookout/bin` and adds hooks for each agent it finds on the machine, by its config folder or app, and lists the ones it skipped. Name agents to install only those, for example `install claude codex`; a named agent is installed even if it isn't found. Each file is backed up to `~/.lookout/backups` first, and existing hooks are kept.

- **Claude Code:** adds entries to `~/.claude/settings.json`. New sessions pick them up.
- **Codex:** adds entries to `~/.codex/hooks.json`. Codex skips new hooks until you trust them: run `/hooks` in the Codex CLI, or open Settings > Hooks in the ChatGPT app.
- **Hermes:** appends a marked `hooks:` block to `~/.hermes/config.yaml` and approves those commands in `~/.hermes/shell-hooks-allowlist.json`. If the config already has a `hooks:` section, the script prints the entries to add by hand instead. Restart Hermes so it loads them. For a Hermes home in another folder, pass `--hermes-home <folder>`; see "Hermes in Docker" below.
- **Amp:** copies `integrations/amp/lookout.ts` to `~/.config/amp/plugins/`.
- **Cursor:** adds entries to `~/.cursor/hooks.json`. Cursor reloads the file on its own; the hooks are listed under Settings > Hooks. User hooks don't run in Cursor's cloud agents.
- **Antigravity:** adds a hook named `lookout` to `~/.gemini/config/hooks.json`, which the Antigravity app, the IDE and the CLI all read. New conversations pick it up; restart the app or IDE if they don't.

```bash
python3 scripts/lookout-hooks.py status
```

```bash
python3 scripts/lookout-hooks.py uninstall
```

`status --json` prints the same as `status` as JSON, which the Agents menu reads. The Amp toggle in the menu starts and stops Lookout's `amp top` watcher; turning it off also removes the optional Amp plugin.

## Signing and notifications

The build script signs the app with the first valid Apple Development certificate in your keychain, chosen by hash because expired certificates can have the same name. Set `LOOKOUT_SIGN_IDENTITY` to use another identity. Without a certificate it signs ad hoc, and macOS then refuses notifications ("Notifications are not allowed for this application") without asking. macOS remembers that refusal for the bundle ID, `dev.lookout.Lookout`; if it happened, rebuild with a certificate and allow Lookout under System Settings > Notifications.

## Not verified yet

- `amp top --stream-jsonl` is marked experimental by Amp, so its output may change.
- Whether Antigravity runs `PreToolUse` hooks for its `ask_question` tool, which "needs a decision" depends on. The question text comes from `questions[0].question`, as seen in an Antigravity transcript.
- Hermes subagents have their own session IDs, so a delegated task may show up as a separate row.
