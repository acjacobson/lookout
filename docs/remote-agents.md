# Agents on other machines

Lookout can show sessions from agents that run on another machine, such as a server or a second computer, when both machines are on the same Tailscale network. This is off until you turn on **Other Machines > Allow Other Machines** in the gear menu.

## Which agents work

Claude Code, Codex, Cursor, Antigravity and Hermes all report from another machine. That machine can run macOS or Linux, and needs Tailscale, `curl` and `python3`. Amp needs nothing there: its threads run on Amp's servers, so the Amp watcher on the Mac already sees them.

Sessions from another machine show "on <hostname>". Clicking one marks it read but opens nothing, since its app runs on the other machine; Hermes is the exception and opens the session in the Hermes desktop app. Antigravity sessions from another machine show no last reply, since the transcript Lookout reads it from is on that machine.

## Set up a machine

1. In the gear menu, open **Other Machines** and turn on **Allow Other Machines**. Make sure Tailscale is running on both machines. The submenu shows "Reachable over Tailscale at 100.x.y.z" once Lookout is listening.
2. Choose **Set Up a Machine…**. This copies a setup command.
3. Paste the command into a terminal on the other machine, for example over SSH. It downloads the reporter to `~/.lookout/bin`, writes the address and token to `~/.lookout/remote.env`, and installs hooks for each agent it finds there.
4. Restart Hermes on that machine, if it runs there. If Codex runs there, trust its new hooks: run `/hooks` in the Codex CLI and approve the Lookout entries.

To add an agent later, run `python3 ~/.lookout/lookout-hooks.py install <agent>` on that machine.

## Remove a machine

- **One machine:** choose **Remove a Machine…**, which copies a removal command, and paste it into a terminal on that machine. It removes Lookout's hooks from every agent there and deletes `~/.lookout`.
- **Every machine at once:** choose **Disconnect All Machines…**. Lookout replaces its token, so it stops accepting sessions from every machine set up so far. Their hooks stay in place and keep trying without effect, until you remove them or set the machine up again.
- **Stop listening:** turn off **Allow Other Machines**. Machines stay set up and report again once you turn it back on.

## Hermes in Docker

When Hermes runs in a container, its hooks run inside the container, which can't see `~/.lookout` on the host. Run the installer on the host with the host folder that is mounted as the Hermes home, and the path Hermes sees for that folder inside the container:

```bash
python3 ~/.lookout/lookout-hooks.py install hermes --hermes-home /srv/hermes/data --container-home /opt/data
```

This copies the reporter and `remote.env` into `<hermes-home>/lookout`, and points the hooks at the path inside the container. The container needs `curl`. If the installer can't find a Hermes home, it lists the folders that look like one.

To remove it, run the same command with `uninstall hermes` and the same `--hermes-home`. The removal command from the menu doesn't cover a Hermes home in another folder.

## How it works

Hooks on another machine can't write to this Mac's inbox, so Lookout also runs a small HTTP server for them. It binds only to this Mac's Tailscale address (100.64.0.0/10), on port 47821, so it can't be reached from the local network or from localhost.

- `POST /event` takes the same data `lookout-report` would write to the inbox. It requires `Authorization: Bearer <token>`.
- `GET /reporter` and `GET /installer` serve `lookout-report` and `lookout-hooks.py` for setting up the other machine. Neither contains the token.

The port and token are in `~/.lookout/config.json`, created with a random token on first launch. **Allow Other Machines** sets `"enabled"` there, and **Disconnect All Machines** replaces the token.

When `~/.lookout/remote.env` exists, `lookout-report` posts each event in the background with a 3-second limit instead of writing a file. If the Mac is asleep or unreachable, the event is dropped.
