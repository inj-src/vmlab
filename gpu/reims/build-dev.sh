#!/usr/bin/env bash
# rebuild reims' development lane (/vmlab/reims-dev). No --yes: its optional sudo steps are declined.
set -euo pipefail
export RUSTUP_HOME=/vmlab/reims/rustup CARGO_HOME=/vmlab/reims/cargo
cd /vmlab/tools/vmlab/gpu/reims-vgpu-dev
XDG_CONFIG_HOME=/vmlab/reims-dev/config XDG_DATA_HOME=/vmlab/reims-dev/data XDG_CACHE_HOME=/vmlab/reims-dev/cache \
CARGO_INSTALL_ROOT=/vmlab/reims-dev PATH=/vmlab/reims-dev/bin:$HOME/.cargo/bin:$PATH scripts/install-ctl.sh < /dev/null
echo "=== development lane done"
