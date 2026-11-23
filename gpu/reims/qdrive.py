#!/usr/bin/env python3
"""qdrive.py: look at and drive a VM through its QMP socket, with no window. The keys and the
pointer are the VM's own hardware (a USB keyboard and tablet), so the guest sees them as a
person's: Windows does not mark them as injected, as it does input sent from inside it.

  qdrive.py VM shot FILE.png            screenshot (the display's own size)
  qdrive.py VM click X Y [right|double] click at a pixel of that screenshot
  qdrive.py VM move X Y                 move the pointer
  qdrive.py VM drag X1 Y1 X2 Y2         press at one point, release at the other
  qdrive.py VM type 'text'              type US-keyboard text (ASCII; other text: paste it)
  qdrive.py VM key cmd+q [ret ...]      key chords: cmd (= win), opt (= alt), ctrl, shift + a
                                        QEMU key name (ret, esc, tab, f4, up, delete, a, 1 ...),
                                        a common one (escape, enter, space, del, bs, pageup,
                                        option, command, super ...) or one character (cmd+,)
  qdrive.py VM qmp '{"execute":...}'    one raw QMP command

  qdrive.py VM size                     the screen's size, WxH

  qdrive.py VM batch STEP [STEP ...]    several commands in one run, on one connection: each STEP
                                        is one of the above in quotes, or "sleep SECONDS". All are
                                        checked before the first runs. Example:
                                          batch "click 100 200" "sleep 0.3" "key ctrl+a" "shot a.png"

VM is a reims VM name (its directory under the reims data dir) or a path to a qmp.sock.
QDRIVE_VNC=PORT: the picture and its size come from the VM's VNC server on 127.0.0.1:PORT
(the Windows VM: QMP's screendump has no picture of a guest that draws through the GPU).
"""
import difflib, json, os, re, shlex, socket, struct, sys, tempfile, time

VMS = '/vmlab/reims/data/reims-ctl/vms'
VNC = os.environ.get('QDRIVE_VNC')
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


def type_keys(text):
    """The chords that type text on a US keyboard, one per character. A character with none
    stops it before any key is sent."""
    out = []
    for i, ch in enumerate(text):
        if ch in PLAIN: out.append([PLAIN[ch]])
        elif ch in SHIFTED: out.append(['shift', SHIFTED[ch]])
        elif ch.isascii() and ch.isupper(): out.append(['shift', ch.lower()])
        elif ch.isascii() and ch.isalnum(): out.append([ch])
        else:
            raise SystemExit(
                f'type: no key for {ch!r} (U+{ord(ch):04X}, character {i + 1}); nothing was typed. type sends '
                'US-keyboard ASCII only (letters, digits, punctuation, space, tab, newline). For other text, put it '
                'on the guest\'s clipboard with the vmlab MCP tool clipboard_write (machine "win" or "mac"), check '
                'it with clipboard_read, then paste: vm gui win key ctrl+v, vm gui mac key cmd+v')
    return out


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(30); self.s.connect(path)
        self.f = self.s.makefile('rw'); self.f.readline(); self.cmd('qmp_capabilities')
        self._size = self._vnc = None

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

    def close(self):
        if self._vnc: self._vnc.s.close()
        self.f.close(); self.s.close()

    def vnc(self):
        if not self._vnc: self._vnc = Vnc(int(VNC))
        return self._vnc

    def size(self):
        """The screen's size, read once per run. QEMU's QMP has no query for a console's size
        (11.1: query-display-options names the display, not its size), and the Mac's launcher
        writes no size file (its size follows the window), so without VNC it takes one
        screendump and reads only its header. A shot sets it too."""
        if not self._size:
            if VNC: v = self.vnc(); self._size = (v.w, v.h)
            else:
                with dump_dir() as d: self._size = ppm_size(self.shot_ppm(os.path.join(d, 's.ppm')))
        return self._size

    def frame(self):
        """The screen as a picture (PIL)."""
        if VNC: img = self.vnc().frame()
        else:
            from PIL import Image
            with dump_dir() as d: w, h, px = read_ppm(self.shot_ppm(os.path.join(d, 's.ppm')))
            img = Image.frombytes('RGB', (w, h), px)
        self._size = img.size
        return img

    def shot_ppm(self, path):
        self.cmd('screendump', filename=path, device='gfx', head=0)
        return path

    def pointer(self, x, y):
        w, h = self.size()
        ax = lambda axis, v, full: {'type': 'abs', 'data': {'axis': axis, 'value': min(0x7fff, int(v * 0x7fff / full))}}
        self.events(ax('x', x, w), ax('y', y, h))

    def button(self, down, name='left'):
        self.events({'type': 'btn', 'data': {'down': down, 'button': name}})


def dump_dir():
    os.makedirs('/vmlab/run', exist_ok=True)
    return tempfile.TemporaryDirectory(dir='/vmlab/run')


class Vnc:
    """A connection to the VM's VNC server on 127.0.0.1 (no password, as the lab's are), kept for
    the run: a batch's shots share it."""
    RAW, DESKTOP_SIZE = 0, -223

    def __init__(self, port):
        self.port = port
        s = self.s = socket.create_connection(('127.0.0.1', port), 10); s.settimeout(15)
        self.rd(12); s.sendall(b'RFB 003.008\n')
        types = self.rd(self.rd(1)[0])
        if 1 not in types: raise SystemExit(f'vnc: the server on port {port} wants a password')
        s.sendall(b'\x01')
        if self.rd(4) != b'\0\0\0\0': raise SystemExit(f'vnc: the server on port {port} refused the connection')
        s.sendall(b'\x01')                                    # shared: other viewers stay
        self.w, self.h = struct.unpack('>HH', self.rd(4)); self.rd(16); self.rd(struct.unpack('>I', self.rd(4))[0])
        s.sendall(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))   # BGRX little-endian
        # raw pixels, and DesktopSize so that a new resolution mid-run is told, not sent at the old size
        s.sendall(struct.pack('>BxHii', 2, 2, self.RAW, self.DESKTOP_SIZE))

    def rd(self, n):
        b = b''
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c: raise SystemExit('vnc: the server closed the connection')
            b += c
        return b

    def frame(self):
        from PIL import Image
        self.s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, self.w, self.h))      # all of it, not just changes
        img = Image.new('RGB', (self.w, self.h)); got = 0
        while got < self.w * self.h:
            t = self.rd(1)[0]
            if t == 2: continue                                                   # bell
            if t == 3: self.rd(3); self.rd(struct.unpack('>I', self.rd(4))[0]); continue   # clipboard text
            if t != 0: raise SystemExit(f'vnc: unexpected message {t}')
            self.rd(1); (nr,) = struct.unpack('>H', self.rd(2))
            for _ in range(nr):
                x, y, rw, rh, enc = struct.unpack('>HHHHi', self.rd(12))
                if enc == self.DESKTOP_SIZE:
                    if (rw, rh) == (self.w, self.h): continue
                    # The guest changed resolution. A new connection starts clean at the new size.
                    self.s.close(); self.__init__(self.port)
                    return self.frame()
                if enc != self.RAW: raise SystemExit(f'vnc: encoding {enc}')
                img.paste(Image.frombuffer('RGB', (rw, rh), self.rd(rw * rh * 4), 'raw', 'BGRX', 0, 1), (x, y))
                got += rw * rh
        return img


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


USAGE = {
    'shot': 'shot FILE.png', 'click': 'click X Y [right|double]', 'move': 'move X Y', 'drag': 'drag X1 Y1 X2 Y2',
    'type': "type 'text'", 'key': 'key CHORD [CHORD ...]', 'qmp': "qmp '{\"execute\": ...}'", 'size': 'size',
    'sleep': 'sleep SECONDS',
}


def parse(verb, args):
    """Check one command and turn it into (verb, what it needs), before anything is sent."""
    def usage(why=''):
        raise SystemExit((why + '. ' if why else '') + f'usage: {USAGE[verb]}')
    def ints(n):
        if len(args) < n: usage(f'{verb} needs {n} numbers')
        try: return [int(a) for a in args[:n]]
        except ValueError: usage(f'{verb}: {" ".join(args[:n])} are not all whole numbers')
    if verb not in USAGE: raise SystemExit(f"no command {verb!r} (commands: {', '.join(USAGE)})")
    if verb == 'shot':
        if len(args) != 1: usage()
        return verb, args[0]
    if verb in ('click', 'move'):
        x, y = ints(2); rest = args[2:]
        how = rest[0] if rest else 'left'
        if len(rest) > (verb == 'click') or how not in ('left', 'right', 'double'): usage()
        return verb, (x, y, how)
    if verb == 'drag':
        if len(args) != 4: usage()
        return verb, ints(4)
    if verb == 'type':
        if not args: usage()
        return verb, type_keys(' '.join(args))         # a character with no key stops it here
    if verb == 'key':
        if not args: usage()
        return verb, [chord(c) for c in args]          # so does a wrong key name
    if verb == 'qmp':
        if len(args) != 1: usage()
        try: return verb, json.loads(args[0])
        except ValueError as e: usage(f'qmp: not JSON ({e})')
    if verb == 'size':
        if args: usage()
        return verb, None
    if verb == 'sleep':
        try: t = float(args[0]) if len(args) == 1 else -1
        except ValueError: t = -1
        if not 0 <= t <= 600: usage('sleep: a number of seconds, 0 to 600')
        return verb, t


def run(q, verb, a):
    if verb == 'size':
        print('%dx%d' % q.size())
    elif verb == 'shot':
        img = q.frame(); img.save(a); print(f'{img.width}x{img.height} {a}')
    elif verb in ('click', 'move'):
        x, y, how = a
        q.pointer(x, y); time.sleep(0.15)
        if verb == 'click':
            name = 'right' if how == 'right' else 'left'
            for _ in range(2 if how == 'double' else 1):
                q.button(True, name); time.sleep(0.06); q.button(False, name); time.sleep(0.1)
    elif verb == 'drag':
        x1, y1, x2, y2 = a
        q.pointer(x1, y1); time.sleep(0.2); q.button(True); time.sleep(0.2)
        for i in range(1, 11): q.pointer(x1 + (x2 - x1) * i // 10, y1 + (y2 - y1) * i // 10)
        time.sleep(0.2); q.button(False)
    elif verb in ('type', 'key'):
        for keys in a: q.key(*keys)
    elif verb == 'qmp':
        print(json.dumps(q.raw(a)))
    elif verb == 'sleep':
        time.sleep(a)


def batch(args):
    """The steps of a batch, each checked: [(label, verb, what it needs)]."""
    if not args: raise SystemExit('usage: batch STEP [STEP ...], each STEP one command in quotes, such as '
                                  '"click 100 200", "key ctrl+a", "sleep 0.2" or "shot a.png"')
    steps = []
    for i, text in enumerate(args, 1):
        label = f'batch step {i} ({text})'
        try:
            argv = shlex.split(text)
            if not argv: raise SystemExit('empty')
            if argv[0] == 'batch': raise SystemExit('a batch cannot hold a batch')
            steps.append((label, *parse(argv[0], argv[1:])))
        except (SystemExit, ValueError) as e:
            raise SystemExit(f'{label}: {e}') from None
    return steps


def main():
    if len(sys.argv) < 3: raise SystemExit(__doc__)
    vm, verb, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    if verb in ('help', '-h', '--help'): print(__doc__); return
    if verb != 'batch' and verb not in USAGE: raise SystemExit(__doc__)
    steps = batch(args) if verb == 'batch' else [(None, *parse(verb, args))]
    q = Qmp(vm if '/' in vm else f'{VMS}/{vm}/qmp.sock')
    try:
        for label, verb, a in steps:
            try: run(q, verb, a)
            except SystemExit as e:
                raise SystemExit(f'{label}: {e}' if label else e.code) from None
            sys.stdout.flush()
    finally:
        q.close()


if __name__ == '__main__':
    main()
