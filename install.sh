#!/bin/bash
# Build and install t3notch as a LaunchAgent (RunAtLoad + KeepAlive).
# Remove with: launchctl bootout gui/$(id -u)/com.kimirti.t3notch && rm ~/Library/LaunchAgents/com.kimirti.t3notch.plist
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
# Run a copy, so a rebuild (which deletes build/) never pulls the binary out from under launchd.
APP="$HOME/Applications/t3notch.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto build/t3notch.app "$APP"
PLIST="$HOME/Library/LaunchAgents/com.kimirti.t3notch.plist"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.kimirti.t3notch</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/t3notch</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/t3notch.log</string>
</dict>
</plist>
EOF

DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/com.kimirti.t3notch"

# bootout is asynchronous. It returns as soon as launchd has accepted the
# request, not once the job is gone, and a bootstrap issued into that window
# fails with "Bootstrap failed: 5: Input/output error" — leaving NOTHING loaded,
# so a reinstall silently took t3notch down until someone noticed.
# Wait for the service to actually disappear, then retry anyway.
launchctl bootout "$SERVICE" 2>/dev/null || true
for _ in $(seq 1 50); do                      # up to 5s
    launchctl print "$SERVICE" >/dev/null 2>&1 || break
    sleep 0.1
done

bootstrapped=0
err=""
for attempt in 1 2 3 4 5; do
    if err="$(launchctl bootstrap "$DOMAIN" "$PLIST" 2>&1)"; then
        bootstrapped=1
        break
    fi
    # Already loaded is success for our purposes; anything else is worth a retry.
    if launchctl print "$SERVICE" >/dev/null 2>&1; then
        bootstrapped=1
        break
    fi
    if [ "$attempt" -lt 5 ]; then sleep 0.5; fi
done

if [ "$bootstrapped" -ne 1 ]; then
    echo "launchctl bootstrap failed after 5 attempts: $err" >&2
    echo "t3notch is NOT running; retry with: launchctl bootstrap $DOMAIN $PLIST" >&2
    exit 1
fi

# Never exit reporting success while the app is down: KeepAlive brings it back
# on a crash, but not if bootstrap left the job loaded-but-not-started.
launchctl kickstart "$SERVICE" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do                      # up to 3s
    pid="$(launchctl list | awk -v l=com.kimirti.t3notch '$3 == l { print $1 }')"
    if [ -n "$pid" ] && [ "$pid" != "-" ]; then break; fi
    sleep 0.1
done
if [ -z "${pid:-}" ] || [ "$pid" = "-" ]; then
    echo "bootstrapped but no running pid; check: launchctl print $SERVICE" >&2
    exit 1
fi

echo "installed and running (pid $pid); restart later with: launchctl kickstart -k $SERVICE"
