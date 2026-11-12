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
                                        QEMU key name (ret, esc, tab, f4, up, delete, a, 1 ...)
  qdrive.py VM qmp '{"execute":...}'    one raw QMP command

  qdrive.py VM size                     the screen's size, WxH

VM is a reims VM name (its directory under the reims data dir) or a path to a qmp.sock.
QDRIVE_VNC=PORT: the picture and its size come from the VM's VNC server on 127.0.0.1:PORT
(the Windows VM: QMP's screendump has no picture of a guest that draws through the GPU).
"""
import json, os, socket, struct, subprocess, sys, tempfile, time

VMS = '/vmlab/reims/data/reims-ctl/vms'
VNC = os.environ.get('QDRIVE_VNC')
VNCSHOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../win3d/vncshot.py')
MODS = {'cmd': 'meta_l', 'win': 'meta_l', 'opt': 'alt', 'alt': 'alt', 'ctrl': 'ctrl', 'shift': 'shift'}
PLAIN = {' ': 'spc', '\n': 'ret', '\t': 'tab', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
         '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe', '`': 'grave_accent', ',': 'comma', '.': 'dot', '/': 'slash'}
SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash', ':': 'semicolon',
           '"': 'apostrophe', '~': 'grave_accent', '<': 'comma', '>': 'dot', '?': 'slash'}


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(30); self.s.connect(path)
        self.f = self.s.makefile('rw'); self.f.readline(); self.cmd('qmp_capabilities')

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
        if VNC: return vnc_size(int(VNC))
        with tempfile.TemporaryDirectory(dir='/vmlab/run') as d:
            w, h, _ = read_ppm(self.shot_ppm(os.path.join(d, 's.ppm')))
        return w, h

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


def read_ppm(path):
    data = open(path, 'rb').read()
    parts, pos = [], 0
    while len(parts) < 4:                      # P6, width, height, max value
        end = pos
        while data[end:end + 1] not in (b' ', b'\n', b'\t'): end += 1
        parts.append(data[pos:end]); pos = end + 1
    return int(parts[1]), int(parts[2]), data[pos:]


def main():
    if len(sys.argv) < 3: raise SystemExit(__doc__)
    vm, verb, args = sys.argv[1], sys.argv[2], sys.argv[3:]
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
        for chord in args: q.key(*[MODS.get(k, k) for k in chord.split('+')])
    elif verb == 'qmp':
        print(json.dumps(q.raw(json.loads(args[0]))))
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
