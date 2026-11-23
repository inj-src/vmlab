#!/bin/bash
# vmlab: Rust for native macOS apps. The Command Line Tools (install-devtools.sh) give it the
# linker and the SDK. Run over SSH as dev, then `vm commit mac`. Idempotent.
set -euo pipefail
xcode-select -p >/dev/null || { echo "install the Command Line Tools first (install-devtools.sh)" >&2; exit 1; }

# 1. rustup: the stable toolchain without its offline documents, clippy and rustfmt. It adds
# ~/.cargo/env to the shell profiles; zsh over SSH reads ~/.zshenv, which it writes too.
if [[ ! -x ~/.cargo/bin/rustup ]]; then
  curl --proto '=https' --tlsv1.2 -fsS https://sh.rustup.rs -o /tmp/rustup-init.sh
  sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain stable -c clippy -c rustfmt
  rm -f /tmp/rustup-init.sh
fi
. ~/.cargo/env

# 2. sccache: rustc's output per crate, kept on the build cache disk (setup-cache.sh), so a clean
# build, a fresh checkout or a reset VM reuses what was compiled before. A clean release build
# of ripgrep: 34.3 s without it, 13.6 s with a warm cache (measured n=3, 2026-11-23).
# A release at least a month old, checked against the checksum upstream publishes with it.
ver=0.19.0 sha=2db7344bb96de350df79cd9f0124dd4e9baa47b3de2fac1e63e1346b66b20684
if [[ $(~/.cargo/bin/sccache --version 2>/dev/null) != "sccache $ver" ]]; then
  t=$(mktemp -d) name=sccache-v$ver-x86_64-apple-darwin
  curl --proto '=https' --tlsv1.2 -fsSL "https://github.com/mozilla/sccache/releases/download/v$ver/$name.tar.gz" -o "$t/sccache.tar.gz"
  echo "$sha  $t/sccache.tar.gz" | shasum -a 256 -c - >/dev/null
  tar -xzf "$t/sccache.tar.gz" -C "$t"
  ~/.cargo/bin/sccache --stop-server >/dev/null 2>&1 || true
  install -m 755 "$t/$name/sccache" ~/.cargo/bin/sccache
  rm -rf "$t"
fi
# ~/.zshenv: every zsh reads it, SSH's too. The folder appears with the first build: made now,
# it would stand where setup-cache.sh links the disk
grep -q '^# vmlab: sccache' ~/.zshenv 2>/dev/null || cat >> ~/.zshenv <<'EOF'
# vmlab: sccache (install-rust.sh), its cache on the build cache disk
export RUSTC_WRAPPER="$HOME/.cargo/bin/sccache" SCCACHE_DIR="$HOME/cache/sccache" SCCACHE_CACHE_SIZE=4G
EOF

# 3. Versions, and one program built, linked and run (without sccache: see above)
echo '=== versions'
rustc --version; cargo --version; ~/.cargo/bin/sccache --version
probe=$(mktemp -d)/probe
cargo new --quiet --vcs none "$probe"
env -u RUSTC_WRAPPER cargo run --quiet --manifest-path "$probe/Cargo.toml"
rm -rf "$(dirname "$probe")"
