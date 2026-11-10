#!/bin/bash
# install.sh: build the agent and (re)load it as LaunchAgent local.vmlab.spice-agent in the dev
# GUI session. Runs inside the VM; ../install-spice-agent.sh copies the source in and calls it.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
sudo install -d -o root -g wheel /usr/local/libexec
sudo install -o root -g wheel -m 755 build/vmlab-spice-agent /usr/local/libexec/vmlab-spice-agent
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
plist=~/Library/LaunchAgents/local.vmlab.spice-agent.plist
sed "s|__HOME__|$HOME|g" local.vmlab.spice-agent.plist > "$plist"
U=$(id -u)
launchctl bootout "gui/$U/local.vmlab.spice-agent" 2>/dev/null || true
# bootout returns before the job is fully gone; bootstrap fails with EIO until it is.
for i in $(seq 10); do launchctl bootstrap "gui/$U" "$plist" 2>/dev/null && break; sleep 1; done
sleep 2
launchctl print "gui/$U/local.vmlab.spice-agent" | grep -E '^\s+(state|pid) ='
tail -n 3 ~/Library/Logs/vmlab-spice-agent.log
