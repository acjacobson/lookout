#!/usr/bin/env python3
"""Install or remove Lookout's hooks in Claude Code, Codex, Hermes, Amp, Antigravity and Cursor.

    python3 scripts/lookout-hooks.py install   [claude codex hermes amp antigravity cursor]
    python3 scripts/lookout-hooks.py uninstall [claude codex hermes amp antigravity cursor]
    python3 scripts/lookout-hooks.py status

For Hermes in another folder, or in Docker:

    python3 scripts/lookout-hooks.py install hermes --hermes-home /home/me/.hermes \\
        --container-home /opt/data

With no agent names, install handles every agent found on this machine (its
config folder or app exists), and uninstall handles every agent. Each file is backed up to
~/.lookout/backups before it changes. Hooks already in a file are kept: Lookout
only adds entries whose command starts with its reporter path, and uninstall
only removes those.
"""
import json
import os
import shutil
import sys
import time
from pathlib import Path

HOME = Path.home()
REPO = Path(__file__).resolve().parent.parent
LOOKOUT = Path(os.environ.get("LOOKOUT_HOME", HOME / ".lookout"))
REPORTER = LOOKOUT / "bin" / "lookout-report"
BACKUPS = LOOKOUT / "backups"

CLAUDE_SETTINGS = HOME / ".claude" / "settings.json"
CODEX_HOOKS = HOME / ".codex" / "hooks.json"
HERMES_CONFIG = HOME / ".hermes" / "config.yaml"
HERMES_ALLOWLIST = HOME / ".hermes" / "shell-hooks-allowlist.json"
AMP_PLUGIN = HOME / ".config" / "amp" / "plugins" / "lookout.ts"
# Read by the Antigravity app, the Antigravity IDE and the Antigravity CLI.
ANTIGRAVITY_HOOKS = HOME / ".gemini" / "config" / "hooks.json"
ANTIGRAVITY_NAME = "lookout"
# Read by the Cursor app; user hooks don't run in Cursor's cloud agents.
CURSOR_HOOKS = HOME / ".cursor" / "hooks.json"

# (native event, Lookout state, matcher or None)
CLAUDE_EVENTS = [
    ("UserPromptSubmit", "prompt", None),
    ("PostToolUse", "working", None),
    ("PreToolUse", "needs", "AskUserQuestion"),
    ("PermissionRequest", "needs", None),
    ("Notification", "needs", "permission_prompt|elicitation_dialog"),
    ("Stop", "done", None),
    ("SessionEnd", "end", None),
]
CODEX_EVENTS = [
    ("UserPromptSubmit", "prompt", None),
    ("PostToolUse", "working", None),
    ("PermissionRequest", "needs", None),
    ("Stop", "done", None),
    ("SessionEnd", "end", None),
]
HERMES_EVENTS = [
    ("pre_llm_call", "prompt"),
    ("on_human_input_request", "needs"),
    ("on_human_input_resolved", "working"),
    ("on_session_end", "done"),
    ("on_session_finalize", "end"),
]
# (native event, Lookout state, matcher or None, JSON the hook prints)
# Antigravity requires a "decision" from PreToolUse and Stop hooks. "allow" leaves
# the tool to the normal permission rules, and any Stop decision other than
# "continue" lets the agent stop, so neither changes what the agent does.
ANTIGRAVITY_EVENTS = [
    ("PreInvocation", "prompt", None, "{}"),
    ("PreToolUse", "needs", "^ask_question$", '{"decision":"allow"}'),
    ("PostToolUse", "working", "^ask_question$", "{}"),
    ("Stop", "done", None, '{"decision":"stop"}'),
]
# (native event, Lookout state, JSON the hook prints)
# Cursor treats output it can't parse as a refusal for some events, so every hook
# prints a valid reply: beforeSubmitPrompt must allow the prompt, the rest take {}.
# afterAgentResponse carries the agent's message, which Lookout keeps for the
# "done" row, since Cursor's stop event has no text.
CURSOR_EVENTS = [
    ("beforeSubmitPrompt", "prompt", '{"continue":true}'),
    ("afterAgentResponse", "reply", "{}"),
    ("stop", "done", "{}"),
    ("sessionEnd", "end", "{}"),
]
HERMES_BEGIN = "# >>> lookout hooks (managed by lookout-hooks.py; remove this block to uninstall)"
HERMES_END = "# <<< lookout hooks"


def command(agent, state, reporter=None):
    return f"{reporter or REPORTER} {agent} {state}"


def ours(cmd):
    # Any Lookout reporter, wherever it was installed (~/.lookout or a Hermes home).
    return isinstance(cmd, str) and ("/lookout-report " in cmd or cmd.startswith(str(REPORTER)))


def backup(path):
    if not path.exists():
        return
    BACKUPS.mkdir(parents=True, exist_ok=True)
    dest = BACKUPS / f"{path.name}.{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, dest)
    print(f"  backup: {dest}")


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".lookout-tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def install_reporter():
    REPORTER.parent.mkdir(parents=True, exist_ok=True)
    (LOOKOUT / "inbox").mkdir(parents=True, exist_ok=True)
    source = REPO / "scripts" / "lookout-report"
    if source.exists():
        shutil.copy2(source, REPORTER)
    elif not REPORTER.exists():
        # Running on another machine from a downloaded copy of this script.
        sys.exit(f"no reporter at {REPORTER}; download it from Lookout's /reporter first")
    REPORTER.chmod(0o755)
    remote = (LOOKOUT / "remote.env").exists()
    print(f"reporter: {REPORTER}" + (" (posting to a remote Lookout, see remote.env)" if remote else ""))


# --- Claude Code and Codex share the same hooks.json layout -----------------

def strip_ours(hooks):
    """Remove Lookout handlers from a {event: [groups]} dict, in place."""
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept = []
        for g in groups:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                g["hooks"] = [h for h in g["hooks"] if not (isinstance(h, dict) and ours(h.get("command")))]
                if not g["hooks"]:
                    continue
            kept.append(g)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]


def add_ours(hooks, agent, events, timeout):
    for event, state, matcher in events:
        group = {"hooks": [{"type": "command", "command": command(agent, state), "timeout": timeout}]}
        if matcher:
            group = {"matcher": matcher, **group}
        hooks.setdefault(event, []).append(group)


def hooks_file(path, agent, events, timeout, install):
    if not install and not path.exists():
        print(f"  nothing to remove: {path} not found")
        return False
    data = {}
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8") or "{}")
        except json.JSONDecodeError as e:
            print(f"  skipped: {path} is not valid JSON ({e})")
            return False
    hooks = data.get("hooks")
    if hooks is None:
        hooks = {}
    if not isinstance(hooks, dict):
        print(f"  skipped: 'hooks' in {path} is not an object")
        return False
    backup(path)
    strip_ours(hooks)
    if install:
        add_ours(hooks, agent, events, timeout)
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    write_json(path, data)
    print(f"  {'installed' if install else 'removed'}: {path}")
    return True


def claude(install):
    print("Claude Code")
    hooks_file(CLAUDE_SETTINGS, "claude", CLAUDE_EVENTS, 5, install)
    if install:
        print("  New Claude Code sessions pick this up; sessions already open may need a restart.")


def codex(install):
    print("Codex")
    if not hooks_file(CODEX_HOOKS, "codex", CODEX_EVENTS, 3, install):
        return
    if install:
        print("  Codex runs new hooks only after you trust them: run /hooks in the Codex CLI,")
        print("  or open Settings > Hooks in the ChatGPT app, and approve the Lookout entries.")


# --- Hermes: a marked block in config.yaml plus allowlist entries ---------

HERMES_OPTS = {"home": None, "container_home": None}


def match_owner(reference, *paths):
    """Give new files the owner of `reference`. Hermes in Docker runs as its own
    user (uid 10000), which can't read root-owned 0600 files."""
    if os.geteuid() != 0:
        return
    st = reference.stat()
    targets = paths or (reference,)
    for p in targets:
        if Path(p).exists():
            os.chown(p, st.st_uid, st.st_gid)


def hermes_candidates():
    """Folders that look like a Hermes home on this machine."""
    found = []
    env = os.environ.get("HERMES_HOME")
    patterns = [env] if env else []
    patterns += [str(HOME / ".hermes"), "/opt/data", "/root/.hermes"]
    patterns += [str(p) for p in Path("/home").glob("*/.hermes")] if Path("/home").exists() else []
    patterns += [str(p) for p in Path("/Users").glob("*/.hermes")] if Path("/Users").exists() else []
    for p in patterns:
        if p and (Path(p) / "config.yaml").exists() and str(Path(p).resolve()) not in found:
            found.append(str(Path(p).resolve()))
    return found


def hermes(install):
    print("Hermes")
    global HERMES_CONFIG, HERMES_ALLOWLIST
    home = HERMES_OPTS["home"] or os.environ.get("HERMES_HOME")
    reporter = None
    if home:
        home = Path(home).expanduser()
        HERMES_CONFIG = home / "config.yaml"
        HERMES_ALLOWLIST = home / "shell-hooks-allowlist.json"
    if not HERMES_CONFIG.exists():
        print(f"  skipped: {HERMES_CONFIG} not found")
        found = hermes_candidates()
        if found:
            print("  Hermes homes found on this machine; rerun with one of them:")
            for f in found:
                print(f"    python3 {sys.argv[0]} {'install' if install else 'uninstall'} hermes --hermes-home {f}")
        if install:
            print("  If Hermes runs in Docker, also pass --container-home /opt/data (its HERMES_HOME inside the container).")
        return
    if home and install:
        # Put the reporter and remote.env inside the Hermes home, so a container that
        # mounts only that folder can still run them.
        inside = home / "lookout"
        (inside / "bin").mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPORTER, inside / "bin" / "lookout-report")
        (inside / "bin" / "lookout-report").chmod(0o755)
        if (LOOKOUT / "remote.env").exists():
            shutil.copy2(LOOKOUT / "remote.env", inside / "remote.env")
            (inside / "remote.env").chmod(0o600)
        match_owner(HERMES_CONFIG, inside, inside / "bin", inside / "bin" / "lookout-report", inside / "remote.env")
        seen_as = Path(HERMES_OPTS["container_home"] or home)
        reporter = seen_as / "lookout" / "bin" / "lookout-report"
        print(f"  reporter for Hermes: {inside / 'bin' / 'lookout-report'} (Hermes runs it as {reporter})")
    text = HERMES_CONFIG.read_text(encoding="utf-8")
    start, end = text.find(HERMES_BEGIN), text.find(HERMES_END)
    if start != -1 and end != -1:
        text = text[:start].rstrip("\n") + "\n" + text[end + len(HERMES_END):].lstrip("\n")
    if install:
        if any(line.startswith("hooks:") for line in text.splitlines()):
            print("  skipped: config.yaml already has a 'hooks:' section. Add these entries to it by hand:")
            for event, state in HERMES_EVENTS:
                print(f"    {event}: - command: \"{command('hermes', state, reporter)}\"")
            return
        lines = ["", HERMES_BEGIN, "hooks:"]
        for event, state in HERMES_EVENTS:
            lines += [f"  {event}:", f"    - command: \"{command('hermes', state, reporter)}\"", "      timeout: 5"]
        lines.append(HERMES_END)
        text = text.rstrip("\n") + "\n" + "\n".join(lines) + "\n"
    backup(HERMES_CONFIG)
    HERMES_CONFIG.write_text(text, encoding="utf-8")
    hermes_allowlist(install, reporter)
    match_owner(HERMES_CONFIG)
    print(f"  {'installed' if install else 'removed'}: {HERMES_CONFIG}")


def hermes_allowlist(install, reporter=None):
    data = {"approvals": []}
    if HERMES_ALLOWLIST.exists():
        try:
            data = json.loads(HERMES_ALLOWLIST.read_text(encoding="utf-8-sig"))
        except json.JSONDecodeError:
            pass
        backup(HERMES_ALLOWLIST)
    approvals = [a for a in data.get("approvals", []) if not (isinstance(a, dict) and ours(a.get("command")))]
    if install:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for event, state in HERMES_EVENTS:
            approvals.append({"event": event, "command": command("hermes", state, reporter), "approved_at": stamp})
    data["approvals"] = approvals
    write_json(HERMES_ALLOWLIST, data)
    HERMES_ALLOWLIST.chmod(0o600)
    match_owner(HERMES_CONFIG, HERMES_ALLOWLIST)


# --- Amp: a plugin file ---------------------------------------------------

def amp(install):
    print("Amp")
    source = REPO / "integrations" / "amp" / "lookout.ts"
    if install and not source.exists():
        # A downloaded copy of this script, on another machine. Amp threads run on
        # Amp's servers, so the Mac running Lookout already sees them through amp top.
        print("  skipped: the Amp plugin isn't needed here; Lookout on the Mac sees all your Amp threads")
        return
    if install:
        AMP_PLUGIN.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, AMP_PLUGIN)
        print(f"  installed: {AMP_PLUGIN}")
    elif AMP_PLUGIN.exists():
        AMP_PLUGIN.unlink()
        print(f"  removed: {AMP_PLUGIN}")
    else:
        print(f"  nothing to remove: {AMP_PLUGIN} not found")


# --- Antigravity: a named entry in ~/.gemini/config/hooks.json ------------

def antigravity(install):
    print("Antigravity")
    path = ANTIGRAVITY_HOOKS
    if not install and not path.exists():
        print(f"  nothing to remove: {path} not found")
        return
    data = {}
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8") or "{}")
        except json.JSONDecodeError as e:
            print(f"  skipped: {path} is not valid JSON ({e})")
            return
        if not isinstance(data, dict):
            print(f"  skipped: {path} is not a JSON object")
            return
    backup(path)
    data.pop(ANTIGRAVITY_NAME, None)
    if install:
        events = {}
        for event, state, matcher, reply in ANTIGRAVITY_EVENTS:
            # The reporter prints nothing, so the reply comes from printf after it.
            handler = {"type": "command", "command": f"{command('antigravity', state)}; printf '%s\\n' '{reply}'",
                       "timeout": 5}
            if event in ("PreToolUse", "PostToolUse"):
                events.setdefault(event, []).append({"matcher": matcher or "*", "hooks": [handler]})
            else:
                # The other events take a list of handlers, with no matcher.
                events.setdefault(event, []).append(handler)
        data[ANTIGRAVITY_NAME] = events
    write_json(path, data)
    print(f"  {'installed' if install else 'removed'}: {path} (hook \"{ANTIGRAVITY_NAME}\")")
    if install:
        print("  New Antigravity conversations pick this up; restart the app or IDE if they don't.")


# --- Cursor: {"version": 1, "hooks": {event: [handlers]}} ----------------

def cursor(install):
    print("Cursor")
    path = CURSOR_HOOKS
    if not install and not path.exists():
        print(f"  nothing to remove: {path} not found")
        return
    data = {"version": 1}
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8") or "{}")
        except json.JSONDecodeError as e:
            print(f"  skipped: {path} is not valid JSON ({e})")
            return
    hooks = data.get("hooks") if isinstance(data, dict) else None
    if hooks is None:
        hooks = {}
    if not isinstance(data, dict) or not isinstance(hooks, dict):
        print(f"  skipped: {path} doesn't have the expected layout")
        return
    backup(path)
    for event in list(hooks):
        if isinstance(hooks[event], list):
            hooks[event] = [h for h in hooks[event] if not (isinstance(h, dict) and ours(h.get("command")))]
            if not hooks[event]:
                del hooks[event]
    if install:
        for event, state, reply in CURSOR_EVENTS:
            # The reporter prints nothing, so the reply comes from printf after it.
            hooks.setdefault(event, []).append(
                {"command": f"{command('cursor', state)}; printf '%s\\n' '{reply}'", "timeout": 5})
    data.setdefault("version", 1)
    data["hooks"] = hooks
    write_json(path, data)
    print(f"  {'installed' if install else 'removed'}: {path}")
    if install:
        print("  Cursor reloads this file on its own; restart Cursor if the hooks don't show")
        print("  under Settings > Hooks.")


def status():
    print(f"reporter: {REPORTER} ({'present' if REPORTER.exists() else 'missing'})")
    for name, path in [("claude", CLAUDE_SETTINGS), ("codex", CODEX_HOOKS),
                       ("hermes", HERMES_CONFIG), ("amp", AMP_PLUGIN),
                       ("antigravity", ANTIGRAVITY_HOOKS), ("cursor", CURSOR_HOOKS)]:
        if name == "amp":
            installed = path.exists()  # the plugin builds the reporter path from $HOME
        else:
            installed = path.exists() and str(REPORTER) in path.read_text(encoding="utf-8", errors="replace")
        print(f"{name:11} {'installed' if installed else 'not installed'}  {path}")


def found(name):
    """Whether the agent appears to be installed on this machine."""
    if name == "claude":
        return (HOME / ".claude").exists()
    if name == "codex":
        return (HOME / ".codex").exists()
    if name == "hermes":
        return bool(HERMES_OPTS["home"] or os.environ.get("HERMES_HOME") or HERMES_CONFIG.exists()
                    or hermes_candidates())
    if name == "amp":
        return ((HOME / ".config" / "amp").exists() or (HOME / ".amp").exists()
                or shutil.which("amp") is not None)
    if name == "antigravity":
        return any((HOME / ".gemini").glob("antigravity*")) or ANTIGRAVITY_HOOKS.exists()
    if name == "cursor":
        return (HOME / ".cursor").exists()
    return False


AGENTS = {"claude": claude, "codex": codex, "hermes": hermes, "amp": amp, "antigravity": antigravity, "cursor": cursor}


def main(argv):
    if not argv or argv[0] not in ("install", "uninstall", "status"):
        print(__doc__)
        return 1
    if argv[0] == "status":
        status()
        return 0
    args = list(argv[1:])
    for flag, key in (("--hermes-home", "home"), ("--container-home", "container_home")):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                print(f"{flag} needs a folder")
                return 1
            HERMES_OPTS[key] = args[i + 1]
            del args[i:i + 2]
    install = argv[0] == "install"
    if args:
        names = args
    elif install:
        names = [n for n in AGENTS if found(n)]
        missing = [n for n in AGENTS if n not in names]
        if missing:
            print(f"not found on this machine, skipped: {', '.join(missing)}")
        if not names:
            print("no supported agents found; name one to install it anyway")
            return 1
    else:
        names = list(AGENTS)
    unknown = [n for n in names if n not in AGENTS]
    if unknown:
        print(f"unknown agent(s): {', '.join(unknown)}")
        return 1
    if install:
        install_reporter()
    for n in names:
        AGENTS[n](install)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
