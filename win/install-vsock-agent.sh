#!/bin/bash
# install-vsock-agent.sh: set up the vsock control channel to the running Windows VM: vmlab-vx
# here (~/.local/bin), and in the VM the viosock driver, vmlab-agent and its logon task
# (vsock-agent.ps1). The token both ends share is made once, at ~/.config/vmlab/agent-token.
# The VM's part is on its disk only: keep it with `vm commit win --keep-states` (or `vm save`).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
lab=$(cd "$here/.." && pwd)
[[ $(vm status | awk '$1 == "win" { print $2 }') == running ]] || { echo "start win first (vm start win)" >&2; exit 1; }

# The host's end
cargo build --release --quiet --manifest-path "$lab/vsock/Cargo.toml" --bin vmlab-vx
cp "$lab/vsock/target/release/vmlab-vx" "$HOME/.local/bin/.vmlab-vx.new"
rm -f "${XDG_RUNTIME_DIR:-/tmp}/vmlab-vx-noagent-3"   # its "no agent here" note
mv -f "$HOME/.local/bin/.vmlab-vx.new" "$HOME/.local/bin/vmlab-vx"

token=$HOME/.config/vmlab/agent-token
if [[ ! -s $token ]]; then
  (umask 077; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$token"; echo >> "$token")
fi

work=$(mktemp -d /vmlab/tmp/vsock-install.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/viosock" "$work/vsock"
osirrox -indev /vmlab/iso/virtio-win.iso -extract /viosock/w11/amd64 "$work/viosock" 2> /dev/null
chmod -R u+w "$work/viosock"
cp -r "$lab/vsock/Cargo.toml" "$lab/vsock/Cargo.lock" "$lab/vsock/src" "$work/vsock/"
cp "$here/vsock-agent.ps1" "$work/"
(umask 077; cp "$token" "$work/agent-token")
tar -C "$work" -cf - viosock vsock vsock-agent.ps1 agent-token | ssh win-pwsh 'tar -xf - -C C:\vmlab'
ssh win-pwsh 'C:\vmlab\vsock-agent.ps1'
for _ in $(seq 20); do vmlab-vx ping 2> /dev/null && exit 0; python3 -c 'import time; time.sleep(0.5)'; done
echo "the agent does not answer: see C:\\vmlab\\agent.log (ssh win 'cat /c/vmlab/agent.log')" >&2
exit 1
