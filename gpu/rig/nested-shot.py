"""nested-shot.py FILE.png: one frame of the nested compositor's screen, at its own pixels."""
import subprocess, sys
from gi.repository import Gio, GLib

# Only ever the nested compositor's own bus (its address is in /vmlab/tmp/nested-bus): on the
# session bus these calls would change, or record, the person's real screens.
bus = Gio.DBusConnection.new_for_address_sync(
    open('/vmlab/tmp/nested-bus').read().strip(),
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
    None, None)
def call(path, iface, method, args=None, reply=None):
    return bus.call_sync('org.gnome.Mutter.ScreenCast', path, iface, method, args,
                         GLib.VariantType(reply) if reply else None, 0, 5000, None)
session = call('/org/gnome/Mutter/ScreenCast', 'org.gnome.Mutter.ScreenCast', 'CreateSession',
               GLib.Variant('(a{sv})', ({},)), '(o)').unpack()[0]
stream = call(session, 'org.gnome.Mutter.ScreenCast.Session', 'RecordMonitor',
              GLib.Variant('(sa{sv})', ('', {'cursor-mode': GLib.Variant('u', 0)})), '(o)').unpack()[0]
loop = GLib.MainLoop()
node = []
def added(conn, sender, path, iface, signal, params):
    node.append(params.unpack()[0]); loop.quit()
bus.signal_subscribe('org.gnome.Mutter.ScreenCast', 'org.gnome.Mutter.ScreenCast.Stream',
                     'PipeWireStreamAdded', stream, None, 0, added)
call(session, 'org.gnome.Mutter.ScreenCast.Session', 'Start')
GLib.timeout_add(5000, loop.quit); loop.run()
if not node: sys.exit('no stream')
r = subprocess.run(['gst-launch-1.0', '-q', 'pipewiresrc', f'path={node[0]}', 'num-buffers=1', '!',
                    'videoconvert', '!', 'pngenc', 'snapshot=false', '!', 'multifilesink',
                    f'location={sys.argv[1]}'], timeout=20)
call(session, 'org.gnome.Mutter.ScreenCast.Session', 'Stop')
sys.exit(r.returncode)
