# Agents on other machines

Lookout can show sessions from agents that run on another machine, such as a server or a second computer, when both machines are on the same Tailscale network. This is off until you turn on **Agents on Other Machines** in the gear menu.

Hooks on another machine can't write to this Mac's inbox, so Lookout also runs a small HTTP server for them. It binds only to this Mac's Tailscale address (100.64.0.0/10), on port 47821, so it can't be reached from the local network or from localhost.

- `POST /event` takes the same data `lookout-report` would write to the inbox. It requires `Authorization: Bearer <token>`.
- `GET /reporter` and `GET /installer` serve `lookout-report` and `lookout-hooks.py` for setting up the other machine. Neither contains the token.

The port and token are in `~/.lookout/config.json`, created with a random token on first launch. The **Agents on Other Machines** toggle sets `"enabled"` there. To get a new token, quit Lookout, delete the file, and open Lookout again; then set up the other machines again.

To set up another machine:

1. Turn on **Agents on Other Machines** in the gear menu, and make sure Tailscale is running on both machines. The gear menu shows "Listening on http://100.x.y.z:47821" once Lookout is listening.
2. In the gear menu, choose **Copy Setup Command for Another Machine**.
3. Paste the command into a shell on the other machine. It needs `curl` and `python3`. It downloads the reporter to `~/.lookout/bin`, writes the URL and token to `~/.lookout/remote.env`, and installs hooks for each agent it finds there.
4. Restart Hermes on that machine, if it runs there, so it loads the new hooks. If Codex runs there, trust its new hooks: run `/hooks` in the Codex CLI and approve the Lookout entries.

To add an agent later, run `python3 ~/.lookout/lookout-hooks.py install <agent>` on that machine. Amp needs nothing there: its threads run on Amp's servers, so the Amp watcher on the Mac already sees them.

### Hermes in Docker

When Hermes runs in a container, its hooks run inside the container, which can't see `~/.lookout` on the host. Run the installer on the host with the host folder that is mounted as the Hermes home, and the path Hermes sees for that folder inside the container:

```bash
python3 ~/.lookout/lookout-hooks.py install hermes --hermes-home /srv/hermes/data --container-home /opt/data
```

This copies the reporter and `remote.env` into `<hermes-home>/lookout`, and points the hooks at the path inside the container. The container needs `curl`. If the installer can't find a Hermes home, it lists the folders that look like one.

When `~/.lookout/remote.env` exists, `lookout-report` posts each event in the background with a 3-second limit instead of writing a file. If the Mac is asleep or unreachable, the event is dropped. Rows from another machine show "on <hostname>". Antigravity rows from another machine show no last reply, since the transcript Lookout reads it from is on that machine.
