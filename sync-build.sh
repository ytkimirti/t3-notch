#!/bin/bash
# Dev-side helper: push sources to the Mac and build there.
set -euo pipefail
cd "$(dirname "$0")"
KEY="$HOME/.ssh/id_ed25519_mac"; HOST=kimirti@100.105.175.41
rsync -a --delete --exclude .git --exclude build --exclude .probe -e "ssh -i $KEY" ./ "$HOST:proj/js/t3-notch/"
ssh -i "$KEY" "$HOST" 'bash -lc "cd ~/proj/js/t3-notch && ./test.sh && ./build.sh"'
