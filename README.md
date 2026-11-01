# t3-notch

Shows [T3 Code](https://github.com/ytkimirti/t3code) agent activity in the MacBook notch.
The black wing grown out of the notch's left edge shows one figure per agent: blue while it works,
green once it finished and you haven't looked yet. Past a few of each, a `+N` counts the rest.
Two styles: `critters` (default), pixel creatures that trot while working and doze when done, and
`equalizer`, bars that bounce while working and rest short when done. Hover the notch
to list the finished ones (red: failed, amber: hit a usage limit); click one to open that thread
in T3 Code. With no notched display (lid closed), it stays hidden.

"Finished" follows T3's default sidebar: a top-level thread showing "done" (its run ended after
you last opened it), or one that failed since you last opened it. Settled, snoozed, archived,
waiting, and approval- or input-blocked threads are left out. "Working" uses the sidebar's working
rule but also counts subagents, since each is an agent at work; a parent blocked on its subagents
is not counted.

The notch window, shape, and hover handling follow [CodeIsland](https://github.com/wxtsky/CodeIsland).

## Setup

On the machine running the T3 server, issue a read-only token:

```sh
t3 auth session issue --scope orchestration:read --ttl 3650d --label "notch" --token-only
```

On the Mac, write `~/.config/t3-notch/config.json` (mode 600):

```json
{ "url": "http://dev.tail1c1140.ts.net:3773", "token": "<token>", "style": "critters" }
```

`style` is optional: `critters` or `equalizer`. Restart to apply (`launchctl kickstart -k gui/$(id -u)/com.kimirti.t3notch`).

Use a full hostname: URLSession upgrades `http://dev` to HTTPS because `.dev` is HSTS-preloaded.

Then `./install.sh` builds the app, copies it to `~/Applications`, and runs it as a LaunchAgent. Logs go to `~/Library/Logs/t3notch.log`.

## How it works

One WebSocket to the server's `/ws`, subscribed to `orchestration.subscribeShell` (Effect RPC,
JSON). The server sends a snapshot, then a `thread.updated` per change, so nothing polls. The
client acks each chunk, pings every 20 s, and reconnects with backoff and on wake.

`build/t3notch.app/Contents/MacOS/t3notch --render <dir>` connects, prints the counts, and writes
`collapsed.png`, `expanded.png`, and `wing-<style>-<running>-<done>.png` for each style without
opening a window. The wing animations run in Core Animation, so the app does no per-frame work;
the PNGs show their resting frame.
