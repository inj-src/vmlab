#!/usr/bin/env bash
# setup-ready.sh [intel|nvidia]: build the Windows ready state again from win11-base (Windows as
# installed, with SSH, Cua Driver and the debloat, but no GPU driver). `win-venus.sh setup` runs
# this. About 15 minutes; run it as a systemd-run --user unit. No window opens.
#
# It works on a new file beside the ready state and swaps it in only when every step passed and
# the checks at the end hold, so a failed run leaves the old ready state as it was. This run's
# changes (win11-venus.qcow2) are dropped at the swap: they belong to the old ready state.
#
# What the ready state is, on top of win11-base (README.md, "After a reset", says why for each):
#   1. the driver package from the CD (D:\Install.cmd): test signing on, the virtio GPU driver
#   2. the lab's builds of the Direct3D driver (guest-umd/) and of the kernel driver (guest-kmd/,
#      HWCursor=1): Chrome's static vertex buffers, a pointer drawn by the host, Desktop
#      Duplication
#   3. Microsoft's d3d12.dll beside the package's bridge, for Chromium's GPU process
#      (guest-scripts/d3d12-mode.ps1, bridge)
#   4. no account lockout: Chrome's empty-password logons locked dev out of SSH
#   5. the lab's helper for the desktop session (win/run-interactive.ps1) and Cua Driver's
#      logon task, both started with no console window (the helper on win11-base shows one)
#   6. the theme "Windows (light)"
#   7. Windows' own animations, fades and transparency (guest-scripts/default-ui.ps1; win11-base
#      has them off, from the time the VM had no GPU). Done with step 3, before its restart.
# WIN_VENUS_READY=FILE builds that file instead (a trial run beside the real ready state).
set -euo pipefail
HERE=/vmlab/tools/vmlab/gpu/win3d
W=$HERE/win-venus.sh
BASE=/vmlab/images/win11-base.qcow2
READY=${WIN_VENUS_READY:-/vmlab/images/win11-ready.qcow2}
RUN_DISK=${WIN_VENUS_DISK:-/vmlab/images/win11-venus.qcow2}    # this run's changes on the old ready state
NEW=${READY%.qcow2}.new.qcow2
gpu=${1:-nvidia}

die(){ echo "setup-ready: $*" >&2; exit 1; }
say(){ echo "$(date +%T) $*"; }
[[ $gpu =~ ^(intel|nvidia)$ ]] || die "usage: setup-ready.sh [intel|nvidia]"
[[ -f $BASE ]] || die "no $BASE"
[[ -f $HERE/guest-umd/x64/viogpu_d3d10.dll && -f $HERE/guest-umd/x86/viogpu_d3d10.dll ]] || die "build the Direct3D driver first (build-guest-umd.sh)"
[[ -f $HERE/guest-kmd/viogpu3d.sys ]] || die "build the kernel driver first (build-guest-kmd.sh)"
"$W" status | grep -q '^not running' || die "the Windows VM is running: stop it first"
# Named states (vm states) are changes to the ready state that goes: they would be a broken disk
STATES=/vmlab/images/states/win
if [[ -z ${WIN_VENUS_READY:-} ]] && compgen -G "$STATES/*.qcow2" > /dev/null; then
  die "Windows has named states, which a new ready state makes unusable: vm clear win --all first"
fi
for u in vmlab-mac26d vmlab-mac26; do
  systemctl --user is-active -q "$u" && die "another VM is running ($u): one at a time"
done

# The trial files: the new ready state, and the run on it that commit folds into it
export WIN_VENUS_READY=$NEW WIN_VENUS_DISK=${NEW%.qcow2}.run.qcow2
rm -f "$NEW" "${NEW%.qcow2}.vars.fd" "$WIN_VENUS_DISK"
qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$NEW"
"$W" reset > /dev/null                      # fresh firmware variables for this start
finished=''
trap '[[ -n $finished ]] || "$W" kill > /dev/null 2>&1 || true' EXIT     # a failed run leaves no VM behind

gssh(){ "$W" ssh "$@"; }
# up: Windows answers over SSH and has been up for half a minute (not on its way down)
up(){ [[ $(gssh '[int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds' 2>/dev/null | tr -d '\r') -ge 30 ]] 2>/dev/null; }
wait_up(){ for _ in $(seq 150); do up && return; sleep 4; done; die "Windows did not come up"; }
restart(){
  gssh 'shutdown.exe /r /t 0 /f' > /dev/null 2>&1 || true
  sleep 20; wait_up
}
interactive(){   # run a script from guest-scripts/ in the desktop session
  gssh "Remove-Item Env:PSModulePath; powershell -NoProfile -ExecutionPolicy Bypass -File C:\\vmlab\\run-interactive.ps1 -TimeoutSec 60 -Command 'C:\\vmlab\\$1'; exit \$LASTEXITCODE"; }

say "start on $gpu, from win11-base"
"$W" start "$gpu" > /dev/null
wait_up

say "1. the driver package (Windows restarts twice)"
# (the session ends with Windows' restart: what counts is the package's own state file)
gssh 'Remove-Item Env:PSModulePath; cmd /c D:\Install.cmd' > /dev/null 2>&1 || true
state=''
for _ in $(seq 150); do
  state=$(gssh '(Get-Content C:\ProgramData\vmlab-win3d\state.json -Raw | ConvertFrom-Json).status' 2>/dev/null | tr -d '\r' || true)
  [[ $state == Installed || $state == Failed ]] && break
  sleep 4
done
[[ $state == Installed ]] || { gssh 'Get-Content C:\ProgramData\vmlab-win3d\journal.log -Tail 20' || true; die "the driver package ended as '${state:-no answer}'"; }
sleep 20; wait_up                           # its last restart

say "2. the lab's Direct3D and kernel drivers"
"$HERE/build-guest-umd.sh" install > /dev/null
"$HERE/build-guest-kmd.sh" install > /dev/null
say "3. Microsoft's d3d12.dll for Chromium, and Windows' own visual effects"
"$W" d3d12 bridge > /dev/null
"$W" scp "$HERE/guest-scripts/default-ui.ps1" dev@127.0.0.1:C:/vmlab/
gssh 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\vmlab\default-ui.ps1' > /dev/null
restart

say "4. no account lockout"
gssh 'net accounts /lockoutthreshold:0' > /dev/null
say "5. helpers that show no window"
"$W" scp "$HERE/../../win/run-interactive.ps1" "$HERE/guest-scripts/quiet-helpers.ps1" dev@127.0.0.1:C:/vmlab/
quiet=$(gssh 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\vmlab\quiet-helpers.ps1' | tr -d '\r')
[[ ${quiet##*$'\n'} == helpers=quiet ]] || die "the helpers are not quiet: $quiet"
"$W" scp "$HERE/guest-scripts/clear-history.ps1" dev@127.0.0.1:C:/vmlab/
gssh 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\vmlab\clear-history.ps1' > /dev/null     # (win11-base carries the lab's own)
say "6. the theme"
"$W" scp "$HERE/guest-scripts/set-theme.ps1" dev@127.0.0.1:C:/vmlab/
theme=''
for _ in $(seq 20); do theme=$(interactive set-theme.ps1 2>&1) && break; sleep 6; done   # (the desktop takes a while after a start)
echo "   ${theme##*$'\n'}"
[[ $theme == *theme*already* || $theme == *'->'* ]] || die "the theme did not apply"

say "checks"
"$W" scp "$HERE/guest-scripts/ready-checks.ps1" dev@127.0.0.1:C:/vmlab/
checks=$(gssh 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\vmlab\ready-checks.ps1' | tr -d '\r')
echo "$checks" | sed 's/^/   /'
want_umd=$(sha256sum "$HERE/guest-umd/x64/viogpu_d3d10.dll" | cut -d' ' -f1)
want_kmd=$(sha256sum "$HERE/guest-kmd/viogpu3d.sys" | cut -d' ' -f1)
for line in gpu=OK hwcursor=1 "umd=$want_umd" "kmd=$want_kmd" d3d12=NotSigned d3d12chromium=Valid,Valid lockout=Never; do
  grep -qx "$line" <<< "$checks" || die "check failed: wanted $line"
done
grep -qx 'licence=1' <<< "$checks" || echo "   (Windows is not activated in this state: it activates by itself online, or not at all)"

say "stop, and make it the ready state"
"$W" stop > /dev/null
"$W" commit > /dev/null                     # the run, folded into $NEW; its firmware variables beside it
finished=1
READY_VARS=${READY%.qcow2}.vars.fd
# this run's changes, if they are on the ready state that goes
if [[ -f $RUN_DISK && $(qemu-img info --output=json "$RUN_DISK" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("backing-filename",""))') == "$READY" ]]; then
  rm -f "$RUN_DISK"
fi
mv "$NEW" "$READY"
mv "${NEW%.qcow2}.vars.fd" "$READY_VARS"
[[ $READY != /vmlab/images/win11-ready.qcow2 ]] || { mkdir -p "$STATES"; echo clean > "$STATES/.current"; rm -f "$STATES/.changed"; }
say "done: $READY ($(du -h "$READY" | cut -f1)) is the ready state"
