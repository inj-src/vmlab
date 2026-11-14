# window.sh: what both launchers (win3d/win-venus.sh, reims/mac26.sh) share for the VM's window
# and its tray icon. Sourced; the launcher has die.
#
# Every start makes the VM's real window where a desktop can be reached: shown with --window,
# hidden otherwise, so `show` (vm view) can put it on the screen at any time; a VNC viewer
# resized Windows and broke an agent's clicks, and a headless Mac could not be watched at all
# (the user's request, 2026-11-15). The window reads `show` and `hide` lines from a FIFO
# (VMLAB_WINDOW_CONTROL) and writes `shown` or `hidden` to a file (VMLAB_WINDOW_STATE_FILE):
# QEMU's GTK window (win3d/qemu-patches/0014) and reims' SDL window
# (reims/patches/window-shown-and-hidden-on-request.dev.patch) alike. A window ties QEMU to the
# desktop's session: if GNOME Shell ends, so does the VM.

# Whether a desktop can be reached: a Wayland socket, $WAYLAND_DISPLAY's or else wayland-0,
# which a caller with a stripped environment (an MCP server) does not name. Sets
# WAYLAND_DISPLAY and XDG_RUNTIME_DIR for the window.
desktop(){
  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  local name=${WAYLAND_DISPLAY:-wayland-0} path
  [[ $name == /* ]] && path=$name || path=$XDG_RUNTIME_DIR/$name
  [[ -S $path ]] || return 1
  export WAYLAND_DISPLAY=$name
}

# tray NAME VM_UNIT STATE_FILE: the VM's icon in the desktop's tray (~/.local/bin/vm-tray), a
# unit bound to the VM's, so it goes when the VM ends. Not for a VM in the test rig's nested
# desktop (gpu/rig/nested.sh): the tray is the real desktop's (the session's D-Bus), whatever
# display the window is on. VMLAB_TRAY=off: none.
tray(){
  [[ ${VMLAB_TRAY:-on} != off && ${WAYLAND_DISPLAY:-} != vmlab-test-* ]] || return 0
  local env=() a
  for a in WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; do [[ -n ${!a:-} ]] && env+=(--setenv="$a=${!a}"); done
  systemctl --user stop "vmlab-tray-$1" 2>/dev/null || true
  systemctl --user reset-failed "vmlab-tray-$1" 2>/dev/null || true
  systemd-run --user --quiet --collect --unit="vmlab-tray-$1" -p BindsTo="$2.service" -p After="$2.service" \
    -p StandardOutput=null -p StandardError="append:$(dirname "$3")/tray.log" "${env[@]}" \
    /vmlab/tools/vmlab/home/.local/bin/vm-tray "$1" "$3" ||
    echo "no tray icon: systemctl --user status vmlab-tray-$1" >&2
}

# window_ask show|hide FIFO STATE_FILE: asks the running VM's window, and waits for it to say
# it is done. The window holds the FIFO open, so the write only waits where the VM is gone.
window_ask(){
  [[ -p $2 ]] || die "no window to $1: started without one (no desktop to reach)"
  local want=shown; [[ $1 == hide ]] && want=hidden
  timeout 5 bash -c 'echo "$1" > "$2"' _ "$1" "$2" || die "the window did not take '$1'"
  for _ in $(seq 30); do
    [[ $(cat "$3" 2>/dev/null) == "$want" ]] && { echo "$want"; return; }
    sleep 0.1
  done
  die "the window did not say $want (it says: $(cat "$3" 2>/dev/null || echo nothing))"
}
