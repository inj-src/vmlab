#!/bin/bash
# vmlab macOS dev tools. Run over SSH as dev (passwordless sudo is set by bootstrap.sh). Idempotent.
# No Homebrew: its installer refuses Intel Macs, and this VM is x86_64 (OSX-KVM).
set -euo pipefail
NODE_VER=${NODE_VER:-v26.13.0}   # match the Windows VM's Node LTS line
PY_VER=${PY_VER:-3.12}
mkdir -p ~/.local/bin
grep -q '.local/bin' ~/.zprofile 2>/dev/null || echo 'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"' >> ~/.zprofile
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# 1. Xcode Command Line Tools (git, clang, make), headless via the softwareupdate in-progress flag
if ! xcode-select -p >/dev/null 2>&1; then
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  label=$(softwareupdate -l 2>/dev/null | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -1)
  echo "CLT: $label"; sudo softwareupdate -i "$label" --verbose
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi

# 2. Node.js (official darwin-x64 tarball into /usr/local) + corepack (pnpm/yarn shims)
if [[ "$(node --version 2>/dev/null)" != "$NODE_VER" ]]; then
  t=node-$NODE_VER-darwin-x64
  curl -fsSL "https://nodejs.org/dist/$NODE_VER/$t.tar.gz" -o /tmp/$t.tar.gz
  curl -fsSL "https://nodejs.org/dist/$NODE_VER/SHASUMS256.txt" | grep " $t.tar.gz\$" | (cd /tmp && shasum -a 256 -c)
  sudo tar -xzf /tmp/$t.tar.gz -C /usr/local --strip-components=1 --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'
  rm -f /tmp/$t.tar.gz
fi
sudo corepack enable || true

# 3. uv (Astral standalone installer) and a uv-managed CPython as python3 / python3.12
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
uv python install "$PY_VER" --default --preview-features python-install-default

# 4. Visual Studio Code (universal build) + `code` on PATH
if [[ ! -d "/Applications/Visual Studio Code.app" ]]; then
  curl -fsSL "https://update.code.visualstudio.com/latest/darwin-universal/stable" -o /tmp/vscode.zip
  sudo ditto -xk /tmp/vscode.zip /Applications && rm -f /tmp/vscode.zip
fi
ln -sf "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ~/.local/bin/code

echo '=== versions'
git --version; node --version; npm --version; pnpm --version 2>/dev/null || true
python3 --version; python$PY_VER --version; uv --version; code --version | head -1; xcode-select -p
