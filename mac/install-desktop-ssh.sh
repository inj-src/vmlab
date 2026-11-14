#!/bin/bash
# install-desktop-ssh.sh: set up desktop-session SSH in the running Mac VM (desktop-ssh.sh) and
# check that SSH now lands in dev's GUI session. The change is on the VM's disk only: keep it
# with `vm commit mac` (or `vm save` for a state).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ $(vm status | awk '$1 == "mac" { print $2 }') == running ]] || { echo "start mac first (vm start mac)" >&2; exit 1; }

tar -C "$here" -cf - vmlab-ssh-session desktop-ssh.sh | vm ssh mac 'rm -rf /tmp/vmlab-dssh && mkdir /tmp/vmlab-dssh && tar -xf - -C /tmp/vmlab-dssh'
vm ssh mac 'sudo -n /tmp/vmlab-dssh/desktop-ssh.sh; c=$?; rm -rf /tmp/vmlab-dssh; exit $c'
# a shared connection opened before keeps the old sshd configuration: close it
ssh -o ControlPath="${XDG_CACHE_HOME:-$HOME/.cache}/vmlab/ssh-2227" -O exit mac 2>/dev/null || true
vm ssh mac 'launchctl managername; echo "user $(id -un), sudo $(sudo -n true && echo ok)"'
