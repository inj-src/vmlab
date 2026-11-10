#!/usr/bin/env bash
# measure-cpu.sh [settle_secs]: idle CPU of the macos QEMU process with and without the agent.
# Alternates 60 s windows with the LaunchAgent loaded and booted out (no SPICE client), then with
# the headless client attached (the agent polls the pasteboard only then), and reports the agent's
# own CPU time from inside the guest.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
settle=${1:-300}
P='~/Library/LaunchAgents/local.vmlab.spice-agent.plist'
load(){ vm ssh mac "launchctl bootstrap gui/\$(id -u) $P 2>/dev/null; true"; sleep 5; }
unload(){ vm ssh mac "launchctl bootout gui/\$(id -u)/local.vmlab.spice-agent 2>/dev/null; true"; sleep 5; }
agent_cpu(){ vm ssh mac 'ps -o time= -p $(pgrep -x vmlab-spice-agent)' | tr -d ' '; }
echo "settling ${settle}s"; sleep "$settle"
vm ssh mac 'ps -Ao %cpu,comm -r | head -4'
for r in 1 2 3; do
  load;   echo "round $r agent loaded, no client:  $("$here/qemu-cpu.sh" 60)%"
  unload; echo "round $r agent unloaded:           $("$here/qemu-cpu.sh" 60)%"
done
load
for r in 1 2; do
  python3 "$here/hold_client.py" 75 >/dev/null & hp=$!
  sleep 8; a=$(agent_cpu)
  echo "round $r agent loaded + client:    $("$here/qemu-cpu.sh" 60)%  (agent cpu time $a -> $(agent_cpu))"
  wait $hp || echo "hold client exited $?"
  sleep 5
done
