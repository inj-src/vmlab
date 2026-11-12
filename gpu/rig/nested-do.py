"""nested-do.py STEP...: move the nested compositor's pointer, click, and take pictures, in order.

  move X Y     the pointer to that screen pixel (the screen's own pixels, as in a shot)
  press | release | click | rclick | dclick      the left (or right) button
  key CODE     press and release that evdev key code (1 = Esc). The first key of a run is lost:
               send a spare one first (42, a shift key)
  keydown CODE | keyup CODE      one half of that, for chords (29 Ctrl, 56 Alt, 33 F)
  run CMD      run that shell command with the test compositor as its display (wl-copy and
               wl-paste need the keyboard this session gives the seat)
  sleep S      wait S seconds
  shot F.png   one frame of the screen (with the pointer in it if NESTED_CURSOR is set)

One mutter RemoteDesktop session with a screen cast, for all the steps.
"""
import os, subprocess, sys, time
from gi.repository import Gio, GLib

# Only a headless compositor has input devices of its own (nested-shell.sh).
if open('/vmlab/tmp/nested-mode').read().strip() != 'headless':
    sys.exit('nested-do.py: the test compositor is not headless; its injected input would go to the desktop')
# Only ever the nested compositor's own bus (its address is in /vmlab/tmp/nested-bus): on the
# session bus these calls would move the person's real pointer and record their real screens.
bus = Gio.DBusConnection.new_for_address_sync(
    open('/vmlab/tmp/nested-bus').read().strip(),
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
    None, None)


def call(dest, path, iface, method, args=None, reply=None):
    return bus.call_sync(dest, path, iface, method, args,
                         GLib.VariantType(reply) if reply else None, 0, 5000, None)


RD, SC = 'org.gnome.Mutter.RemoteDesktop', 'org.gnome.Mutter.ScreenCast'
rd = call(RD, '/org/gnome/Mutter/RemoteDesktop', RD, 'CreateSession', None, '(o)').unpack()[0]
sid = call(RD, rd, 'org.freedesktop.DBus.Properties', 'Get',
           GLib.Variant('(ss)', (RD + '.Session', 'SessionId')), '(v)').unpack()[0]
sc = call(SC, '/org/gnome/Mutter/ScreenCast', SC, 'CreateSession',
          GLib.Variant('(a{sv})', ({'remote-desktop-session-id': GLib.Variant('s', sid)},)), '(o)').unpack()[0]
stream = call(SC, sc, SC + '.Session', 'RecordMonitor',
              GLib.Variant('(sa{sv})', ('', {'cursor-mode': GLib.Variant('u', 1 if os.environ.get('NESTED_CURSOR') else 0)})), '(o)').unpack()[0]
loop = GLib.MainLoop()
node = []


def added(conn, sender, path, iface, signal, params):
    node.append(params.unpack()[0])
    loop.quit()


bus.signal_subscribe(SC, SC + '.Stream', 'PipeWireStreamAdded', stream, None, 0, added)
call(RD, rd, RD + '.Session', 'Start')
GLib.timeout_add(5000, loop.quit)
loop.run()
if not node:
    sys.exit('no stream')


def session(method, sig=None, *args):
    call(RD, rd, RD + '.Session', method, GLib.Variant(sig, args) if sig else None)


def button(code, down):
    session('NotifyPointerButton', '(ib)', code, down)


LEFT, RIGHT = 272, 273
# The session's pointer appears with its first event, and a client has to ask for it (the seat's
# new capability) before it gets any: that first event, and those right after it, are lost.
session('NotifyPointerMotionRelative', '(dd)', 0.0, 0.0)
time.sleep(0.5)
steps = sys.argv[1:]
rc = 0
while steps:
    step = steps.pop(0)
    if step == 'move':
        x, y = float(steps.pop(0)), float(steps.pop(0))
        # RemoteDesktop takes the stream's own pixels, the screen's, and mutter divides them by
        # the screen's scale itself (meta_screen_cast_monitor_stream_transform_position).
        # Dividing here too put every click at 80% of its place on the 125% screen (found
        # 2026-11-12: a click meant for the close button landed left of it, on the title bar).
        session('NotifyPointerMotionAbsolute', '(sdd)', stream, x, y)
    elif step == 'press':
        button(LEFT, True)
    elif step == 'release':
        button(LEFT, False)
    elif step in ('click', 'rclick', 'dclick'):
        code = RIGHT if step == 'rclick' else LEFT
        for _ in range(2 if step == 'dclick' else 1):
            button(code, True)
            time.sleep(0.05)
            button(code, False)
            time.sleep(0.05)
    elif step == 'key':
        code = int(steps.pop(0))
        session('NotifyKeyboardKeycode', '(ub)', code, True)
        session('NotifyKeyboardKeycode', '(ub)', code, False)
    elif step in ('keydown', 'keyup'):
        session('NotifyKeyboardKeycode', '(ub)', int(steps.pop(0)), step == 'keydown')
    elif step == 'run':
        # in the test compositor, while this session's keyboard and pointer exist
        # (its output goes nowhere: wl-copy stays behind and would hold a pipe open. Redirect
        # what is wanted to a file)
        subprocess.run(steps.pop(0), shell=True, timeout=60, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       env=dict(os.environ, WAYLAND_DISPLAY='vmlab-test-0'))
    elif step == 'sleep':
        time.sleep(float(steps.pop(0)))
    elif step == 'shot':
        # the first buffer a new reader gets can be an old frame: read a few (keepalive-time
        # repeats the last one while nothing changes) and keep the last
        rc |= subprocess.run(['gst-launch-1.0', '-q', 'pipewiresrc', f'path={node[0]}', 'num-buffers=4',
                              'keepalive-time=60',
                              '!', 'videoconvert', '!', 'pngenc', 'snapshot=false', '!', 'multifilesink',
                              f'location={steps.pop(0)}'], timeout=20).returncode
    else:
        sys.exit(f'unknown step {step}')
    time.sleep(0.05)
call(RD, rd, RD + '.Session', 'Stop')
sys.exit(rc)
