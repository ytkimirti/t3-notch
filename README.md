# t3-notch

Shows [T3 Code](https://github.com/ytkimirti/t3code) agent activity in the MacBook notch.
The black wing grown out of the notch's left edge shows how many agents are working
(blue spinner) and how many finished since you last looked (green check). Hover the notch
to list the finished ones; click one to open that thread in T3 Code.

"Working" and "finished" follow T3's own sidebar: a thread counts as working while its run is
preparing, queued, starting, running, or waiting (not when it is only blocked on child threads),
and as finished when its latest run completed or failed after you last opened it.

The notch window, shape, and hover handling follow [CodeIsland](https://github.com/wxtsky/CodeIsland).

## Setup

On the machine running the T3 server, issue a read-only token:

```sh
t3 auth session issue --scope orchestration:read --ttl 3650d --label "notch" --token-only
```

On the Mac, write `~/.config/t3-notch/config.json` (mode 600):

```json
{ "url": "http://dev.tail1c1140.ts.net:3773", "token": "<token>" }
```

Use a full hostname: URLSession upgrades `http://dev` to HTTPS because `.dev` is HSTS-preloaded.

Then `./install.sh` builds the app and runs it as a LaunchAgent. Logs go to `~/Library/Logs/t3notch.log`.

## How it works

One WebSocket to the server's `/ws`, subscribed to `orchestration.subscribeShell` (Effect RPC,
JSON). The server sends a snapshot, then a `thread.updated` per change, so nothing polls. The
client acks each chunk, pings every 20 s, and reconnects with backoff and on wake.

`build/t3notch.app/Contents/MacOS/t3notch --render <dir>` connects, prints the counts, and writes
`collapsed.png` and `expanded.png` without opening a window.
