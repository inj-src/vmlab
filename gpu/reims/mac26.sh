#!/usr/bin/env bash
# mac26.sh: run the macOS 26 lab VM on reims-vgpu (Metal on the RTX 4050), as a user unit. It
# counts as "a VM" for one-VM-at-a-time.
#
#   mac26.sh start [--window]             boot and wait for SSH
#                                           --window: on the user's screen, maximized (closing
#                                             it powers off). macOS takes the maximized
#                                             window's pixels (1920x1048 on the 1920x1080
#                                             monitor) and keeps them: a resize scales the
#                                             picture. Maximized on a screen of another scale
#                                             (the laptop's 125% panel) it takes that screen's
#                                             pixels, so the picture is sharp on both.
#                                             The title bar's round button, or Ctrl+Alt+F,
#                                             fills the screen; Ctrl+Alt+F leaves it. Text and
#                                             pictures copied on either side paste on the
#                                             other; files dragged onto the window land on the
#                                             guest's desktop (the guest's vmlab-spice-agent,
#                                             ../../mac/spice-agent).
#                                           Without a window, 1920x1080
#   mac26.sh stop                         shut macOS down
#   mac26.sh kill                         power off now
#   mac26.sh status                       running or not, and why QEMU ended if reims ended it
#   mac26.sh ssh [command...]             dev@127.0.0.1 (password vmlab, passwordless sudo)
#   mac26.sh scp SRC... DEST              copy files; the guest is dev@127.0.0.1:PATH
#   mac26.sh gui shot FILE.png | click X Y | type 'text' | key cmd+q ...   (qdrive.py)
#   mac26.sh reset                        back to the clean snapshot
#   mac26.sh commit                       make the disk as it is the clean snapshot
#
# The VM is mac26d, port 2227, on reims' `development` branch with the lab's patches
# (/vmlab/reims-dev, ../README.md). reims' `master` does not run macOS 26.7.1 here.
# Switches:
#   MAC26_WINDOW_SIZE=first|WxH|follow   the window. first (default): above. A size such as
#                                        1920x1080: macOS's whatever the window's, scaled into
#                                        it. follow: reims' own, every resize a new resolution
#   MAC26_WINDOW_X11=1                   the window under XWayland (it is Wayland's own
#                                        otherwise): xdotool and xwininfo can measure and
#                                        resize it, and it is soft on a scaled screen (../README.md)
#   MAC26_DISK=virtio|sata               the system disk; virtio is the default and six times
#                                        faster on small reads
#   MAC26_FIRMWARE=stock                 reims' firmware as it is (TianoCore's logo at the
#                                        start); otherwise a quiet copy of it, a black screen
#   MAC26_SHARE=DIR|off                  the host folder macOS sees as smb://10.0.2.4/qemu
#                                        (in the guest: ~/share). Default /vmlab/share, the
#                                        same folder as the Windows VM's. QEMU starts a
#                                        private smbd for it (-netdev user,smb=); the host's
#                                        own Samba services are masked.
#   MAC26_HUGE_PAGES=on, MAC26_CPU_EXTRA=+flag,...
#   MAC26_LOG, MAC26_STATS, MAC26_TRACE  for diagnosis (../README.md)
set -euo pipefail

R=/vmlab/reims-dev/bin/reims NAME=mac26d PORT=2227
V=${R%/bin/reims}/data/reims-ctl/vms/$NAME
UNIT=vmlab-$NAME
KEY=$HOME/.ssh/vmlab_ed25519
VCPUS=0-7                     # host CPUs for the guest's CPUs: the fast cores (../pin.py)
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$V/known_hosts"
  -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)

die(){ echo "mac26: $*" >&2; exit 1; }
alive(){ systemctl --user is-active --quiet "$UNIT"; }
guest(){ ssh "${SSH_OPTS[@]}" -p "$PORT" dev@127.0.0.1 "$@"; }
stopped(){ alive && die "stop it first (mac26.sh stop)"; return 0; }

start(){
  local window=0 a
  for a in "$@"; do case $a in
    --window) window=1 ;;
    *) die "usage: mac26.sh start [--window]" ;;
  esac; done
  alive && die "already running"
  [[ $(virsh -c qemu:///system list --name | grep -c .) == 0 ]] || die "a libvirt VM is running: one VM at a time"
  systemctl --user is-active --quiet vmlab-win-venus && die "the Windows GPU VM is running: one VM at a time"

  # reims prints the QEMU command for the VM's current settings; some lines of it change here
  mkdir -p "$V/logs"
  "$R" command "$NAME" -o "$V/run.sh" > /dev/null
  # The system disk as virtio-blk on a thread of its own, in place of reims' emulated SATA disk:
  # small reads take 29 us, not 183, and cold app launches a fifth less time (../README.md).
  # macOS has the driver. MAC26_DISK=sata keeps reims' line.
  local disk=${MAC26_DISK:-virtio}
  if [[ $disk == virtio ]]; then
    sed -i "s|^  -device 'ide-hd,bus=sata.3,drive=disk,rotation_rate=1' \\\\\$|  -object 'iothread,id=io0' \\\\\n  -device 'virtio-blk-pci,drive=disk,iothread=io0,addr=0x8' \\\\|" "$V/run.sh"
    grep -q "virtio-blk-pci,drive=disk" "$V/run.sh" || die "could not make the disk virtio-blk in run.sh"
  fi
  # The channel to the guest's agent (vmlab-spice-agent: clipboard and dropped files), a
  # virtio serial port named as SPICE's. Its host end is a socket the window connects to
  # (VMLAB_AGENT_SOCKET below; our agent.rs in reims' window code).
  rm -f "$V/agent.sock"
  sed -i "s|^  -display none \\\\\$|  -device 'virtio-serial-pci,id=vser,addr=0x9' \\\\\n  -chardev 'socket,id=agent,path=$V/agent.sock,server=on,wait=off' \\\\\n  -device 'virtserialport,chardev=agent,name=com.redhat.spice.0' \\\\\n&|" "$V/run.sh"
  grep -q "virtserialport,chardev=agent" "$V/run.sh" || die "could not add the agent's channel to run.sh"
  # The firmware with a quiet start, as the Windows VM's (../win3d/firmware/make-firmware.py):
  # no TianoCore logo and no "BdsDxe: loading Boot..." lines, so the screen stays black until
  # macOS draws. reims' own OVMF_CODE.fd stays as it is; the quiet one is made from it, and
  # again when it changes. MAC26_FIRMWARE=stock keeps reims' line.
  if [[ ${MAC26_FIRMWARE:-} != stock ]]; then
    local fw=$V/OVMF_CODE.fd quiet=$V/OVMF_CODE.vmlab.fd
    if [[ ! -f $quiet || $(cat "$quiet.sha256" 2>/dev/null) != $(sha256sum "$fw" | cut -d' ' -f1) ]]; then
      python3 "$(dirname "$(readlink -f "$0")")/../win3d/firmware/make-firmware.py" "$fw" "$quiet" \
        > "$V/logs/firmware.log" 2>&1 || rm -f "$quiet"
    fi
    if [[ -f $quiet ]]; then
      sed -i "s|file=$fw'|file=$quiet'|" "$V/run.sh"
      grep -q "file=$quiet'" "$V/run.sh" || die "could not give run.sh the quiet firmware"
    else
      echo "mac26: no quiet firmware ($V/logs/firmware.log): TianoCore's logo will show" >&2
    fi
  fi
  local share=${MAC26_SHARE:-/vmlab/share}
  if [[ $share != off && -x /usr/sbin/smbd ]]; then
    mkdir -p "$share"
    sed -i "s|^\(  -netdev 'user,id=net0,[^']*\)'|\1,smb=$share'|" "$V/run.sh"
    grep -q ",smb=$share'" "$V/run.sh" || die "could not give run.sh the shared folder"
  fi
  # MAC26_CPU_EXTRA: more flags for the guest CPU, e.g. +sha-ni
  [[ -n ${MAC26_CPU_EXTRA:-} ]] && sed -i "s|^\(  -cpu '[^']*\),check'|\1,$MAC26_CPU_EXTRA,check'|" "$V/run.sh"
  # For diagnosis: MAC26_LOG replaces reims' log filter (its timing lines:
  # warn,reims_vgpu_vulkan::gpu::timing=debug), MAC26_STATS=1 adds a line of frame statistics a second.
  [[ -n ${MAC26_LOG:-} ]] && sed -i "s|^export REIMS_VGPU_LOG=.*|export REIMS_VGPU_LOG=$MAC26_LOG|" "$V/run.sh"
  [[ -n ${MAC26_STATS:-} ]] && sed -i 's|^export REIMS_VGPU_LOG=|export REIMS_VGPU_STATS=1\n&|' "$V/run.sh"
  # MAC26_TRACE=FILE: reims' timeline of guest doorbells, interrupts, commits and presents (large).
  [[ -n ${MAC26_TRACE:-} ]] && sed -i "s|^export REIMS_VGPU_LOG=|export REIMS_VGPU_TRACE=$MAC26_TRACE\n&|" "$V/run.sh"
  local env=()
  if (( window )); then
    for a in WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR; do [[ -n ${!a:-} ]] && env+=(--setenv="$a=${!a}"); done
    # As the user asked for both VMs: the window opens maximized (our switch in reims' window
    # code, ../README.md).
    # SDL_APP_ID: the desktop's icon for the window (vmlab-macos26.desktop); _TITLE: its
    # title (also ours). VMLAB_AGENT_SOCKET: the clipboard and file drop (above).
    env+=(--setenv=REIMS_VGPU_WINDOW_MAXIMIZED=1 --setenv=SDL_APP_ID=vmlab-macos26
      --setenv="REIMS_VGPU_WINDOW_TITLE=macOS 26 Tahoe" --setenv="VMLAB_AGENT_SOCKET=$V/agent.sock")
    # The guest keeps the resolution it starts with (our switch too, ../README.md): reims' own
    # window makes every resize a new macOS resolution.
    env+=(--setenv="REIMS_VGPU_WINDOW_MODE=${MAC26_WINDOW_SIZE:-first}")
    # The window is Wayland's own (SDL alone would pick XWayland here, mutter 46 having no
    # fifo-v1): on a scaled screen (the laptop's panel, 125%) mutter 46 stretches an XWayland
    # window, and only a Wayland one gets the screen's own pixels. Three things make it safe
    # (../README.md):
    # - the title bar is drawn by libdecor's cairo plugin, in the lab's build that looks like
    #   the desktop's own title bars and has the full screen button (./libdecor-cairo, built by
    #   ./libdecor-vmlab/build.sh). The GTK plugin that is installed runs GTK on reims' UI
    #   thread while QEMU's main thread runs GTK's callbacks, and QEMU ends with a segfault
    #   (in libcanberra-gtk3-module.so, 5 s after the window opens).
    # - the lab's SDL does not export its windows (xdg-foreign; ./sdl3-src-3.4.18-vmlab): with
    #   the export, a QEMU that ends without cleaning up crashes mutter 46.2, which on the
    #   real desktop ends the whole session.
    # - macOS takes the maximized window's pixels, again on a screen of another scale
    #   (REIMS_VGPU_WINDOW_MODE=first).
    # MAC26_WINDOW_X11=1: the window under XWayland (softer on a scaled screen).
    if [[ -n ${MAC26_WINDOW_X11:-} ]]; then
      env+=(--setenv=SDL_VIDEO_DRIVER=x11)
    elif [[ -n ${WAYLAND_DISPLAY:-} ]]; then
      # the title's font is the desktop's, as GTK's title bars have it
      local font aa
      font=$(gsettings get org.gnome.desktop.interface font-name 2>/dev/null | tr -d "'" || true)
      aa=$(gsettings get org.gnome.desktop.interface font-antialiasing 2>/dev/null | tr -d "'" || true)
      env+=(--setenv=SDL_VIDEO_DRIVER=wayland
        --setenv="LIBDECOR_PLUGIN_DIR=$(dirname "$(readlink -f "$0")")/libdecor-cairo"
        --setenv="VMLAB_DECOR_FONT=${font:-Ubuntu Sans 11}" --setenv="VMLAB_DECOR_FONT_AA=${aa:-rgba}")
    fi
    # MAC26_WAYLAND_DEBUG=1, for tests: libwayland's trace of the window's requests in qemu.log.
    [[ -n ${MAC26_WAYLAND_DEBUG:-} ]] && env+=(--setenv=WAYLAND_DEBUG=1)
    # MAC26_SDL_XDG_EXPORT=1, for tests in a nested compositor ONLY: SDL exports the window
    # again, to see the compositor crash it causes. Never on the real desktop.
    [[ -n ${MAC26_SDL_XDG_EXPORT:-} ]] && env+=(--setenv=VMLAB_SDL_XDG_EXPORT=1)
  else
    sed -i 's|^unset REIMS_VGPU_WINDOW.*|export REIMS_VGPU_WINDOW=0|' "$V/run.sh"
    grep -q '^export REIMS_VGPU_WINDOW=0' "$V/run.sh" || die "could not make run.sh headless"
  fi

  # No huge pages for guest RAM (prctl 41 is PR_SET_THP_DISABLE, kept across exec): with them
  # reims ends the VM at about every second boot here (../README.md). MAC26_HUGE_PAGES=on tries.
  local thp=(python3 -I -c 'import ctypes,os,sys; ctypes.CDLL(None).prctl(41,1,0,0,0); os.execv(sys.argv[1],sys.argv[1:])')
  [[ ${MAC26_HUGE_PAGES:-off} == on ]] && thp=()
  : > "$V/logs/qemu.log"
  systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  systemd-run --user --quiet --collect --unit="$UNIT" "${env[@]}" \
    -p StandardOutput="append:$V/logs/qemu.log" -p StandardError="append:$V/logs/qemu.log" "${thp[@]}" "$V/run.sh"
  for _ in $(seq 20); do python3 -I "${0%/*}/../pin.py" "$V/qmp.sock" "$VCPUS" 2>/dev/null && break; sleep 0.5; done
  for _ in $(seq 90); do
    alive || die "QEMU ended: $(tail -3 "$V/logs/qemu.log")"
    guest true 2>/dev/null && { echo "started: ssh port $PORT, log $V/logs/qemu.log"; return; }
    sleep 2
  done
  die "no SSH after 3 min (mac26.sh gui shot FILE.png shows the screen)"
}

stop(){
  alive || { echo "not running"; return; }
  guest 'sudo shutdown -h now' > /dev/null 2>&1 || true
  for _ in $(seq 45); do alive || { echo stopped; return; }; sleep 2; done
  echo "macOS did not shut down in 90 s, powering off"; systemctl --user stop "$UNIT"; echo stopped
}

case ${1:-} in
  start) shift; start "$@" ;;
  stop) stop ;;
  kill) systemctl --user stop "$UNIT" 2>/dev/null || true; echo killed ;;
  status) alive && echo running || { echo "not running"
    # QEMU ends itself where reims cannot do what the guest asked; say so (../README.md)
    grep -m1 -o 'reims-vgpu: fatal:.\{0,260\}' "$V/logs/qemu.log" 2>/dev/null || true; } ;;
  ssh) shift; guest "$@" ;;
  scp) shift; scp -q "${SSH_OPTS[@]}" -P "$PORT" "$@" ;;
  gui) shift; exec python3 -I /vmlab/tools/vmlab/gpu/reims/qdrive.py "$V/qmp.sock" "$@" ;;
  reset) stopped; qemu-img snapshot -a clean "$V/disk.qcow2"; echo "reset to the clean snapshot" ;;
  commit) stopped
    qemu-img snapshot -l "$V/disk.qcow2" | grep -qw clean && qemu-img snapshot -d clean "$V/disk.qcow2"
    qemu-img snapshot -c clean "$V/disk.qcow2"; echo "the disk as it is now is the clean snapshot" ;;
  *) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
