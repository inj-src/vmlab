#!/usr/bin/env bash
# build.sh [HOST]: builds vmlab-display.exe in the Windows VM and puts it in ../guest-bin/, where
# win-venus.sh's scale-watch looks for it (without it scale-watch runs the PowerShell scripts).
# HOST: an ssh host for the VM, `win` by default (~/.config/vmlab/ssh_config: Git Bash on the
# desktop). The VM must be running (vm start win).
#
# The host has the x86_64-pc-windows-msvc target, so `cargo check --target
# x86_64-pc-windows-msvc` works here, but not MSVC's libraries, so the link has to happen in
# Windows. The source goes to C:\cache\src\vmlab-display (the build cache disk: its target\
# outlives vm reset, so a rebuild is incremental) as a tar over SSH: three files, where
# `vm push` would mirror the whole lab repository.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HOST=${1:-win}
DEST=/c/cache/src/vmlab-display          # Git Bash's name for it
OUT=$HERE/../guest-bin/vmlab-display.exe

ssh "$HOST" true 2>/dev/null || { echo "build.sh: no SSH to $HOST (vm start win?)" >&2; exit 1; }
echo "sending the source to $HOST:C:/cache/src/vmlab-display"
tar -C "$HERE" -cf - Cargo.toml Cargo.lock src |
  ssh "$HOST" "mkdir -p $DEST && rm -rf $DEST/src && tar -xf - -C $DEST"
# --target-dir: the crate's own target\, whatever CARGO_TARGET_DIR the VM may have
ssh "$HOST" "cd $DEST && cargo build --release --locked --target-dir target"
mkdir -p "$(dirname "$OUT")"
scp -q "$HOST:C:/cache/src/vmlab-display/target/release/vmlab-display.exe" "$OUT.new"
mv -f "$OUT.new" "$OUT"     # in one step: scale-watch may be copying it to the VM
echo "$OUT: $(stat -c %s "$OUT") bytes, sha256 $(sha256sum "$OUT" | cut -d' ' -f1)"
