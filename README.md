# t3-notch

Your [T3 Code](https://github.com/ytkimirti/t3code) agents, living in the MacBook notch.

<p align="center">
  <img src="docs/critters.gif" width="704" alt="Pixel critters in a black wing grown out of the notch: blue ones trot while their agents work, a grey one glances around while it waits, green ones doze once finished. Hovering the notch opens a list of the finished threads.">
</p>

A black wing grows out of the notch's left edge with one figure per agent:

- **Blue** while it works (subagents count too).
- **Grey** while it waits on another thread or on background work.
- **Green** once it finished and you haven't looked yet.

Up to ten figures show at once. Past that, every group with agents keeps at least one figure,
and a group with more than it shows adds a `+N` for the rest.

Hover the notch to list the finished threads (red: failed, amber: hit a usage limit), and click
one to open it in T3 Code. Nothing to show means no wing: the notch looks like a notch.

## Styles

`critters` (the default): pixel creatures that trot while working, stand and glance around while
waiting, and doze when done.

`equalizer`: bars that bounce while working, idle at half height while waiting, and rest short
when done.

<p align="center">
  <img src="docs/equalizer.gif" width="567" alt="The equalizer style: bouncing blue bars, a dim grey bar, and short green bars.">
</p>

## Requirements

- An Apple silicon Mac on macOS 14 or later, with the Xcode command line tools (`xcode-select --install`).
- One or more T3 Code servers the Mac can reach. Plain HTTP works for Tailscale (`*.ts.net`) names, IP
  addresses, and local hosts (`.local`); other domains need HTTPS.

No notch? With no notched display connected (say, the lid closed on an external monitor), the
wing sits as a pill at the top center of the main display's menu bar, no wider than its figures.
It hides over full-screen apps and an auto-hidden menu bar.

## Install

On each machine running a T3 server, issue a read-only token:

```sh
t3 auth session issue --scope orchestration:read --ttl 3650d --label "notch" --token-only
```

The T3 Code desktop app runs its own server on the Mac (`127.0.0.1:3773`), and its CLI lives at
`~/.t3/bin/t3`.

On the Mac, write `~/.config/t3-notch/config.json` and keep it private (`chmod 600`):

```json
{
  "servers": [
    { "url": "http://127.0.0.1:3773", "token": "<token from the Mac>" },
    { "url": "http://my-server.my-tailnet.ts.net:3773", "token": "<token from the server>" }
  ],
  "style": "critters"
}
```

Agents from every server count together. With one server, top-level `"url"` and `"token"` work
too. If a server drops, its agents keep counting for 30 seconds in case it comes right back.
`style` is optional. Use the full hostname: URLSession upgrades a bare `http://dev` to HTTPS
because `.dev` is HSTS-preloaded.

Then build, install to `~/Applications`, and run it as a LaunchAgent that starts at login:

```sh
git clone https://github.com/ytkimirti/t3-notch && cd t3-notch
./install.sh
```

Logs go to `~/Library/Logs/t3notch.log`. After editing the config, restart it:

```sh
launchctl kickstart -k gui/$(id -u)/com.kimirti.t3notch
```

To uninstall:

```sh
launchctl bootout gui/$(id -u)/com.kimirti.t3notch
rm -rf ~/Library/LaunchAgents/com.kimirti.t3notch.plist ~/Applications/t3notch.app
```

## What counts as what

The counts follow T3's default sidebar:

- **Finished**: a top-level thread showing "done" (its run ended after you last opened it), or
  one that failed since you last opened it. Settled, snoozed, archived, waiting, and approval- or
  input-blocked threads are left out.
- **Working**: the sidebar's working rule, plus subagents, since each is an agent at work.
- **Waiting**: the sidebar's "Waiting": blocked on another thread (such as a parent waiting on
  its subagents) or parked on background work it awaits. Top-level only, minus settled and
  snoozed threads.

A subagent's approval or input request rolls up to its parents, as in the sidebar, so those
threads count as neither working nor waiting.

## How it works

One WebSocket to the server's `/ws`, subscribed to `orchestration.subscribeShell` (Effect RPC,
JSON). The server sends a snapshot, then a `thread.updated` per change, so nothing polls. The
client acks each chunk, pings every 20 s, and reconnects with backoff and on wake.

The wing animations run in Core Animation, so the app does no per-frame work.

## Development

```sh
./test.sh    # status rules and wing layout
./build.sh   # build/t3notch.app
```

`build/t3notch.app/Contents/MacOS/t3notch --render <dir>` connects with your config, prints the
counts, and writes `collapsed.png`, `expanded.png`, and wing strips for each style without
opening a window.

`--demo <dir>` needs no server: it plays a scripted set of made-up agents through the real wing
layers and writes the frames. The GIFs above come from (needs `ffmpeg`):

```sh
build/t3notch.app/Contents/MacOS/t3notch --demo build/demo
for s in critters equalizer; do
  ffmpeg -framerate 25 -i build/demo/$s/frame-%04d.png \
    -vf "split[a][b];[a]palettegen[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" -loop 0 docs/$s.gif
done
```

## Credits

The notch window, shape, and hover handling follow [CodeIsland](https://github.com/wxtsky/CodeIsland)
(MIT).

## License

[MIT](LICENSE)
