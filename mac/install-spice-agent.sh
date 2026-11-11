#!/bin/bash
# install-spice-agent.sh: build and install the SPICE guest agent (shared clipboard, file drop) in
# the mac VM. Run on the host while `mac` is running. Copies spice-agent/ to ~/src/spice-agent in
# the VM, compiles it with the Command Line Tools' swiftc, installs /usr/local/libexec/vmlab-spice-agent
# and loads LaunchAgent local.vmlab.spice-agent (KeepAlive) in the dev GUI session.
# Log: ~/Library/Logs/vmlab-spice-agent.log in the VM.
# Undo: launchctl bootout gui/501/local.vmlab.spice-agent; rm ~/Library/LaunchAgents/local.vmlab.spice-agent.plist
# The domain also needs <mouse mode='server'/> in its <graphics type='spice'> (see macos.live.xml),
# or spice-server routes the mouse through the agent.
set -euo pipefail
src=$(cd "$(dirname "$0")/spice-agent" && pwd)
tar -C "$src" -cf - Sources build.sh install.sh local.vmlab.spice-agent.plist |
  vm ssh mac 'rm -rf ~/src/spice-agent && mkdir -p ~/src/spice-agent && tar -xf - -C ~/src/spice-agent'
vm ssh mac '~/src/spice-agent/install.sh'
