#!/bin/bash
# nested.sh start [SCALE] | scale SCALE | shot FILE.png | do STEP... | stop: a test desktop for
# the VM windows. A second GNOME compositor (nested-shell.sh; the same mutter as the desktop's)
# with one 1920x1080 screen at SCALE (1.25 unless given). It is headless: nothing of it shows on
# the desktop, and its pointer and keyboard are its own. scale changes the screen's scale while
# it runs, as moving a window to another screen does. shot is the screen at its own pixels
# (mutter's screen cast, through PipeWire). do moves its pointer, clicks and takes pictures
# (nested-do.py has the steps). Open a VM in it with WAYLAND_DISPLAY=vmlab-test-0 before the
# VM's start command, and check `systemctl --user is-active vmlab-nested-shell` first: without
# the test display QEMU's GTK window opens on the real desktop instead.
# NESTED_GDB=1 start: under gdb, with freed memory overwritten (nested-shell.sh).
# NESTED_VISIBLE=1 start: in a window on the desktop instead, to look at it. Then `do` refuses:
# a compositor in a window sends injected input to the desktop's own X server.
# State: /vmlab/tmp/nested-home, nested-bus, nested-mode, nested-shell.log. Compare pictures
# with cmp.py.
set -u
here=$(dirname "$(readlink -f "$0")")
case ${1:-} in
start)
  systemctl --user kill -s KILL vmlab-nested-shell 2>/dev/null; sleep 1
  systemctl --user reset-failed vmlab-nested-shell 2>/dev/null
  rm -f "$XDG_RUNTIME_DIR"/vmlab-test-0 "$XDG_RUNTIME_DIR"/vmlab-test-0.lock /vmlab/tmp/nested-bus /vmlab/tmp/nested-mode
  visible=(); [[ -n ${NESTED_VISIBLE:-} ]] && visible=(--setenv=DISPLAY="$DISPLAY" --setenv=XAUTHORITY="$XAUTHORITY")
  : > /vmlab/tmp/nested-shell.log
  systemd-run --user --quiet --collect --unit=vmlab-nested-shell -p TimeoutStopSec=5 \
    -p StandardOutput=append:/vmlab/tmp/nested-shell.log -p StandardError=append:/vmlab/tmp/nested-shell.log \
    "${visible[@]}" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" --setenv=NESTED_VISIBLE="${NESTED_VISIBLE:-}" \
    --setenv=NESTED_GDB="${NESTED_GDB:-}" --setenv=MUTTER_DEBUG_DUMMY_MODE_SPECS=1920x1080 --setenv=MUTTER_DEBUG_DUMMY_MONITOR_SCALES="${2:-1.25}" \
    dbus-run-session -- "$here/nested-shell.sh"
  for _ in $(seq 40); do [[ -s /vmlab/tmp/nested-bus && -S $XDG_RUNTIME_DIR/vmlab-test-0 ]] && break; sleep 0.5; done
  sleep 3
  # a headless screen starts at 100%
  [[ -n ${NESTED_VISIBLE:-} ]] || python3 "$here/nested-scale.py" "${2:-1.25}" > /dev/null
  systemctl --user is-active vmlab-nested-shell ;;
stop) systemctl --user kill -s KILL vmlab-nested-shell; systemctl --user reset-failed vmlab-nested-shell 2>/dev/null ;;
shot) exec python3 "$here/nested-shot.py" "$2" ;;
scale) exec python3 "$here/nested-scale.py" "$2" ;;
do) shift; exec python3 "$here/nested-do.py" "$@" ;;
*) sed -n "2,15p" "$0" ;;
esac
