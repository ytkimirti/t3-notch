#!/bin/bash
# Dev-side helper: push sources to a Mac, then test and build there.
# Usage: MAC=user@host [MAC_KEY=~/.ssh/key] [MAC_DIR=proj/js/t3-notch] ./sync-build.sh
# MAC_DIR is relative to the remote home, or absolute.
set -euo pipefail
cd "$(dirname "$0")"
HOST="${MAC:?set MAC=user@host}"
DIR="${MAC_DIR:-proj/js/t3-notch}"
DIR="${DIR#\~/}"
SSH=(ssh -o BatchMode=yes)
RSH="ssh -o BatchMode=yes" # rsync splits -e itself and honours quotes, not backslashes
if [ -n "${MAC_KEY:-}" ]; then
  SSH+=(-i "$MAC_KEY" -o IdentitiesOnly=yes)
  RSH+=" -i '$MAC_KEY' -o IdentitiesOnly=yes"
fi
# rsync --delete empties the target of anything else, so only sync into a checkout or a new dir.
printf 'd=%q\n[ ! -e "$d" ] || [ -e "$d/build.sh" ] || [ -z "$(ls -A "$d")" ] && mkdir -p "$d"\n' "$DIR" |
  "${SSH[@]}" "$HOST" bash -s || { echo "refusing to sync into $HOST:$DIR: not empty and not a t3-notch checkout" >&2; exit 1; }
rsync -a --delete --exclude .git --exclude build --exclude .probe --exclude .claude --exclude docs -e "$RSH" ./ "$HOST:$DIR/"
"${SSH[@]}" "$HOST" "bash -lc \"cd '$DIR' && ./test.sh && ./build.sh\""
