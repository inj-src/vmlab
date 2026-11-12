#!/bin/bash
# vmlab: the build cache disk in the Mac guest, at ~/cache. Run over SSH as dev, then
# `vm commit mac`. Idempotent.
# The disk is the launcher's second one (mac26.sh, VMLAB_CACHE), which `vm reset` and `vm
# commit` leave alone. ~/cache/src is where `vm push` puts repositories, so a checkout and its
# build output outlive a reset; cargo's downloads (registry, git) are kept there too, through
# links from ~/.cargo.
set -euo pipefail

if [[ ! -d /Volumes/cache ]]; then
  # The blank one: 25 GiB and no partitions
  disk=
  for d in $(diskutil list physical | awk '/^\/dev\/disk/{print $1}'); do
    size=$(diskutil info "$d" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes).*/\1/p')
    parts=$(diskutil list "$d" | grep -c '^ *[1-9][0-9]*:' || true)
    [[ $size == 26843545600 && $parts == 0 ]] && disk=$d
  done
  [[ -n $disk ]] || { echo "no blank 25 GB disk: was the VM started with VMLAB_CACHE=off?" >&2; exit 1; }
  diskutil eraseDisk APFS cache GPT "$disk"
fi
# Build output is thousands of files Spotlight has no use for. The marker file is what lasts:
# mdutil's setting alone was back to "enabled" at the next start
touch /Volumes/cache/.metadata_never_index
sudo mdutil -i off /Volumes/cache >/dev/null
ln -sfn /Volumes/cache ~/cache
mkdir -p ~/cache/src ~/cache/cargo/registry ~/cache/cargo/git
# cargo's downloads: links, so CARGO_HOME (and rustup's files in it) stay where they are
for d in registry git; do
  [[ -L ~/.cargo/$d ]] && continue
  rm -rf ~/.cargo/"$d"
  ln -s ~/cache/cargo/"$d" ~/.cargo/"$d"
done
df -h /Volumes/cache | tail -1
ls -la ~/cache/ ~/.cargo | grep -E 'src|cargo|registry|git'
