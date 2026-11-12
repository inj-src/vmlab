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

# 2. Versions, and one program built, linked and run
echo '=== versions'
rustc --version; cargo --version
probe=$(mktemp -d)/probe
cargo new --quiet --vcs none "$probe"
cargo run --quiet --manifest-path "$probe/Cargo.toml"
rm -rf "$(dirname "$probe")"
