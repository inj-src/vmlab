#!/bin/sh
# A second GNOME compositor with one 1920x1080 screen at a scale, for testing a VM window on a
# scaled screen. It has a home and settings of its own
# (/vmlab/tmp/nested-home), so nothing of the user's session is read or started. Its session bus
# address goes to /vmlab/tmp/nested-bus, its Wayland socket is vmlab-test-0.
export HOME=/vmlab/tmp/nested-home XDG_CONFIG_HOME=/vmlab/tmp/nested-home/.config
export XDG_DATA_HOME=/vmlab/tmp/nested-home/.local/share XDG_CACHE_HOME=/vmlab/tmp/nested-home/.cache
export GSETTINGS_BACKEND=keyfile
mkdir -p "$XDG_CONFIG_HOME/glib-2.0/settings" "$HOME/Desktop"
cp "$(dirname "$(readlink -f "$0")")/keyfile" "$XDG_CONFIG_HOME/glib-2.0/settings/keyfile"
echo "$DBUS_SESSION_BUS_ADDRESS" > /vmlab/tmp/nested-bus
# Headless unless NESTED_VISIBLE is set: no window on the desktop, and its own input devices.
# In a window (--nested) mutter is an X11 client of the desktop, and input injected through its
# RemoteDesktop interface goes out as XTest events on the desktop's X server.
if [ -n "$NESTED_VISIBLE" ]; then
  mode="--nested"; echo visible > /vmlab/tmp/nested-mode
else
  mode="--headless --virtual-monitor 1920x1080"; echo headless > /vmlab/tmp/nested-mode
  unset DISPLAY XAUTHORITY
fi
# NESTED_GDB=1: under gdb, which prints a backtrace where the compositor crashes (symbols from
# Ubuntu's debuginfod, cached in the nested home).
if [ -n "$NESTED_GDB" ]; then
  export DEBUGINFOD_URLS=https://debuginfod.ubuntu.com
  # freed memory is overwritten, so the compositor's use of a freed object faults every time
  export MALLOC_PERTURB_=165
  exec gdb -q -batch -iex "set debuginfod enabled on" -ex "handle SIGPIPE nostop noprint pass" \
    -ex run -ex "bt 14" --args gnome-shell $mode --wayland --wayland-display=vmlab-test-0 --no-x11
fi
exec gnome-shell $mode --wayland --wayland-display=vmlab-test-0 --no-x11
