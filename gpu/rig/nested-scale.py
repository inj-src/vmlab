"""nested-scale.py SCALE: give the nested compositor's screen that scale (as moving a window to such a screen does)."""
import sys
from gi.repository import Gio, GLib
# Only ever the nested compositor's own bus (its address is in /vmlab/tmp/nested-bus): on the
# session bus these calls would change, or record, the person's real screens.
bus = Gio.DBusConnection.new_for_address_sync(
    open('/vmlab/tmp/nested-bus').read().strip(),
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
    None, None)
def call(method, args=None):
    return bus.call_sync('org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig',
                         'org.gnome.Mutter.DisplayConfig', method, args, None, 0, 5000, None)
serial, monitors, logical, props = call('GetCurrentState').unpack()
(connector, *_), modes, _ = monitors[0]
mode = next(m for m in modes if m[6].get('is-current'))
print('screen', connector, mode[0], 'scales it offers:', [round(s, 3) for s in mode[5]])
want = min(mode[5], key=lambda s: abs(s - float(sys.argv[1])))
call('ApplyMonitorsConfig', GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})',
     (serial, 1, [(0, 0, want, 0, True, [(connector, mode[0], {})])], {})))
print('scale now', want)
