#!/usr/bin/env python3
"""qdrive.py: look at and drive a VM through its QMP socket, with no window. The keys and the
pointer are the VM's own hardware (a USB keyboard and tablet), so the guest sees them as a
person's: Windows does not mark them as injected, as it does input sent from inside it.

  qdrive.py VM shot FILE.png            screenshot (the display's own size)
  qdrive.py VM click X Y [right|double] click at a pixel of that screenshot
  qdrive.py VM move X Y                 move the pointer
  qdrive.py VM drag X1 Y1 X2 Y2         press at one point, release at the other
  qdrive.py VM type 'text'              type US-keyboard text
  qdrive.py VM key cmd+q [ret ...]      key chords: cmd (= win), opt (= alt), ctrl, shift + a
                                        QEMU key name (ret, esc, tab, f4, up, delete, a, 1 ...),
                                        a common one (escape, enter, space, del, bs, pageup,
                                        option, command, super ...) or one character (cmd+,)
  qdrive.py VM qmp '{"execute":...}'    one raw QMP command

  qdrive.py VM size                     the screen's size, WxH

VM is a reims VM name (its directory under the reims data dir) or a path to a qmp.sock.
QDRIVE_VNC=PORT: the picture and its size come from the VM's VNC server on 127.0.0.1:PORT
(the Windows VM: QMP's screendump has no picture of a guest that draws through the GPU).
"""
import difflib, json, os, re, socket, struct, subprocess, sys, tempfile, time

VMS = '/vmlab/reims/data/reims-ctl/vms'
VNC = os.environ.get('QDRIVE_VNC')
VNCSHOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../win3d/vncshot.py')
# QEMU's key names (qcodes): the QKeyCode enum of QEMU 11.1's QMP schema (query-qmp-schema).
QCODES = set('''
unmapped shift shift_r alt alt_r ctrl ctrl_r menu esc 1 2 3 4 5 6 7 8 9 0 minus equal backspace tab
q w e r t y u i o p bracket_left bracket_right ret a s d f g h j k l semicolon apostrophe
grave_accent backslash z x c v b n m comma dot slash asterisk spc caps_lock f1 f2 f3 f4 f5 f6 f7 f8
f9 f10 num_lock scroll_lock kp_divide kp_multiply kp_subtract kp_add kp_enter kp_decimal sysrq kp_0
kp_1 kp_2 kp_3 kp_4 kp_5 kp_6 kp_7 kp_8 kp_9 less f11 f12 print home pgup pgdn end left up down
right insert delete stop again props undo front copy open paste find cut lf help meta_l meta_r
compose pause ro hiragana henkan yen muhenkan katakanahiragana kp_comma kp_equals power sleep wake
audionext audioprev audiostop audioplay audiomute volumeup volumedown mediaselect mail calculator
computer ac_home ac_back ac_forward ac_refresh ac_bookmarks lang1 lang2 f13 f14 f15 f16 f17 f18 f19
f20 f21 f22 f23 f24
'''.split())
# The names agents and people use (Cua's, the DOM's, a Mac's keys) for qcodes.
ALIASES = {
    'cmd': 'meta_l', 'command': 'meta_l', 'win': 'meta_l', 'windows': 'meta_l', 'super': 'meta_l', 'meta': 'meta_l',
    'opt': 'alt', 'option': 'alt', 'control': 'ctrl',
    'escape': 'esc', 'enter': 'ret', 'return': 'ret', 'space': 'spc', 'del': 'delete', 'bs': 'backspace',
    'pageup': 'pgup', 'page_up': 'pgup', 'pagedown': 'pgdn', 'page_down': 'pgdn', 'ins': 'insert',
    'arrowup': 'up', 'arrowdown': 'down', 'arrowleft': 'left', 'arrowright': 'right',
    'capslock': 'caps_lock', 'numlock': 'num_lock', 'scrolllock': 'scroll_lock',
    'printscreen': 'print', 'prtsc': 'print', 'apps': 'menu', 'contextmenu': 'menu',
    'period': 'dot', 'plus': '+',
}
PLAIN = {' ': 'spc', '\n': 'ret', '\t': 'tab', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
         '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe', '`': 'grave_accent', ',': 'comma', '.': 'dot', '/': 'slash'}
SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash', ':': 'semicolon',
           '"': 'apostrophe', '~': 'grave_accent', '<': 'comma', '>': 'dot', '?': 'slash'}


def chord(text):
    """'ctrl+shift+escape' -> ['ctrl', 'shift', 'esc']: the qcodes of a chord, in order. A name is
    a qcode, an alias or one character ('cmd+,', 'ctrl++'); letters in any case."""
    keys = []
    for name in re.split(r'\+(?=.)', text):
        k = name if len(name) == 1 else ALIASES.get(name.lower().replace('-', '_'), name.lower().replace('-', '_'))
        if len(k) == 1 and k in ALIASES: k = ALIASES[k]
        if len(k) == 1:
            if k in PLAIN: k = PLAIN[k]
            elif k in SHIFTED: keys.append('shift'); k = SHIFTED[k]
            elif k.isascii() and k.isalnum(): k = k.lower()
        if k not in QCODES:
            near = difflib.get_close_matches(k, sorted(QCODES | set(ALIASES)), 3)
            raise SystemExit(f"key: no key named {name!r} in {text!r}" + (f" (did you mean {', '.join(near)}?)" if near else '') +
                             ". Names: QEMU's (ret, esc, spc, tab, backspace, delete, up, pgdn, f4, a, 1 ...), "
                             "escape, enter, space, del, pageup, cmd, option ..., or one character")
        if k not in keys: keys.append(k)
    return keys


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(30); self.s.connect(path)
        self.f = self.s.makefile('rw'); self.f.readline(); self.cmd('qmp_capabilities')
        self._size = None

    def cmd(self, execute, **arguments):
        msg = {'execute': execute}
        if arguments: msg['arguments'] = arguments
        return self.raw(msg)

    def raw(self, msg):
        self.f.write(json.dumps(msg) + '\n'); self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if 'error' in r: raise SystemExit(f"qmp: {r['error']['desc']}")
            if 'return' in r: return r['return']

    def events(self, *events):
        self.cmd('input-send-event', events=list(events)); time.sleep(0.04)

    def key(self, *qcodes):
        """Press the keys in order and release them in reverse: a chord."""
        ev = lambda q, down: {'type': 'key', 'data': {'down': down, 'key': {'type': 'qcode', 'data': q}}}
        for q in qcodes: self.events(ev(q, True))
        for q in reversed(qcodes): self.events(ev(q, False))

    def size(self):
        """The screen's size, read once per process. QEMU's QMP has no query for a console's
        size (11.1: query-display-options names the display, not its size), and the Mac's
        launcher writes no size file (its size follows the window), so without VNC it takes
        one screendump and reads only its header. A shot sets it too (shot_size)."""
        if not self._size:
            if VNC: self._size = vnc_size(int(VNC))
            else:
                os.makedirs('/vmlab/run', exist_ok=True)
                with tempfile.TemporaryDirectory(dir='/vmlab/run') as d:
                    self._size = ppm_size(self.shot_ppm(os.path.join(d, 's.ppm')))
        return self._size

    def shot_size(self, w, h):
        self._size = (w, h)

    def shot_ppm(self, path):
        self.cmd('screendump', filename=path, device='gfx', head=0)
        return path

    def pointer(self, x, y):
        w, h = self.size()
        ax = lambda axis, v, full: {'type': 'abs', 'data': {'axis': axis, 'value': min(0x7fff, int(v * 0x7fff / full))}}
        self.events(ax('x', x, w), ax('y', y, h))

    def button(self, down, name='left'):
        self.events({'type': 'btn', 'data': {'down': down, 'button': name}})


def vnc_size(port):
    """The screen's size from the VNC server's greeting (no password, as the lab's are)."""
    s = socket.create_connection(('127.0.0.1', port), 10); s.settimeout(15)
    def rd(n):
        b = b''
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c: raise EOFError
            b += c
        return b
    rd(12); s.sendall(b'RFB 003.008\n'); rd(rd(1)[0]); s.sendall(b'\x01'); rd(4); s.sendall(b'\x01')
    w, h = struct.unpack('>HH', rd(4)); s.close()
    return w, h


def ppm_header(data):
    """P6, width, height, max value: (width, height, where the pixels start)."""
    parts, pos = [], 0
    while len(parts) < 4:
        end = pos
        while data[end:end + 1] not in (b' ', b'\n', b'\t'):
            if end >= len(data): raise SystemExit('screendump: not a PPM file')
            end += 1
        parts.append(data[pos:end]); pos = end + 1
    return int(parts[1]), int(parts[2]), pos


def ppm_size(path):
    with open(path, 'rb') as f: w, h, _ = ppm_header(f.read(64))
    return w, h


def read_ppm(path):
    data = open(path, 'rb').read()
    w, h, pos = ppm_header(data)
    return w, h, data[pos:]


def main():
    if len(sys.argv) < 3: raise SystemExit(__doc__)
    vm, verb, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    chords = [chord(c) for c in args] if verb == 'key' else []      # a wrong name stops before any key
    q = Qmp(vm if '/' in vm else f'{VMS}/{vm}/qmp.sock')
    if verb == 'size':
        print('%dx%d' % q.size())
    elif verb == 'shot' and VNC:
        w, h = subprocess.run([sys.executable, '-I', VNCSHOT, VNC, args[0]], check=True, capture_output=True, text=True).stdout.split()
        print(f'{w}x{h} {args[0]}')
    elif verb == 'shot':
        from PIL import Image
        os.makedirs('/vmlab/run', exist_ok=True)
        with tempfile.TemporaryDirectory(dir='/vmlab/run') as d:
            w, h, px = read_ppm(q.shot_ppm(os.path.join(d, 's.ppm')))
        Image.frombytes('RGB', (w, h), px).save(args[0]); print(f'{w}x{h} {args[0]}')
    elif verb in ('click', 'move'):
        x, y = int(args[0]), int(args[1]); how = args[2] if len(args) > 2 else ''
        q.pointer(x, y); time.sleep(0.15)
        if verb == 'click':
            for _ in range(2 if how == 'double' else 1):
                name = 'right' if how == 'right' else 'left'
                q.button(True, name); time.sleep(0.06); q.button(False, name); time.sleep(0.1)
    elif verb == 'drag':
        x1, y1, x2, y2 = map(int, args)
        q.pointer(x1, y1); time.sleep(0.2); q.button(True); time.sleep(0.2)
        for i in range(1, 11): q.pointer(x1 + (x2 - x1) * i // 10, y1 + (y2 - y1) * i // 10)
        time.sleep(0.2); q.button(False)
    elif verb == 'type':
        for ch in args[0]:
            if ch in PLAIN: q.key(PLAIN[ch])
            elif ch in SHIFTED: q.key('shift', SHIFTED[ch])
            elif ch.isupper(): q.key('shift', ch.lower())
            elif ch.isalnum(): q.key(ch)
            else: raise SystemExit(f'type: no key for {ch!r}')
    elif verb == 'key':
        for keys in chords: q.key(*keys)
    elif verb == 'qmp':
        print(json.dumps(q.raw(json.loads(args[0]))))
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
