# Lookout

A macOS menu bar app that shows which AI agent sessions need a decision or have finished and are waiting to be read, and opens the app the session runs in when you click one. It supports Claude Code, Codex, Hermes, Amp, Antigravity and Cursor.

## How it works

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

## Build

```bash
./scripts/build-app.sh
```

This builds `build/Lookout.app`. It signs the app with the first valid Apple Development certificate in your keychain, chosen by hash because expired certificates can have the same name. Set `LOOKOUT_SIGN_IDENTITY` to use another identity. Without a certificate it signs ad hoc, and macOS then refuses notifications ("Notifications are not allowed for this application") without asking. To create a certificate, open Xcode > Settings > Accounts > Manage Certificates and add an Apple Development certificate.

Install it to `/Applications`, then turn on "Launch at Login" from the gear menu in the panel:

```bash
rm -rf /Applications/Lookout.app && cp -R build/Lookout.app /Applications/ && open /Applications/Lookout.app
```

macOS remembers a notification refusal by bundle ID. The bundle ID is `dev.lookout.Lookout`; the earlier `local.lookout.Lookout` was refused while the app was signed ad hoc.

## Install the hooks

```bash
python3 scripts/lookout-hooks.py install
```

This copies the reporter to `~/.lookout/bin` and adds hooks for all six agents. Name agents to install only some of them, for example `install claude codex`. Each file is backed up to `~/.lookout/backups` first, and existing hooks are kept.

- **Claude Code:** adds entries to `~/.claude/settings.json`. New sessions pick them up.
- **Codex:** adds entries to `~/.codex/hooks.json`. Codex skips new hooks until you trust them: run `/hooks` in the Codex CLI, or open Settings > Hooks in the ChatGPT app.
- **Hermes:** appends a marked `hooks:` block to `~/.hermes/config.yaml` and approves those commands in `~/.hermes/shell-hooks-allowlist.json`. If the config already has a `hooks:` section, the script prints the entries to add by hand instead.
- **Amp:** copies `integrations/amp/lookout.ts` to `~/.config/amp/plugins/`.
- **Cursor:** adds entries to `~/.cursor/hooks.json`. Cursor reloads the file on its own; the hooks are listed under Settings > Hooks. User hooks don't run in Cursor's cloud agents.
- **Antigravity:** adds a hook named `lookout` to `~/.gemini/config/hooks.json`, which the Antigravity app, the IDE and the CLI all read. New conversations pick it up; restart the app or IDE if they don't.

```bash
python3 scripts/lookout-hooks.py status
```

```bash
python3 scripts/lookout-hooks.py uninstall
```

## Agents on another machine

Hooks on another machine can't write to this Mac's inbox, so Lookout also runs a small HTTP server for them. It binds only to this Mac's Tailscale address (100.64.0.0/10), on port 47821, so it can't be reached from the local network or from localhost.

- `POST /event` takes the same data `lookout-report` would write to the inbox. It requires `Authorization: Bearer <token>`.
- `GET /reporter` and `GET /installer` serve `lookout-report` and `lookout-hooks.py` for setting up the other machine. Neither contains the token.

The port and token are in `~/.lookout/config.json`, created with a random token on first launch. Set `"enabled": false` there to turn the server off. Delete the file and restart Lookout to get a new token.

To set up another machine:

1. In the Lookout menu, choose **Copy Setup Command for Another Machine**.
2. Paste the command into a shell on that machine. It downloads the reporter to `~/.lookout/bin`, writes the URL and token to `~/.lookout/remote.env`, and installs the Hermes hooks there. To install hooks for other agents on that machine, run `python3 ~/.lookout/lookout-hooks.py install <agent>` afterwards.
3. Restart Hermes on that machine so it loads the new hooks.

When `~/.lookout/remote.env` exists, `lookout-report` posts each event in the background with a 3-second limit instead of writing a file. If the Mac is asleep or unreachable, the event is dropped. Rows from another machine show "on <hostname>".

## Not verified yet

- `amp top --stream-jsonl` is marked experimental by Amp, so its output may change.
- The arguments of Antigravity's `ask_question` tool aren't documented. Lookout looks for a `question` field and otherwise shows the tool name.
- Hermes subagents have their own session IDs, so a delegated task may show up as a separate row.
