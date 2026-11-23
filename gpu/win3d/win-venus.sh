#!/usr/bin/env bash
# win-venus.sh: run the Windows lab VM on a Venus virtual GPU (host Vulkan), rootless and
# outside libvirt. Three disk layers: win11-base (Windows as installed, never written),
# win11-ready on it (the GPU driver and the rest of the ready state: reset returns to it,
# commit writes to it, setup builds it again) and win11-venus on that (this run's changes).
#
#   win-venus.sh start <intel|nvidia> [--window] [--defender]
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
#                                       Without --window: the same window, made hidden, when
#                                       a desktop can be reached (`show` puts it on the screen),
#                                       without sound. No desktop, or WIN_VENUS_HIDDEN_WINDOW=off:
#                                       no window at all. Hidden, Windows is at 1920x1080 and
#                                       100%; shown, it takes the window's pixels and the screen's
#                                       scaling, as at a start with --window.
#                                       With a window either way: the title bar's hide button
#                                       hides it (Windows keeps running), and the VM has an icon
#                                       in the desktop's tray (show or hide, restart, shut down;
#                                       ~/.local/bin/vm-tray).
#                                       Either way the display is also on VNC, 127.0.0.1:5911.
#                                       --defender: Microsoft Defender on in the disk first
#                                       (defender-on.sh; vm then updates its definitions). It
#                                       stays on in this run's disk, and in a state saved from it
#   win-venus.sh show | hide            the window on the screen, or off it (Windows runs on)
#   win-venus.sh window                 the window: shown, hidden, or none (started without one)
#   win-venus.sh stop                   ask Windows to shut down, then stop the helpers
#   win-venus.sh kill                   stop everything now
#   win-venus.sh status                 what is running
#   win-venus.sh ssh [command...]       ssh into the guest (dev@127.0.0.1:2222)
#   win-venus.sh scp SRC... DEST        copy files; the guest is dev@127.0.0.1:PATH
#   win-venus.sh view                   show the window; without one, the VNC console in
#                                       remote-viewer (which resizes Windows to its own size)
#   win-venus.sh shot <file.png>        screenshot the guest display (over VNC)
#   win-venus.sh scale [PERCENT]        Windows' display scaling now, or set it (100, 125, 150...).
#                                       With a window it follows the screen by itself (the
#                                       vmlab-win-venus-scale unit, log /vmlab/run/win-venus/scale.log)
#   win-venus.sh d3d12 [bridge|native|status]
#                                       which d3d12.dll the guest has. native (the lab's default):
#                                       Microsoft's, so Direct3D 12 programs get its software
#                                       adapter (WARP). bridge: the driver package's (vkd3d-proton);
#                                       a program gets a device on this GPU, but nothing that needs a
#                                       composition swap chain draws (guest-scripts/d3d12-mode.ps1).
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
# that socket. Guest: 10.0.2.15, host: 10.0.2.2.
# The lab's build has slirp, so by default (WIN_VENUS_NET=inproc, since 2026-11-23) the VM's own
# QEMU does the network, the shared folder and the SSH port, and no NAT box runs. The guest's
# NIC is the same (MAC, slot) either way. WIN_VENUS_NET=helper: the NAT box, as before.
# The guest has a virtio socket (CID 3) for the vsock agent (../../vsock) when QEMU and
# /dev/vhost-vsock allow it; WIN_VENUS_VSOCK=off: none.
set -euo pipefail

HERE=/vmlab/tools/vmlab/gpu/win3d
QEMU=$HERE/opt/qemu-ui/bin/qemu-system-x86_64
RENDER_SERVER=$HERE/opt/virgl/libexec/virgl_render_server
BASE=/vmlab/images/win11-base.qcow2
READY=${WIN_VENUS_READY:-/vmlab/images/win11-ready.qcow2}   # on BASE; its firmware variables beside it
READY_VARS=${READY%.qcow2}.vars.fd
DISK=${WIN_VENUS_DISK:-/vmlab/images/win11-venus.qcow2}     # on READY
# New overlays and the blank cache disk are made with extended_l2=on: a 4 KiB write to a
# cluster the layer below holds copies 4 KiB of it, not the whole 64 KiB cluster. Files made
# before keep their format; commit, rebase and reflink copies work across the two.
NEW_QCOW2=(-f qcow2 -o extended_l2=on)
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
# The guest driver package, as a CD (D:\Install.cmd): only setup-ready.sh installs from it
# (WIN_VENUS_ISO=on). The package copies itself to C:\ProgramData\vmlab-win3d and runs from
# there, so a normal start has no CD drive.
ISO=$HERE/win3d-guest.iso
SSH_PORT=2222 VNC_DISPLAY=11      # VNC on 127.0.0.1:5911
VCPUS=0-7                         # host CPUs for the guest's CPUs: the fast cores (../pin.py)
# The host folder both VMs see as \\10.0.2.4\qemu (in the guest: C:\share). The QEMU that does
# the network (the VM's own, or the NAT helper with WIN_VENUS_NET=helper) starts a private
# smbd for it at each connection (../share-smbd.sh); the host's own
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
. "$HERE/../window.sh"
# alive NAME: the process in $S/NAME.pid runs and is the QEMU that wrote it (-pidfile with that
# path on its command line). A pid file left by a QEMU that ended without `stop` can name an
# unrelated process after a reboot, and `stop` and `kill` must never signal that one.
# (builtins only, no fork: scale-watch asks four times a second)
alive(){ local p='' a=() x
  { read -r p < "$S/$1.pid"; } 2>/dev/null || true
  [[ $p =~ ^[0-9]+$ ]] || return 1
  { mapfile -d '' -t a < "/proc/$p/cmdline"; } 2>/dev/null || return 1
  for x in "${a[@]}"; do [[ $x == "$S/$1.pid" ]] && return 0; done
  return 1; }
# get VAR FILE: VAR is FILE's first line, '' where there is none, without a fork. Not
# VAR=$(<FILE): bash 5.2 reads that without a fork too, but ends a set -e script where FILE is
# missing, || or not (and $(<FILE 2>/dev/null) forks, and gives nothing).
get(){ printf -v "$1" ''; { read -r "$1" < "$2"; } 2>/dev/null || true; }
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
  local gpu=${1:-} node select layer=() display env=() audio=none window=none a
  case $gpu in
    intel)  node=$(gpu_node 0x8086); select='*intel*' ;;
    nvidia) node=$(gpu_node 0x10de); select='*nvidia*'
      # host-layer/: without it the guest's Direct3D 11 uploads arrive with holes on this laptop
      [[ ${WIN_VENUS_LAYER:-on} == off ]] || layer=(--setenv=VK_LAYER_PATH="$HERE/host-layer"
        --setenv=VK_INSTANCE_LAYERS=VK_LAYER_VMLAB_coherent_memory) ;;
    *) die "usage: win-venus.sh start <intel|nvidia> [--window] [--defender]" ;;
  esac
  shift
  [[ -x $QEMU ]] || die "build QEMU first: $HERE/build-qemu.sh"
  display=(-display "egl-headless,rendernode=$node" -vnc "127.0.0.1:$VNC_DISPLAY")
  # No --window: the window is made all the same, hidden, where a desktop can be reached, so
  # `show` (vm view) can put it on the screen later; a VNC viewer instead resized Windows and
  # broke an agent's clicks. It keeps Windows at 1920x1080 and has no sound, for an agent's run.
  # A QEMU built before qemu-patches/0014 has none of it: the window as before, and no tray.
  local hideable= defender=; grep -aq VMLAB_WINDOW_HIDDEN "$QEMU" && hideable=1
  for a in "$@"; do case $a in
    --window) window=shown ;;
    --defender) defender=1 ;;
    *) die "usage: win-venus.sh start <intel|nvidia> [--window] [--defender]" ;;
  esac; done
  [[ $window == shown || -z $hideable || ${WIN_VENUS_HIDDEN_WINDOW:-on} == off ]] || ! desktop || window=hidden
  case $window in
    shown|hidden) [[ $window == shown ]] && audio=pipewire
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
      # CONTROL and STATE_FILE (qemu-patches/0014): `show` and `hide` reach the window through
      # the FIFO, and it writes shown or hidden to the file; HIDDEN makes it without showing it.
      for a in WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR WAYLAND_DEBUG; do [[ -n ${!a:-} ]] && env+=(--setenv="$a=${!a}"); done
      local size=${WIN_VENUS_WINDOW_SIZE:-first}
      [[ $window == hidden ]] && env+=(--setenv=VMLAB_WINDOW_HIDDEN=1)
      # HIDDEN_SIZE (qemu-patches/0015): while the window is hidden Windows is offered 1920x1080,
      # for an agent's clicks; shown, the window's own size (=first), a guest pixel to a screen
      # pixel. A QEMU built before 0015 cannot change it on showing: 1920x1080 throughout.
      if grep -aq VMLAB_WINDOW_HIDDEN_SIZE "$QEMU"; then env+=(--setenv=VMLAB_WINDOW_HIDDEN_SIZE=1920x1080)
      elif [[ $window == hidden ]]; then size=1920x1080; fi
      env+=(--setenv=VMLAB_WINDOW=1 --setenv=VMLAB_WINDOW_APP_ID=vmlab-win11 --setenv="VMLAB_WINDOW_TITLE=Windows 11" --setenv=VMLAB_WINDOW_CLOSE_POWERS_DOWN=1
        --setenv="VMLAB_WINDOW_FIXED_SIZE=$size" --setenv="VMLAB_WINDOW_SCALE_FILE=$S/scale" --setenv="VMLAB_WINDOW_SIZE_FILE=$S/size"
        --setenv="VMLAB_WINDOW_CONTROL=$S/window.ctl" --setenv="VMLAB_WINDOW_STATE_FILE=$S/window.state")
      # WIN_VENUS_WINDOW_RESTORED=1, for tests: the window opens at QEMU's own size, not maximized.
      [[ -n ${WIN_VENUS_WINDOW_RESTORED:-} ]] || env+=(--setenv=VMLAB_WINDOW_MAXIMIZE=1)
      [[ -n ${WIN_VENUS_WINDOW_X11:-} ]] && env+=(--setenv=GDK_BACKEND=x11)
      ;;
  esac
  local netmode=${WIN_VENUS_NET:-inproc}
  case $netmode in
    helper) ;;
    inproc) "$QEMU" -netdev help 2>/dev/null | grep -qx user || die "WIN_VENUS_NET=inproc: $QEMU has no user-mode network (build-qemu.sh --enable-slirp)" ;;
    *) die "WIN_VENUS_NET is helper or inproc, not '$netmode'" ;;
  esac
  # The guest's CPUs (WIN_VENUS_CPUS=8, the default since 2026-11-23): 4 cores of 2 threads,
  # each on its own fast host CPU (0-7: 4 cores of 2 threads, so the guest's pairs are real
  # pairs), with host-cache-info and hv-avic; the cache disk on an iothread of its own and both
  # disks with a 32 MiB L2 table cache. Measured 2026-11-23, a clean release build of ripgrep
  # without sccache, 3 boots of each in turn, 3 builds a boot: median 27.0 s (24.9-29.6) against
  # 29.3 s (27.5-34.6) for WIN_VENUS_CPUS=6, everything as it was before: 6 cores sharing the
  # fast host CPUs 0-7, one iothread, QEMU's L2 cache. Below, with the Hyper-V enlightenments
  # below plus three more (WIN_VENUS_HV_EXTRA=1, the default since 2026-11-23): direct synthetic
  # timers (they need hv_stimer), hypercall input in XMM registers, extended TLB flush ranges
  # (they need hv_tlbflush). Measured 2026-11-23: a UI Automation read of a window 27-35%
  # faster, builds as fast. WIN_VENUS_HV_EXTRA=0: without them. (3 cores of 2 threads on 0-5,
  # tried the same day, built 10% slower: it gives up a fast core.)
  local cpu=host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_vpindex,hv_runtime,hv_synic,hv_stimer,hv_frequencies,hv_tlbflush,hv_ipi,hv_time
  local smp=6,sockets=1,cores=6,threads=1 vcpus=$VCPUS
  case ${WIN_VENUS_HV_EXTRA:-1} in
    0) ;;
    1) cpu+=,hv-stimer-direct,hv-xmm-input,hv-tlbflush-ext ;;
    *) die "WIN_VENUS_HV_EXTRA is 0 or 1, not '$WIN_VENUS_HV_EXTRA'" ;;
  esac
  local cio=io0 l2=''
  case ${WIN_VENUS_CPUS:-8} in
    6) ;;
    8) smp=8,sockets=1,cores=4,threads=2 cpu+=,host-cache-info=on,hv-avic cio=io1 l2=,l2-cache-size=33554432 ;;
    *) die "WIN_VENUS_CPUS is 8 or 6, not '$WIN_VENUS_CPUS'" ;;
  esac
  [[ -n $node ]] || die "no $gpu render node"
  alive qemu && die "already running (win-venus.sh stop)"
  [[ $(virsh -c qemu:///system list --name | grep -c .) == 0 ]] || die "a libvirt VM is running: one VM at a time"
  { systemctl --user is-active --quiet vmlab-mac26 || systemctl --user is-active --quiet vmlab-mac26d; } && die "a mac26 VM is running: one VM at a time"
  mkdir -p "$S"
  [[ -f $READY ]] || die "no ready state ($READY): win-venus.sh setup"
  [[ -f $DISK ]] || qemu-img create -q "${NEW_QCOW2[@]}" -F qcow2 -b "$READY" "$DISK"
  # .defender: the disk has Defender on (save and load carry it to and from NAME.defender)
  [[ -z $defender ]] || { "$HERE/defender-on.sh" "$DISK" >&2 && : > "$STATES/.defender"; } || die "Defender was not turned on: not started"
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
  systemctl --user stop vmlab-tray-win 2>/dev/null || true
  rm -f "$S"/{net,qmp,ga}.sock "$S"/{net,qemu}.pid "$S/size" "$S/window.ctl" "$S/window.state"; : > "$S/qemu.log"; : > "$S/net.log"
  [[ $window == none || -z $hideable ]] || mkfifo -m 600 "$S/window.ctl"
  # Both run as transient user units, so they outlive the terminal or app that started them,
  # and QEMU's stderr (the render server's messages too) lands in qemu.log.
  local smb='' slirp='' net=()
  if [[ $SHARE != off && -x /usr/sbin/smbd ]]; then    # (../share-smbd.sh says why not smb=)
    mkdir -p "$SHARE"; rm -rf "$S/smb"; smb=",guestfwd=tcp:10.0.2.4:445-cmd:$HERE/../share-smbd.sh $SHARE $S/smb"
  fi
  # The guest's network: slirp, with the SSH port and the shared folder (WIN_VENUS_NET above)
  slirp="net=10.0.2.0/24,dhcpstart=10.0.2.15,hostfwd=tcp:127.0.0.1:$SSH_PORT-10.0.2.15:22$smb"
  if [[ $netmode == inproc ]]; then
    net=(-netdev "user,id=n,$slirp")
  else
    unit vmlab-win-venus-net "$S/net.log" \
      /usr/bin/qemu-system-x86_64 -name win-venus-net -machine none -nodefaults -display none \
      -netdev "user,id=u,$slirp" \
      -netdev "stream,id=s,server=on,addr.type=unix,addr.path=$S/net.sock" \
      -netdev hubport,id=h0,hubid=0,netdev=u -netdev hubport,id=h1,hubid=0,netdev=s \
      -pidfile "$S/net.pid"
    up net || die "the NAT helper did not start: $(cat "$S/net.log")"
    net=(-netdev "stream,id=n,server=off,addr.type=unix,addr.path=$S/net.sock")
  fi

  local cache=()
  if [[ $CACHE != off ]]; then
    mkdir -p "$CACHE"
    if [[ ! -f $CACHE/win.qcow2 ]]; then
      if [[ -f $CACHE_EMPTY ]]; then cp "$CACHE_EMPTY" "$CACHE/win.qcow2"; else qemu-img create -q "${NEW_QCOW2[@]}" "$CACHE/win.qcow2" 25G; fi
    fi
    cache=(-blockdev "driver=qcow2,node-name=cache0,cache.direct=on,discard=unmap$l2,file.driver=file,file.aio=io_uring,file.filename=$CACHE/win.qcow2"
      -device virtio-blk-pci,drive=cache0,serial=vmlabcache,iothread=$cio,addr=2)
    [[ $cio == io0 ]] || cache=(-object iothread,id=$cio "${cache[@]}")
  fi

  # (the CD is on the q35 board's own SATA controller, so it moves no PCI slot)
  local cdrom=()
  if [[ ${WIN_VENUS_ISO:-off} == on ]]; then
    [[ -f $ISO ]] || die "no $ISO"
    cdrom=(-drive if=none,id=cd0,media=cdrom,readonly=on,format=raw,file="$ISO" -device ide-cd,drive=cd0)
  fi

  # The vsock control channel (../../vsock: vmlab-agent in Windows, vmlab-vx here): a virtio
  # socket, CID 3, in slot 8. /dev/vhost-vsock is the kvm group's. A QEMU without vhost (built
  # before build-qemu.sh had --enable-vhost-kernel) has no such device; then the VM starts
  # without it, and vmlab-vx falls back to SSH. WIN_VENUS_VSOCK=off leaves it out.
  local vsock=()
  if [[ ${WIN_VENUS_VSOCK:-on} == on && -r /dev/vhost-vsock && -w /dev/vhost-vsock &&
        $("$QEMU" -device help 2>/dev/null) == *'"vhost-vsock-pci"'* ]]; then
    vsock=(-device vhost-vsock-pci,guest-cid=3,addr=8)
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
    -cpu "$cpu" \
    -smp "$smp" -m 8192M -rtc base=localtime,driftfix=slew \
    -drive if=pflash,format=raw,readonly=on,file="$(firmware)" \
    -drive if=pflash,format=raw,file="$S/OVMF_VARS.fd" \
    -object iothread,id=io0 \
    -blockdev "driver=qcow2,node-name=disk0,cache.direct=on,discard=unmap$l2,file.driver=file,file.aio=io_uring,file.filename=$DISK" \
    -device virtio-blk-pci,drive=disk0,bootindex=1,iothread=io0,addr=1 "${cache[@]}" \
    "${cdrom[@]}" "${vsock[@]}" \
    "${net[@]}" \
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
  for _ in $(seq 20); do python3 -I "$HERE/../pin.py" "$S/qmp.sock" "$vcpus" 2>/dev/null && break; sleep 0.5; done
  # With a window, Windows' own scaling follows the screen the window is on while it is shown,
  # and is 100% while it is hidden (scale-watch below)
  # (a unit has none of this shell's environment: the switch is handed on)
  local scale_env=(--setenv="WIN_VENUS_SCALE_DIRECT=${WIN_VENUS_SCALE_DIRECT:-1}")
  [[ $window == none ]] || unit vmlab-win-venus-scale "$S/scale.log" "${scale_env[@]}" "$0" scale-watch
  [[ $window == none || -z $hideable ]] || tray win vmlab-win-venus "$S/window.state"
  echo "started on $gpu ($node): ssh port $SSH_PORT, VNC 127.0.0.1:$((5900 + VNC_DISPLAY))$([[ $window == none ]] || echo ", a window ($window)"), log $S/qemu.log"
}
# unit NAME LOG [systemd-run options...] COMMAND...: run COMMAND as a transient user unit
unit(){ local name=$1 log=$2; shift 2
  systemctl --user reset-failed "$name" 2>/dev/null || true
  systemd-run --user --quiet --collect --unit="$name" -p StandardOutput="append:$log" -p StandardError="append:$log" "$@"; }
up(){ for _ in $(seq 20); do alive "$1" && return 0; sleep 0.5; done; return 1; }
gpu_node(){ local d; for d in /sys/class/drm/renderD*; do [[ $(cat "$d/device/vendor") == "$1" ]] && { echo "/dev/dri/${d##*/}"; return; }; done; }
stop_helpers(){ alive net && kill "$(cat "$S/net.pid")"; rm -f "$S"/net.pid; systemctl --user stop vmlab-win-venus-scale 2>/dev/null || true; mux_close; }
stop(){
  if alive qemu; then
    qmp '{"execute":"system_powerdown"}' > /dev/null || true
    for _ in $(seq 240); do alive qemu || break; sleep 0.5; done
    alive qemu && { echo "guest did not shut down in 2 min, stopping it"; kill "$(cat "$S/qemu.pid")"; }
  fi
  # (its unit ends a moment after QEMU: `vm` and the other VM's launcher go by the unit)
  for _ in $(seq 20); do systemctl --user is-active --quiet vmlab-win-venus || break; sleep 0.5; done
  rm -f "$S/qemu.pid"; stop_helpers; echo stopped
}
# Commands here are PowerShell: VMLAB_SHELL=pwsh asks the guest's vmshell for it (its default is
# Git Bash; a guest from before vmshell ignores the variable).
ssh_guest(){ ssh "${MUX[@]}" -i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$S/known_hosts" \
  -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR -o SetEnv=VMLAB_SHELL=pwsh dev@127.0.0.1 "$@"; }
# scp_guest asks for PowerShell too: with MUX the first call opens the shared connection, and
# every later session on it gets the SetEnv of the one that opened it.
scp_guest(){ scp -q "${MUX[@]}" -i "$KEY" -P "$SSH_PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$S/known_hosts" -o LogLevel=ERROR -o SetEnv=VMLAB_SHELL=pwsh "$@"; }
# MUX: none by default. scale-watch (WIN_VENUS_SCALE_DIRECT=1, its default) sets it to one connection
# shared by its calls (ControlMaster, as `vm` keeps one), so a call skips the key exchange. Its
# own socket: a session over a shared connection gets the SetEnv of the one that opened it
# (~/.local/bin/vm says so too), and these are all PowerShell. Keepalives, so a master left on a
# Windows that went away ends by itself; stop_helpers closes it.
MUX=()
MUX_SOCK=$S/ssh-pwsh-$SSH_PORT
mux_on(){ MUX=(-o ControlMaster=auto -o "ControlPath=$MUX_SOCK" -o ControlPersist=120 -o ServerAliveInterval=5 -o ServerAliveCountMax=3); }
# ssh_bash, scp_bash: Git Bash, for vmlab-display.exe (scale-watch, where guest-bin/ has it).
# Git Bash because a session must have a shell (vmshell starts one for each), the program needs
# none of PowerShell, and Git Bash is the cheap one: its start is a few tens of milliseconds,
# pwsh's most of a second. vmshell gives Git Bash to a session without VMLAB_SHELL; over MUX's
# connection every session would get pwsh, the shell that connection was opened with, so this
# is a second shared connection of its own, opened without SetEnv (as `vm` keeps
# ssh-%p and ssh-pwsh-%p apart).
BASH_SOCK=$S/ssh-bash-$SSH_PORT
BASH_MUX=(-o ControlMaster=auto -o "ControlPath=$BASH_SOCK" -o ControlPersist=120 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
ssh_bash(){ ssh "${BASH_MUX[@]}" -i "$KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$S/known_hosts" \
  -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR dev@127.0.0.1 "$@"; }
scp_bash(){ scp -q "${BASH_MUX[@]}" -i "$KEY" -P "$SSH_PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$S/known_hosts" -o LogLevel=ERROR "$@"; }
mux_close(){ local s
  for s in "$MUX_SOCK" "$BASH_SOCK"; do
    [[ -S $s ]] || continue
    ssh -o "ControlPath=$s" -O exit dev@127.0.0.1 > /dev/null 2>&1 || true; rm -f "$s"
  done; return 0; }

# guest_display SIZE PERCENT ALWAYS (scale-watch): the mode SIZE and then the scaling PERCENT in
# one SSH command, run in the SSH session itself: since desktop-ssh (346efb2) that is dev's
# desktop session, so no scheduled task (run-interactive.ps1) is needed. With DISPLAY_EXE set
# (scale-watch copied guest-bin/vmlab-display.exe to C:\vmlab) that program does both, through
# Git Bash (ssh_bash): about 50 ms for a call that changes nothing, 0.2 s for a new scaling.
# Else set-mode.ps1 and set-scale.ps1 in pwsh, about 3.6 s in Windows either way.
# Empty SIZE or PERCENT: that part is not run; the scale runs after the mode only when ALWAYS
# is set or the mode was set (Windows keeps a scaling for each size). It prints "@mode RC LINE"
# and "@scale RC LINE" (the step's exit code and last line), or "@desktop no" where the
# session is not on the desktop (an older state), and scale-watch goes back to the task.
DISPLAY_EXE=''
guest_display(){
  [[ $1 =~ ^([0-9]+x[0-9]+)?$ && $2 =~ ^[0-9]*$ && $3 =~ ^1?$ ]] || return 2
  if [[ -n $DISPLAY_EXE ]]; then
    local a=()
    [[ -z $1 ]] || a+=(--mode "$1")
    [[ -z $2 ]] || a+=(--scale "$2")
    [[ -z $3 ]] || a+=(--scale-always)
    ssh_bash C:/vmlab/vmlab-display.exe "${a[@]}"; return
  fi
  ssh_guest <<PS1
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { '@desktop no'; exit 3 }
\$rcs = @{}
function Step(\$tag, \$file, \$arg) {
    \$global:LASTEXITCODE = 0
    try { \$o = @(& \$file \$arg 2>&1); \$rc = [int]\$global:LASTEXITCODE }
    catch { \$o = @("\$_"); \$rc = 1 }
    \$last = if (\$o.Count) { "\$(\$o[-1])" } else { '' }
    "@\$tag \$rc \$last"
    \$script:rcs[\$tag] = \$rc
}
if ('$1') { Step mode C:\vmlab\set-mode.ps1 '$1' }
if ('$2' -and ('$3' -or \$rcs['mode'] -eq 0)) { Step scale C:\vmlab\set-scale.ps1 ([int]'$2') }
exit 0
PS1
}
# nap SECONDS: sleep, without a fork once NAP_FD is open (scale-watch: a pipe nobody writes,
# which read waits on until it times out); sleep(1) where that read did not wait
NAP_FD=''
nap(){ local x
  if [[ -n $NAP_FD ]]; then read -rt "$1" -u "$NAP_FD" x && return 0; (( $? > 128 )) && return 0; fi
  sleep "$1"; }

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
  start) shift; start "$@" ;;
  # Internal, a unit of its own beside a windowed VM: QEMU keeps $S/scale at the scale, in
  # percent, of the screen its window is on (VMLAB_WINDOW_SCALE_FILE), and gives Windows that
  # screen's pixels of the window. This gives Windows the same scaling, so that things in it
  # are as large as on the host. It ends with QEMU.
  scale-watch)
    applied='' copied='' sized='' tries=0 direct='' exe=''
    # By default one shared SSH connection, and the mode and the scale in one command on the
    # desktop (guest_display), the scheduled task only where SSH is not there. The command is
    # guest-bin/vmlab-display.exe where build.sh has made it (vmlab-display/), else the two
    # scripts in pwsh (measured 2026-11-23 in the nested rig at 125%: the scale follows a show
    # or hide in 1.6-4.8 s, against 6.2-7.8 s through the task; most of it is the call in
    # Windows, about 3.6 s for the mode and the scale, where the program takes 0.05-0.2 s).
    # WIN_VENUS_SCALE_DIRECT=0: always the task, as before.
    if [[ ${WIN_VENUS_SCALE_DIRECT:-1} == 1 ]]; then
      direct=1; mux_close; mux_on      # (a connection left by an earlier run would hang)
      [[ -f $HERE/guest-bin/vmlab-display.exe ]] && exe=$HERE/guest-bin/vmlab-display.exe
      exec {NAP_FD}<> <(:)             # (for nap)
      echo "$(date +%T) direct: one SSH connection, no scheduled task, $([[ -n $exe ]] && echo vmlab-display.exe || echo 'the PowerShell scripts')"
    fi
    while alive qemu; do
      # A check four times a second, with builtins only (get, alive, nap): a pass that finds
      # nothing to do starts no process. After a call that left something to do (the mode
      # not there yet, nobody signed in, no SSH yet while Windows starts) 2 s, as before, so
      # a mode Windows lacks still has 20 tries over 40 s or more.
      if [[ -n $direct ]]; then
        get size "$S/size"; get shown "$S/window.state"; get screen "$S/scale"
        want=100; [[ $shown == hidden ]] || want=$screen
        m=''; [[ $size =~ ^[0-9]+x[0-9]+$ && $size != "$sized" ]] && m=$size
        p=''; [[ $want =~ ^[0-9]+$ ]] && p=$want
        always=''; [[ -n $p && $p != "$applied" ]] && always=1
        pause=0.25
        if [[ -n $m || -n $always ]]; then
          # Once: the program (with Git Bash's connection, which then runs it) and the scripts,
          # which the task needs if this state's SSH turns out not to be on the desktop
          if [[ -z $copied && -n $exe ]]; then
            scp_bash "$exe" "$HERE/guest-scripts/set-scale.ps1" "$HERE/guest-scripts/set-mode.ps1" dev@127.0.0.1:C:/vmlab/ 2>/dev/null && copied=1 DISPLAY_EXE=1
          elif [[ -z $copied ]]; then
            scp_guest "$HERE/guest-scripts/set-scale.ps1" "$HERE/guest-scripts/set-mode.ps1" dev@127.0.0.1:C:/vmlab/ 2>/dev/null && copied=1
          fi
          pause=2
          if [[ -n $copied ]]; then
            t0=${EPOCHREALTIME/./}
            out=$(guest_display "$m" "$p" "$always" 2>&1) || true
            t0=$(( (${EPOCHREALTIME/./} - t0) / 100000 )); took="$((t0 / 10)).$((t0 % 10)) s"
            if grep -qx '@desktop no' <<< "$out"; then
              direct=''; echo "$(date +%T) direct: SSH is not on the desktop in this state; the scheduled task from now on"; continue
            fi
            mline=$(grep -m1 '^@mode ' <<< "$out" || true) sline=$(grep -m1 '^@scale ' <<< "$out" || true)
            if [[ -n $m ]]; then
              if [[ $mline == '@mode 0 '* ]]; then
                sized=$m applied='' tries=0; echo "$(date +%T) window size $m: ${mline#@mode 0 } ($took)"
              elif (( ++tries >= 20 )); then   # nobody signed in, or Windows has no such mode
                msg=${mline#@mode * }; sized=$m tries=0; echo "$(date +%T) window size $m: not set: ${msg:-${out##*$'\n'}}"
              fi
            fi
            [[ $sline == '@scale 0 '* ]] && { applied=$p; echo "$(date +%T) screen scale $p%: ${sline#@scale 0 } ($took)"; }
            [[ (-n $m && $m != "$sized") || (-n $p && $p != "$applied") ]] || pause=0.25
          fi
        fi
        nap "$pause"; continue
      fi
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
      want=100      # hidden: the size and scaling an agent's run expects
      [[ $(cat "$S/window.state" 2>/dev/null) == hidden ]] || want=$(cat "$S/scale" 2>/dev/null || true)
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
  scp) shift; scp_guest "$@" ;;
  show|hide) alive qemu || die "not running"; window_ask "$1" "$S/window.ctl" "$S/window.state" ;;
  window) alive qemu && [[ -p $S/window.ctl ]] && cat "$S/window.state" 2>/dev/null || echo none ;;
  view) if alive qemu && [[ -p $S/window.ctl ]]; then window_ask show "$S/window.ctl" "$S/window.state"
        else exec remote-viewer "vnc://127.0.0.1:$((5900 + VNC_DISPLAY))"; fi ;;
  # over VNC, which works with any build (qemu-patches/0017 gives QMP's screendump the picture too)
  shot) [[ -n ${2:-} ]] || die "usage: win-venus.sh shot <file.png>"; python3 -I "$HERE/vncshot.py" $((5900 + VNC_DISPLAY)) "$2" ;;
  d3d12) [[ ${2:-status} =~ ^(native|bridge|status)$ ]] || die "usage: win-venus.sh d3d12 [bridge|native|status]"
    "$0" scp "$HERE/guest-scripts/d3d12-mode.ps1" dev@127.0.0.1:C:/vmlab/
    ssh_guest "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\vmlab\\d3d12-mode.ps1 ${2:-status}" ;;
  reset) alive qemu && die "stop it first"; st_guard "${2:-}"
    rm -f "$DISK" "$S/OVMF_VARS.fd" "$STATES/.defender"; st_mark clean
    echo "this run's changes dropped: the next start is the ready state" ;;
  commit) alive qemu && die "stop it first"
    [[ ${2:-} =~ ^(|--keep-states|--drop-states)$ ]] || die "usage: win-venus.sh commit [--keep-states|--drop-states]"
    [[ ${2:-} != --keep-states ]] || states_release   # what an earlier commit left unmoved
    [[ -f $DISK && -f $READY ]] || die "nothing to commit"
    # Defender would scan every file a build writes, and once it has run, Windows does not let
    # it be turned off again: the default state keeps it off
    [[ ! -e $STATES/.defender ]] || die "this run has Defender on (started with --defender): the default state keeps it off. 'vm reset win' drops the run"
    # The named states are changes to READY as it is now: on another READY they are a broken disk
    if compgen -G "$STATES/*.qcow2" > /dev/null; then
      case ${2:-} in
        --keep-states) states_hold ;;
        --drop-states) rm -f "$STATES"/*.qcow2 "$STATES"/*.vars.fd "$STATES"/*.note "$STATES"/*.defender "$READY_HELD" ;;
        *) die "the ready state has named states on it, which a commit alone makes unusable: $(state_names). Commit with --keep-states (they stay as they are and grow by what the commit changed) or --drop-states (they are deleted)" ;;
      esac
    fi
    qemu-img commit -q "$DISK"; rm -f "$DISK"
    [[ -f $S/OVMF_VARS.fd ]] && cp "$S/OVMF_VARS.fd" "$READY_VARS"
    st_mark clean
    [[ ${2:-} != --keep-states ]] || states_release
    echo "committed: $READY is the ready state" ;;
  state) alive qemu && [[ ${2:-} != list && ${2:-} != rm && ${2:-} != default-size ]] && die "stop it first"
    case ${2:-} in
      save) st_valid "${3:-}"; mkdir -p "$STATES" "$S"
        [[ -f $DISK ]] || qemu-img create -q "${NEW_QCOW2[@]}" -F qcow2 -b "$READY" "$DISK"   # nothing ran: the ready state itself
        cp --reflink=auto "$DISK" "$STATES/$3.qcow2.new"; mv "$STATES/$3.qcow2.new" "$STATES/$3.qcow2"
        cp "$([[ -f $S/OVMF_VARS.fd ]] && echo "$S/OVMF_VARS.fd" || echo "$READY_VARS")" "$STATES/$3.vars.fd"
        if [[ -e $STATES/.defender ]]; then : > "$STATES/$3.defender"; else rm -f "$STATES/$3.defender"; fi
        st_mark "$3"; echo "saved: $3" ;;
      load) st_valid "${3:-}"; [[ -f $STATES/$3.qcow2 ]] || die "no state '$3' ($(state_names))"
        st_guard "${4:-}"; mkdir -p "$S"
        cp --reflink=auto "$STATES/$3.qcow2" "$DISK.new"; mv "$DISK.new" "$DISK"
        cp "$STATES/$3.vars.fd" "$S/OVMF_VARS.fd"
        if [[ -e $STATES/$3.defender ]]; then : > "$STATES/.defender"; else rm -f "$STATES/.defender"; fi
        st_mark "$3"; echo "loaded: $3" ;;
      rm) st_valid "${3:-}"; [[ -f $STATES/$3.qcow2 ]] || die "no state '$3' ($(state_names))"
        rm -f "$STATES/$3.qcow2" "$STATES/$3.vars.fd" "$STATES/$3.defender"; st_forget "$3"; echo "deleted: $3" ;;
      list) for f in "$STATES"/*.qcow2; do   # NAME, bytes on disk, time saved
          [[ -f $f ]] || continue
          printf '%s\t%s\t%s\n' "$(basename "$f" .qcow2)" "$(( $(stat -c %b "$f") * 512 ))" "$(stat -c %Y "$f")"
        done ;;
      default-size) # bytes on disk of the default (clean) state: the installed base and the ready layer on it
        echo $(( ($(stat -c %b "$BASE") + $(stat -c %b "$READY")) * 512 )) ;;
      *) die "usage: win-venus.sh state save NAME | load NAME [--discard] | rm NAME | list | default-size" ;;
    esac ;;
  setup) shift; exec "$HERE/setup-ready.sh" "$@" ;;
  *) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
