#!/bin/bash
# install-desktop-ssh.sh: set up desktop-session SSH in the running Windows VM (desktop-ssh.ps1),
# restart it and check that SSH now lands on the desktop. The change is on the VM's disk only:
# keep it with `vm commit win --keep-states` (or `vm save` for a state).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ $(vm status | awk '$1 == "win" { print $2 }') == running ]] || { echo "start win first (vm start win)" >&2; exit 1; }

tar -C "$here" --exclude=target -cf - vmshell desktop-ssh.ps1 | vm ssh win 'tar -xf - -C C:\vmlab'
vm run win --timeout 900 <<< '& C:\vmlab\desktop-ssh.ps1'
vm stop win
vm start win
vm ssh win '"session " + (Get-Process -Id $PID).SessionId + ", desktop " + (Get-Process explorer).SessionId + ", shell " + (Get-Process -Id (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId).Name'
