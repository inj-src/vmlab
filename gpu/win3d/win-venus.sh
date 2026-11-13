#!/usr/bin/env bash
# win-venus.sh: run the Windows lab VM on a Venus virtual GPU (host Vulkan), rootless and
# outside libvirt. Three disk layers: win11-base (Windows as installed, never written),
# win11-ready on it (the GPU driver and the rest of the ready state: reset returns to it,
# commit writes to it, setup builds it again) and win11-venus on that (this run's changes).
#
#   win-venus.sh start <intel|nvidia> [--window]
#                                       boot on that host GPU; --window: in a window on the
#                                       user's screen with sound and a shared clipboard. It
#                                       opens maximized and Windows takes its size once (1920x1042
#                                       on a 1920x1080 screen), so the picture is unscaled; a
#                                       resize after that scales it, Windows' size staying.
#                                       Maximized on a screen of another scale (the laptop's
#                                       panel, 125%), Windows takes that screen's pixels
#                                       (1920 wide there) and its own scaling follows (125%),
#                                       so the picture is sharp and the same size as the
#                                       desktop's on both screens.
#                                       WIN_VENUS_WINDOW_SIZE=1920x1080: that size always, scaled
#                                       into the window (unscaled only full screen, on a
#                                       1920x1080 screen). Closing it shuts Windows down.
#                                       The title bar's round button, or Ctrl+Alt+F, fills the
#                                       screen; Ctrl+Alt+F leaves it. Text and pictures copied
#                                       on either side paste on the other; files dragged onto
#                                       the window land on the guest's desktop.
#                                       Without --window: no window.
#                                       Either way the display is also on VNC, 127.0.0.1:5911
#   win-venus.sh stop                   ask Windows to shut down, then stop the helpers
#   win-venus.sh kill                   stop everything now
#   win-venus.sh status                 what is running
#   win-venus.sh ssh [command...]       ssh into the guest (dev@127.0.0.1:2222)
#   win-venus.sh scp SRC... DEST        copy files; the guest is dev@127.0.0.1:PATH
#   win-venus.sh view                   open the VNC console in remote-viewer
#   win-venus.sh shot <file.png>        screenshot the guest display (over VNC)
#   win-venus.sh scale [PERCENT]        Windows' display scaling now, or set it (100, 125, 150...).
#                                       With a window it follows the screen by itself (the
#                                       vmlab-win-venus-scale unit, log /vmlab/run/win-venus/scale.log)
#   win-venus.sh d3d12 [native|bridge|status]
#                                       which d3d12.dll the guest has. native (the lab's default):
#                                       Microsoft's, and Chrome and Electron work. bridge: the
#                                       driver package's, for a native Direct3D 12 program; with it
#                                       Chrome's GPU process crashes (guest-scripts/d3d12-mode.ps1).
#                                       Restart Windows after a change
#   win-venus.sh reset [--discard]      drop this run's changes: the next start is the ready state
#   win-venus.sh commit [--keep-states|--drop-states]
#                                       make the stopped VM's disk the ready state (reset's
#                                       target). Named states stand on the ready state:
#                                       --keep-states moves them to the new one, each as it was
#                                       (it grows by what the commit changed); --drop-states
#                                       deletes them
#   win-venus.sh state save NAME | load NAME [--discard] | rm NAME | list
#                                       named states (`vm save`, `vm states`; ../states.sh): the
#                                       stopped VM's disk kept under a name, and put back
#   win-venus.sh setup                  build the ready state again from win11-base (setup-ready.sh)
#
# QEMU is vmlab-win3d's (patched for NVIDIA), built here with a window (build-qemu.sh). Their
# release build, opt/qemu/, has no user-mode network, so the system QEMU runs beside it as a
# NAT box: its slirp backend and a socket backend share a hub, and the guest's NIC connects to
# that socket. Guest: 10.0.2.15, host: 10.0.2.2. That arrangement is kept for both builds.
set -euo pipefail

HERE=/vmlab/tools/vmlab/gpu/win3d
QEMU=$HERE/opt/qemu-ui/bin/qemu-system-x86_64
RENDER_SERVER=$HERE/opt/virgl/libexec/virgl_render_server
BASE=/vmlab/images/win11-base.qcow2
READY=${WIN_VENUS_READY:-/vmlab/images/win11-ready.qcow2}   # on BASE; its firmware variables beside it
READY_VARS=${READY%.qcow2}.vars.fd
DISK=${WIN_VENUS_DISK:-/vmlab/images/win11-venus.qcow2}     # on READY
S=/vmlab/run/win-venus            # sockets, pid files, logs, firmware variables
# Named states: NAME.qcow2 is a run's disk kept as it was (the changes since READY, so each is
# as large as what its run wrote) and NAME.vars.fd its firmware variables. Loading one copies
# it to DISK: on this XFS disk a copy shares its blocks (reflink), so it takes no time or room.
# They are written on READY: whatever changes READY (commit, setup) makes them unusable,
# unless they are moved with it (commit --keep-states).
STATES=/vmlab/images/states/win ST_VM=win
# A trial on other files (setup-ready.sh) has nothing to do with them, or with their marks
[[ -z ${WIN_VENUS_READY:-}${WIN_VENUS_DISK:-} ]] || STATES=$S/trial-states
KEY=$HOME/.ssh/vmlab_ed25519
ISO=$HERE/win3d-guest.iso          # the guest driver package, as a CD (D:\Install.cmd)
SSH_PORT=2222 VNC_DISPLAY=11      # VNC on 127.0.0.1:5911
VCPUS=0-7                         # host CPUs for the guest's CPUs: the fast cores (../pin.py)
# The host folder both VMs see as \\10.0.2.4\qemu (in the guest: C:\share). The NAT helper's
# QEMU starts a private smbd for it at each connection (../share-smbd.sh); the host's own
# Samba services are masked, so nothing serves it outside the VM. WIN_VENUS_SHARE=off: none.
SHARE=${WIN_VENUS_SHARE:-/vmlab/share}
# The build cache: a second disk, C:\cache in the guest, that `reset` and `commit` leave alone
# (checkouts, their build output, cargo's downloads). It is on the system disk, at the user's
# wish (2026-11-12), not on /vmlab: at most 25 GB, as large as what is in it. Missing, it is
# made from the empty formatted one in CACHE_EMPTY (so deleting the file empties the cache), or
# blank where that is missing too (win/setup-cache.ps1 formats it). VMLAB_CACHE=off: no such disk.
CACHE=${VMLAB_CACHE:-$HOME/.local/share/vmlab/cache}
CACHE_EMPTY=/vmlab/images/win-cache-empty.qcow2

die(){ echo "win-venus: $*" >&2; exit 1; }
. "$HERE/../states.sh"
alive(){ [[ -f $S/$1.pid ]] && kill -0 "$(cat "$S/$1.pid")" 2>/dev/null; }
qmp(){ # qmp '<json command>': one command over the QMP socket
  python3 -I - "$S/qmp.sock" "$1" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1]); f = s.makefile('rw')
f.readline(); f.write('{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(sys.argv[2] + '\n'); f.flush()
while True:
    r = json.loads(f.readline())
    if 'return' in r or 'error' in r: print(json.dumps(r)); break
EOF
}

start(){
  local gpu=${1:-} node select layer=() display env=() audio=none a
  case $gpu in
    intel)  node=$(gpu_node 0x8086); select='*intel*' ;;
    nvidia) node=$(gpu_node 0x10de); select='*nvidia*'
      # host-layer/: without it the guest's Direct3D 11 uploads arrive with holes on this laptop
      [[ ${WIN_VENUS_LAYER:-on} == off ]] || layer=(--setenv=VK_LAYER_PATH="$HERE/host-layer"
        --setenv=VK_INSTANCE_LAYERS=VK_LAYER_VMLAB_coherent_memory) ;;
    *) die "usage: win-venus.sh start <intel|nvidia> [--window]" ;;
  esac
  [[ -x $QEMU ]] || die "build QEMU first: $HERE/build-qemu.sh"
  display=(-display "egl-headless,rendernode=$node" -vnc "127.0.0.1:$VNC_DISPLAY")
  case ${2:-} in
    --window) audio=pipewire
      # The window is GTK's plain (non-OpenGL) one beside egl-headless, which qemu-patches/0002
      # opens where VMLAB_WINDOW is set: the guest's frames are rendered and read back on $gpu,
      # as without a window, and the window shows them. `-display gtk,gl=on` cannot be used for
      # NVIDIA: GTK draws on the desktop's GPU (Intel), whose driver cannot use NVIDIA's frames
      # (QEMU's main thread then loops on DRM_IOCTL_I915_GEM_EXECBUFFER2 = ENOMEM for ever), and
      # on NVIDIA's own EGL QEMU's GTK code finds no dma-buf support and aborts.
      # The other VMLAB_ variables (qemu-patches/0001): the desktop's icon for the window
      # (vmlab-win11.desktop), its title, and a close button that shuts Windows down.
      # FIXED_SIZE and MAXIMIZE (qemu-patches/0003, 0005), as the user asked: the window opens
      # filling the screen and the guest's resolution does not follow it. =first (the default):
      # the guest takes the window's size once, when it starts, so the picture is a guest pixel
      # to a screen pixel (sharp), and the window scales it only once resized. =1920x1080
      # (WIN_VENUS_WINDOW_SIZE): that size always, scaled into the window's 1042 rows (soft).
      # The title bar has one button, full screen (qemu-patches/0010); QEMU's menus are not shown.
      # WIN_VENUS_WINDOW_X11=1, for tests: the window under XWayland, where xdotool and
      # xwininfo can measure and resize it.
      for a in WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR WAYLAND_DEBUG; do [[ -n ${!a:-} ]] && env+=(--setenv="$a=${!a}"); done
      env+=(--setenv=VMLAB_WINDOW=1 --setenv=VMLAB_WINDOW_APP_ID=vmlab-win11 --setenv="VMLAB_WINDOW_TITLE=Windows 11" --setenv=VMLAB_WINDOW_CLOSE_POWERS_DOWN=1
        --setenv="VMLAB_WINDOW_FIXED_SIZE=${WIN_VENUS_WINDOW_SIZE:-first}" --setenv="VMLAB_WINDOW_SCALE_FILE=$S/scale" --setenv="VMLAB_WINDOW_SIZE_FILE=$S/size")
      # WIN_VENUS_WINDOW_RESTORED=1, for tests: the window opens at QEMU's own size, not maximized.
      [[ -n ${WIN_VENUS_WINDOW_RESTORED:-} ]] || env+=(--setenv=VMLAB_WINDOW_MAXIMIZE=1)
      [[ -n ${WIN_VENUS_WINDOW_X11:-} ]] && env+=(--setenv=GDK_BACKEND=x11)
      ;;
    '') ;;
    *) die "usage: win-venus.sh start <intel|nvidia> [--window]" ;;
  esac
  [[ -n $node ]] || die "no $gpu render node"
  alive qemu && die "already running (win-venus.sh stop)"
  [[ $(virsh -c qemu:///system list --name | grep -c .) == 0 ]] || die "a libvirt VM is running: one VM at a time"
  { systemctl --user is-active --quiet vmlab-mac26 || systemctl --user is-active --quiet vmlab-mac26d; } && die "a mac26 VM is running: one VM at a time"
  mkdir -p "$S"
  [[ -f $READY ]] || die "no ready state ($READY): win-venus.sh setup"
  [[ -f $DISK ]] || qemu-img create -q -f qcow2 -F qcow2 -b "$READY" "$DISK"
  st_ran
  # Secure Boot has to be off for the test-signed driver: plain OVMF with its own variables,
  # the ready state's where it has saved them
  [[ -f $S/OVMF_VARS.fd ]] || cp "$([[ -f $READY_VARS ]] && echo "$READY_VARS" || echo /usr/share/OVMF/OVMF_VARS_4M.fd)" "$S/OVMF_VARS.fd"

  [[ -x $RENDER_SERVER ]] || die "$RENDER_SERVER is missing"
  [[ ${#layer[@]} == 0 || -f $HERE/host-layer/libVkLayer_vmlab_coherent_memory.so ]] || die "build the layer first: $HERE/host-layer/build.sh"
  # Helpers left by a run that ended by itself (Windows shut down from inside, or its window
  # closed, which powers it down; only `stop` and `kill` end them): their units would refuse
  # the new ones their names.
  systemctl --user stop vmlab-win-venus-net vmlab-win-venus-scale 2>/dev/null || true
  rm -f "$S"/{net,qmp,ga}.sock "$S"/{net,qemu}.pid "$S/size"; : > "$S/qemu.log"; : > "$S/net.log"
  # Both run as transient user units, so they outlive the terminal or app that started them,
  # and QEMU's stderr (the render server's messages too) lands in qemu.log.
  local smb=
  if [[ $SHARE != off && -x /usr/sbin/smbd ]]; then    # (../share-smbd.sh says why not smb=)
    mkdir -p "$SHARE"; rm -rf "$S/smb"; smb=",guestfwd=tcp:10.0.2.4:445-cmd:$HERE/../share-smbd.sh $SHARE $S/smb"
  fi
  unit vmlab-win-venus-net "$S/net.log" \
    /usr/bin/qemu-system-x86_64 -name win-venus-net -machine none -nodefaults -display none \
    -netdev "user,id=u,net=10.0.2.0/24,dhcpstart=10.0.2.15,hostfwd=tcp:127.0.0.1:$SSH_PORT-10.0.2.15:22$smb" \
    -netdev "stream,id=s,server=on,addr.type=unix,addr.path=$S/net.sock" \
    -netdev hubport,id=h0,hubid=0,netdev=u -netdev hubport,id=h1,hubid=0,netdev=s \
    -pidfile "$S/net.pid"
  up net || die "the NAT helper did not start: $(cat "$S/net.log")"

  local cache=()
  if [[ $CACHE != off ]]; then
    mkdir -p "$CACHE"
    if [[ ! -f $CACHE/win.qcow2 ]]; then
      if [[ -f $CACHE_EMPTY ]]; then cp "$CACHE_EMPTY" "$CACHE/win.qcow2"; else qemu-img create -q -f qcow2 "$CACHE/win.qcow2" 25G; fi
    fi
    cache=(-blockdev "driver=qcow2,node-name=cache0,cache.direct=on,discard=unmap,file.driver=file,file.aio=io_uring,file.filename=$CACHE/win.qcow2"
      -device virtio-blk-pci,drive=cache0,serial=vmlabcache,iothread=io0,addr=2)
  fi

  echo "$gpu" > "$S/gpu"
  # The clipboard channel (qemu-vdagent) has mouse=off: left on, QEMU sends every pointer move
  # through the agent program inside Windows, not the USB tablet, and the pointer lags
  # (../README.md, "The pointer").
  # For diagnosis: WIN_VENUS_STRACE=FILE records the system calls of QEMU's main thread there
  local trace=(); [[ -n ${WIN_VENUS_STRACE:-} ]] && trace=(strace -o "$WIN_VENUS_STRACE" -tt -T)
  # Every PCI device has its slot written out (addr=). Windows keeps a device's settings under
  # its slot: left to QEMU's numbering, the cache disk (added 2026-11-12) moved the GPU from
  # slot 4 to 5, Windows set it up as a new device with the driver's defaults (HWCursor=0), and
  # the pointer trailed again. A new device takes a free slot (8 and up), never one of these.
  unit vmlab-win-venus "$S/qemu.log" --setenv=VK_LOADER_DRIVERS_SELECT="$select" --setenv=RENDER_SERVER_EXEC_PATH="$RENDER_SERVER" "${layer[@]}" "${env[@]}" \
    "${trace[@]}" "$QEMU" -name win-venus -L /usr/share/qemu -L /usr/share/seabios -L /usr/lib/ipxe/qemu -machine q35,hpet=off -accel kvm \
    -cpu host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_vpindex,hv_runtime,hv_synic,hv_stimer,hv_frequencies,hv_tlbflush,hv_ipi,hv_time \
    -smp 6,sockets=1,cores=6,threads=1 -m 8192M -rtc base=localtime,driftfix=slew \
    -drive if=pflash,format=raw,readonly=on,file="$(firmware)" \
    -drive if=pflash,format=raw,file="$S/OVMF_VARS.fd" \
    -object iothread,id=io0 \
    -blockdev driver=qcow2,node-name=disk0,cache.direct=on,discard=unmap,file.driver=file,file.aio=io_uring,file.filename="$DISK" \
    -device virtio-blk-pci,drive=disk0,bootindex=1,iothread=io0,addr=1 "${cache[@]}" \
    -drive if=none,id=cd0,media=cdrom,readonly=on,format=raw,file="$ISO" -device ide-cd,drive=cd0 \
    -netdev "stream,id=n,server=off,addr.type=unix,addr.path=$S/net.sock" \
    -device virtio-net-pci,netdev=n,mac=52:54:00:58:55:6c,addr=3 \
    -device virtio-serial-pci,addr=4 \
    -chardev socket,id=ga,path="$S/ga.sock",server=on,wait=off -device virtserialport,chardev=ga,name=org.qemu.guest_agent.0 \
    -chardev qemu-vdagent,id=clip,name=vdagent,clipboard=on,mouse=off -device virtserialport,chardev=clip,name=com.redhat.spice.0 \
    -device virtio-vga-gl,venus=true,blob=true,hostmem=4G,xres=1920,yres=1080,addr=5 "${display[@]}" \
    -audiodev "$audio,id=snd0" -device ich9-intel-hda,addr=6 -device hda-duplex,audiodev=snd0 \
    -device qemu-xhci,addr=7 -device usb-tablet -device usb-kbd \
    -qmp unix:"$S/qmp.sock",server=on,wait=off -monitor none -serial file:"$S/serial.log" -parallel none \
    -pidfile "$S/qemu.pid"
  up qemu || { stop_helpers; die "QEMU did not start: $(tail -5 "$S/qemu.log")"; }
  for _ in $(seq 20); do python3 -I "$HERE/../pin.py" "$S/qmp.sock" "$VCPUS" 2>/dev/null && break; sleep 0.5; done
  # With a window, Windows' own scaling follows the screen the window is on (scale-watch below)
  [[ $audio == none ]] || unit vmlab-win-venus-scale "$S/scale.log" "$0" scale-watch
  echo "started on $gpu ($node): ssh port $SSH_PORT, VNC 127.0.0.1:$((5900 + VNC_DISPLAY))$([[ $audio == none ]] || echo " and a window"), log $S/qemu.log"
}
# unit NAME LOG [systemd-run options...] COMMAND...: run COMMAND as a transient user unit
unit(){ local name=$1 log=$2; shift 2
  systemctl --user reset-failed "$name" 2>/dev/null || true
  systemd-run --user --quiet --collect --unit="$name" -p StandardOutput="append:$log" -p StandardError="append:$log" "$@"; }
up(){ for _ in $(seq 20); do alive "$1" && return 0; sleep 0.5; done; return 1; }
gpu_node(){ local d; for d in /sys/class/drm/renderD*; do [[ $(cat "$d/device/vendor") == "$1" ]] && { echo "/dev/dri/${d##*/}"; return; }; done; }
stop_helpers(){ alive net && kill "$(cat "$S/net.pid")"; rm -f "$S"/net.pid; systemctl --user stop vmlab-win-venus-scale 2>/dev/null || true; }
stop(){
  if alive qemu; then
    qmp '{"execute":"system_powerdown"}' > /dev/null || true
    for _ in $(seq 60); do alive qemu || break; sleep 2; done
    alive qemu && { echo "guest did not shut down in 2 min, stopping it"; kill "$(cat "$S/qemu.pid")"; }
  fi
  # (its unit ends a moment after QEMU: `vm` and the other VM's launcher go by the unit)
  for _ in $(seq 20); do systemctl --user is-active --quiet vmlab-win-venus || break; sleep 0.5; done
  rm -f "$S/qemu.pid"; stop_helpers; echo stopped
}
ssh_guest(){ ssh -i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$S/known_hosts" \
  -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR dev@127.0.0.1 "$@"; }

# firmware: the firmware's file. The system's OVMF with a quiet start (no TianoCore logo, so
# Windows draws its own, and no "BdsDxe: loading" lines: firmware/make-firmware.py), made again
# when the system's file has changed; the system's own file where that fails.
# WIN_VENUS_FIRMWARE=stock: the system's own file.
firmware(){
  local sys=/usr/share/OVMF/OVMF_CODE_4M.fd ours=$HERE/firmware/OVMF_CODE_4M.vmlab.fd
  [[ ${WIN_VENUS_FIRMWARE:-} == stock ]] && { echo "$sys"; return; }
  if [[ ! -f $ours || $(cat "$ours.sha256" 2>/dev/null) != $(sha256sum "$sys" | cut -d' ' -f1) ]]; then
    python3 "$HERE/firmware/make-firmware.py" "$sys" "$ours" >> "$S/qemu.log" 2>&1 || { echo "$sys"; return; }
  fi
  echo "$ours"
}

# guest_scale PERCENT: set Windows' display scaling, in its desktop session (guest-scripts/set-scale.ps1)
guest_scale(){
  ssh_guest "Remove-Item Env:PSModulePath; powershell -NoProfile -ExecutionPolicy Bypass -File C:\\vmlab\\run-interactive.ps1 -TimeoutSec 30 -Command 'C:\\vmlab\\set-scale.ps1 $1'; exit \$LASTEXITCODE"; }

# guest_mode WxH: set Windows' resolution, in its desktop session (guest-scripts/set-mode.ps1)
guest_mode(){
  ssh_guest "Remove-Item Env:PSModulePath; powershell -NoProfile -ExecutionPolicy Bypass -File C:\\vmlab\\run-interactive.ps1 -TimeoutSec 30 -Command 'C:\\vmlab\\set-mode.ps1 $1'; exit \$LASTEXITCODE"; }

# commit --keep-states. A state is its changes to READY, so READY may not change under it:
# before the commit each state is pointed at a copy of READY as it is (states_hold: the same
# content under another name, and a reflink copy takes no room), and after it each is moved to
# the new READY (states_release: qemu-img copies into the state what the commit changed
# underneath it, so the state reads as before). A state not moved yet stays whole on the copy,
# and the next commit moves it.
READY_HELD=${READY%.qcow2}.held.qcow2
states_hold(){ local f
  [[ -e $READY_HELD ]] || cp --reflink=always "$READY" "$READY_HELD" || die "no copy of the ready state: nothing was changed"
  for f in "$STATES"/*.qcow2; do
    [[ $(backing_of "$f") == "$READY" ]] || continue
    qemu-img rebase -u -q -f qcow2 -F qcow2 -b "$READY_HELD" "$f"
  done; }
states_release(){ local f
  [[ -e $READY_HELD ]] || return 0
  for f in "$STATES"/*.qcow2; do
    [[ -f $f && $(backing_of "$f") == "$READY_HELD" ]] || continue
    qemu-img rebase -q -f qcow2 -F qcow2 -b "$READY" "$f" ||
      die "state $(basename "$f" .qcow2) was not moved to the new ready state (disk full?). It is whole, on $READY_HELD; 'win-venus.sh commit --keep-states' tries again"
  done
  rm -f "$READY_HELD"; }
backing_of(){ qemu-img info --output=json "$1" | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("backing-filename", ""))'; }
state_names(){ local f n=(); for f in "$STATES"/*.qcow2; do [[ -f $f ]] && n+=("$(basename "$f" .qcow2)"); done; echo "${n[*]:-none}"; }

case ${1:-} in
  start) start "${2:-}" "${3:-}" ;;
  # Internal, a unit of its own beside a windowed VM: QEMU keeps $S/scale at the scale, in
  # percent, of the screen its window is on (VMLAB_WINDOW_SCALE_FILE), and gives Windows that
  # screen's pixels of the window. This gives Windows the same scaling, so that things in it
  # are as large as on the host. It ends with QEMU.
  scale-watch)
    applied='' copied='' sized='' tries=0
    while alive qemu; do
      # The size the window offered Windows ($S/size, VMLAB_WINDOW_SIZE_FILE), where Windows
      # did not take it by itself (set-mode.ps1 says why), before the scaling, which Windows
      # keeps for each size
      size=$(cat "$S/size" 2>/dev/null || true)
      if [[ $size =~ ^[0-9]+x[0-9]+$ && $size != "$sized" ]]; then
        [[ -n $copied ]] || { "$0" scp "$HERE/guest-scripts/set-scale.ps1" "$HERE/guest-scripts/set-mode.ps1" dev@127.0.0.1:C:/vmlab/ 2>/dev/null && copied=1; }
        if [[ -n $copied ]] && out=$(guest_mode "$size" 2>&1); then
          sized=$size applied='' tries=0; echo "$(date +%T) window size $size: ${out##*$'\n'}"
        elif (( ++tries >= 20 )); then      # nobody signed in, or Windows has no such mode
          sized=$size tries=0; echo "$(date +%T) window size $size: not set: ${out##*$'\n'}"
        fi
      fi
      want=$(cat "$S/scale" 2>/dev/null || true)
      if [[ $want =~ ^[0-9]+$ && $want != "$applied" ]]; then
        [[ -n $copied ]] || { "$0" scp "$HERE/guest-scripts/set-scale.ps1" "$HERE/guest-scripts/set-mode.ps1" dev@127.0.0.1:C:/vmlab/ 2>/dev/null && copied=1; }
        if [[ -n $copied ]] && out=$(guest_scale "$want" 2>&1); then
          applied=$want; echo "$(date +%T) screen scale $want%: ${out##*$'\n'}"
        fi
      fi
      sleep 2
    done ;;
  scale) [[ ${2:-} =~ ^[0-9]*$ ]] || die "usage: win-venus.sh scale [percent]"
    "$0" scp "$HERE/guest-scripts/set-scale.ps1" dev@127.0.0.1:C:/vmlab/; guest_scale "${2:-}" ;;
  stop) stop ;;
  kill) alive qemu && kill -9 "$(cat "$S/qemu.pid")"; rm -f "$S/qemu.pid"; stop_helpers; echo killed ;;
  status) alive qemu && echo "running on $(cat "$S/gpu") (pid $(cat "$S/qemu.pid"))" || echo "not running" ;;
  ssh) shift; ssh_guest "$@" ;;
  scp) shift; scp -q -i "$KEY" -P "$SSH_PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$S/known_hosts" -o LogLevel=ERROR "$@" ;;
  view) exec remote-viewer "vnc://127.0.0.1:$((5900 + VNC_DISPLAY))" ;;
  # over VNC: QMP's screendump has no picture of a guest that draws through the GPU ("no surface")
  shot) [[ -n ${2:-} ]] || die "usage: win-venus.sh shot <file.png>"; python3 -I "$HERE/vncshot.py" $((5900 + VNC_DISPLAY)) "$2" ;;
  d3d12) [[ ${2:-status} =~ ^(native|bridge|status)$ ]] || die "usage: win-venus.sh d3d12 [native|bridge|status]"
    "$0" scp "$HERE/guest-scripts/d3d12-mode.ps1" dev@127.0.0.1:C:/vmlab/
    ssh_guest "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\vmlab\\d3d12-mode.ps1 ${2:-status}" ;;
  reset) alive qemu && die "stop it first"; st_guard "${2:-}"
    rm -f "$DISK" "$S/OVMF_VARS.fd"; st_mark clean
    echo "this run's changes dropped: the next start is the ready state" ;;
  commit) alive qemu && die "stop it first"
    [[ ${2:-} =~ ^(|--keep-states|--drop-states)$ ]] || die "usage: win-venus.sh commit [--keep-states|--drop-states]"
    [[ ${2:-} != --keep-states ]] || states_release   # what an earlier commit left unmoved
    [[ -f $DISK && -f $READY ]] || die "nothing to commit"
    # The named states are changes to READY as it is now: on another READY they are a broken disk
    if compgen -G "$STATES/*.qcow2" > /dev/null; then
      case ${2:-} in
        --keep-states) states_hold ;;
        --drop-states) rm -f "$STATES"/*.qcow2 "$STATES"/*.vars.fd "$STATES"/*.note "$READY_HELD" ;;
        *) die "the ready state has named states on it, which a commit alone makes unusable: $(state_names). Commit with --keep-states (they stay as they are and grow by what the commit changed) or --drop-states (they are deleted)" ;;
      esac
    fi
    qemu-img commit -q "$DISK"; rm -f "$DISK"
    [[ -f $S/OVMF_VARS.fd ]] && cp "$S/OVMF_VARS.fd" "$READY_VARS"
    st_mark clean
    [[ ${2:-} != --keep-states ]] || states_release
    echo "committed: $READY is the ready state" ;;
  state) alive qemu && [[ ${2:-} != list && ${2:-} != rm ]] && die "stop it first"
    case ${2:-} in
      save) st_valid "${3:-}"; mkdir -p "$STATES" "$S"
        [[ -f $DISK ]] || qemu-img create -q -f qcow2 -F qcow2 -b "$READY" "$DISK"   # nothing ran: the ready state itself
        cp --reflink=auto "$DISK" "$STATES/$3.qcow2.new"; mv "$STATES/$3.qcow2.new" "$STATES/$3.qcow2"
        cp "$([[ -f $S/OVMF_VARS.fd ]] && echo "$S/OVMF_VARS.fd" || echo "$READY_VARS")" "$STATES/$3.vars.fd"
        st_mark "$3"; echo "saved: $3" ;;
      load) st_valid "${3:-}"; [[ -f $STATES/$3.qcow2 ]] || die "no state '$3' ($(state_names))"
        st_guard "${4:-}"; mkdir -p "$S"
        cp --reflink=auto "$STATES/$3.qcow2" "$DISK.new"; mv "$DISK.new" "$DISK"
        cp "$STATES/$3.vars.fd" "$S/OVMF_VARS.fd"
        st_mark "$3"; echo "loaded: $3" ;;
      rm) st_valid "${3:-}"; [[ -f $STATES/$3.qcow2 ]] || die "no state '$3' ($(state_names))"
        rm -f "$STATES/$3.qcow2" "$STATES/$3.vars.fd"; st_forget "$3"; echo "deleted: $3" ;;
      list) for f in "$STATES"/*.qcow2; do   # NAME, bytes on disk, time saved
          [[ -f $f ]] || continue
          printf '%s\t%s\t%s\n' "$(basename "$f" .qcow2)" "$(( $(stat -c %b "$f") * 512 ))" "$(stat -c %Y "$f")"
        done ;;
      *) die "usage: win-venus.sh state save NAME | load NAME [--discard] | rm NAME | list" ;;
    esac ;;
  setup) shift; exec "$HERE/setup-ready.sh" "$@" ;;
  *) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
