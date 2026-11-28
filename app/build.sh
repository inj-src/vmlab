#!/bin/bash
# build.sh: build the vmlab app (target/release/vmlab), the window the vmlab launcher opens.
# Rune, the UI library it is written with, is not in this repository (app/rune is ignored):
# the first run fetches it, at the commit Cargo.lock was made with, without its demo videos
# and pictures (about 100 MB instead of a few GB). Delete app/rune to fetch it again.
set -euo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
rune_url=https://github.com/anomalyco/rune
rune_rev=af6b1fdd9537a3f278f9c85e0f0893f1e773302a

if [[ ! -d $here/rune/.git ]]; then
  git clone --filter=blob:none --no-checkout --branch dev "$rune_url" "$here/rune"
  # The cursor pictures stay: Rune builds them into itself.
  git -C "$here/rune" sparse-checkout set --no-cone '/*' '!/demo/' '!*.mp4' '!*.png' '!*.jpg' \
    '!*.gif' '!*.webm' '/crates/rune/src/input/cursor/*.png'
fi
if [[ $(git -C "$here/rune" rev-parse HEAD 2>/dev/null) != "$rune_rev" ]]; then
  git -C "$here/rune" fetch --filter=blob:none origin "$rune_rev" 2>/dev/null || true
  git -C "$here/rune" checkout --quiet "$rune_rev"
fi

cd "$here"
cargo build --release
echo "built $here/target/release/vmlab"
