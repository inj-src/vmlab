"""xmax.py WINDOW_ID on|off: maximize an X11 (XWayland) window or restore it, for tests of the
VM windows started with WIN_VENUS_WINDOW_X11=1 / MAC26_WINDOW_X11=1. Find the id with
`xwininfo -root -tree | grep 'Windows 11'`; resize a restored window with
`xdotool windowsize ID W H`."""
import ctypes, sys

class ClientMessage(ctypes.Structure):
    _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong), ('send_event', ctypes.c_int),
                ('display', ctypes.c_void_p), ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                ('format', ctypes.c_int), ('data', ctypes.c_long * 5), ('pad', ctypes.c_long * 8)]

x = ctypes.CDLL('libX11.so.6')
x.XOpenDisplay.restype = ctypes.c_void_p
x.XInternAtom.restype = ctypes.c_ulong
x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
x.XFlush.argtypes = [ctypes.c_void_p]
dpy = x.XOpenDisplay(None)
atom = lambda name: x.XInternAtom(dpy, name, 0)
ev = ClientMessage(type=33, send_event=1, window=int(sys.argv[1], 0), message_type=atom(b'_NET_WM_STATE'), format=32)
ev.data[0] = 1 if sys.argv[2] == 'on' else 0
ev.data[1], ev.data[2], ev.data[3] = atom(b'_NET_WM_STATE_MAXIMIZED_VERT'), atom(b'_NET_WM_STATE_MAXIMIZED_HORZ'), 1
x.XSendEvent(dpy, x.XDefaultRootWindow(dpy), 0, (1 << 20) | (1 << 19), ctypes.byref(ev))
x.XFlush(dpy)
