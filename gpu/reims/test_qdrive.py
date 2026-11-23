#!/usr/bin/env python3
"""Tests of qdrive.py on the host, with no VM: a fake QMP socket that answers what qdrive sends.
Run: python3 -m unittest gpu/reims/test_qdrive.py (or python3 gpu/reims/test_qdrive.py)."""
import io, json, os, shutil, socket, struct, sys, tempfile, threading, unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qdrive


class FakeQmp:
    """A QMP server on a Unix socket. screendump writes a PPM of the given size; every command
    is kept in .commands, every input event in .events."""
    def __init__(self, w=1920, h=1080):
        self.w, self.h = w, h
        self.dir = tempfile.mkdtemp(dir='/vmlab/tmp')
        self.path = os.path.join(self.dir, 'qmp.sock')
        self.commands, self.events, self.connections = [], [], 0
        self.srv = socket.socket(socket.AF_UNIX); self.srv.bind(self.path); self.srv.listen(4)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try: c, _ = self.srv.accept()
            except OSError: return
            self.connections += 1
            threading.Thread(target=self.client, args=(c,), daemon=True).start()

    def client(self, c):
        f = c.makefile('rw')
        f.write(json.dumps({'QMP': {'version': {}, 'capabilities': []}}) + '\n'); f.flush()
        for line in f:
            msg = json.loads(line); ex = msg['execute']; args = msg.get('arguments', {})
            self.commands.append(ex)
            if ex == 'screendump':
                px = bytes([10, 20, 30]) * (self.w * self.h)
                with open(args['filename'], 'wb') as o: o.write(b'P6\n%d %d\n255\n' % (self.w, self.h) + px)
                r = {'return': {}}
            elif ex == 'input-send-event':
                self.events.extend(args['events']); r = {'return': {}}
            elif ex == 'bad':
                r = {'error': {'class': 'GenericError', 'desc': 'no such thing'}}
            else:
                r = {'return': {}}
            f.write(json.dumps(r) + '\n'); f.flush()

    def close(self):
        self.srv.close(); shutil.rmtree(self.dir, ignore_errors=True)

    def dumps(self):
        return self.commands.count('screendump')


class FakeVnc:
    """An RFB 3.8 server with no password, like QEMU's: a full frame of raw BGRX pixels for
    each update request. The pixel at (x, y) is (x % 256, y % 256, 7). resize_to: the size the
    screen takes after the first frame, told with a DesktopSize rectangle."""
    def __init__(self, w=64, h=48, resize_to=None):
        self.w, self.h, self.resize_to = w, h, resize_to
        self.connections, self.requests, self.encodings = 0, 0, []
        self.srv = socket.create_server(('127.0.0.1', 0)); self.port = self.srv.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try: c, _ = self.srv.accept()
            except OSError: return
            self.connections += 1
            threading.Thread(target=self.client, args=(c,), daemon=True).start()

    def client(self, c):
        def rd(n):
            b = b''
            while len(b) < n:
                d = c.recv(n - len(b))
                if not d: raise EOFError
                b += d
            return b
        try:
            c.sendall(b'RFB 003.008\n'); rd(12); c.sendall(b'\x01\x01'); rd(1); c.sendall(b'\0\0\0\0'); rd(1)
            name = b'fake'
            c.sendall(struct.pack('>HH', self.w, self.h) + bytes(16) + struct.pack('>I', len(name)) + name)
            while True:
                t = rd(1)[0]
                if t == 0: rd(19)
                elif t == 2:
                    rd(1); (n,) = struct.unpack('>H', rd(2))
                    self.encodings = list(struct.unpack('>%di' % n, rd(4 * n)))
                elif t == 3:
                    rd(9); self.requests += 1
                    if self.requests == 2 and self.resize_to:
                        self.w, self.h = self.resize_to
                        c.sendall(struct.pack('>BxH', 0, 1) + struct.pack('>HHHHi', 0, 0, self.w, self.h, -223))
                        continue                   # this connection is left behind
                    c.sendall(b'\x02')            # a bell first: the client must skip it
                    px = bytearray()
                    for y in range(self.h):
                        for x in range(self.w): px += bytes([7, y % 256, x % 256, 0])   # B G R X
                    c.sendall(struct.pack('>BxH', 0, 1) + struct.pack('>HHHHi', 0, 0, self.w, self.h, 0) + px)
        except (EOFError, OSError):
            pass

    def close(self):
        self.srv.close()


def run(fake, *argv, vnc=None):
    """qdrive.py on the fake socket, with no waits; what it printed."""
    out = io.StringIO()
    with mock.patch.object(qdrive.time, 'sleep'), mock.patch.object(sys, 'argv', ['qdrive.py', fake.path, *argv]), \
            mock.patch.object(qdrive, 'VNC', str(vnc.port) if vnc else None), mock.patch.object(sys, 'stdout', out):
        qdrive.main()
    return out.getvalue()


class SizeTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeQmp(); self.addCleanup(self.fake.close)

    def test_drag_dumps_once(self):
        run(self.fake, 'drag', '10', '10', '200', '100')
        self.assertEqual(self.fake.dumps(), 1)
        moves = [e for e in self.fake.events if e['type'] == 'abs']
        self.assertEqual(len(moves), 22)           # the start and ten steps, x and y each

    def test_pointer_scales_to_the_screen(self):
        run(self.fake, 'move', '960', '540')
        xs = [e['data']['value'] for e in self.fake.events if e['type'] == 'abs']
        self.assertEqual(xs, [0x7fff // 2, 0x7fff // 2])

    def test_size(self):
        self.fake.w, self.fake.h = 1280, 800
        self.assertEqual(run(self.fake, 'size'), '1280x800\n')

    def test_ppm_header(self):
        self.assertEqual(qdrive.ppm_header(b'P6\n640 480\n255\nxyz'), (640, 480, 15))
        with self.assertRaises(SystemExit): qdrive.ppm_header(b'P6\n640')


class KeyNameTest(unittest.TestCase):
    def test_aliases(self):
        cases = {
            'escape': ['esc'], 'Esc': ['esc'], 'enter': ['ret'], 'return': ['ret'], 'space': ['spc'],
            'del': ['delete'], 'bs': ['backspace'], 'backspace': ['backspace'],
            'pageup': ['pgup'], 'PgUp': ['pgup'], 'pagedown': ['pgdn'], 'pgdn': ['pgdn'], 'page-down': ['pgdn'],
            'option+left': ['alt', 'left'], 'opt+right': ['alt', 'right'],
            'cmd+q': ['meta_l', 'q'], 'command+w': ['meta_l', 'w'], 'super': ['meta_l'], 'meta': ['meta_l'],
            'win+r': ['meta_l', 'r'], 'ctrl+shift+escape': ['ctrl', 'shift', 'esc'], 'control+c': ['ctrl', 'c'],
            'arrowup': ['up'], 'down': ['down'], 'shift+Tab': ['shift', 'tab'], 'F4': ['f4'], 'alt+f4': ['alt', 'f4'],
            'ctrl+A': ['ctrl', 'a'], 'cmd+,': ['meta_l', 'comma'], 'ctrl+-': ['ctrl', 'minus'],
            'ctrl++': ['ctrl', 'shift', 'equal'], 'ctrl+plus': ['ctrl', 'shift', 'equal'], 'shift+1': ['shift', '1'],
            'ctrl+!': ['ctrl', 'shift', '1'], 'meta_r': ['meta_r'], 'kp_enter': ['kp_enter'],
        }
        for text, keys in cases.items():
            self.assertEqual(qdrive.chord(text), keys, text)

    def test_every_alias_is_a_qcode(self):
        for name, code in qdrive.ALIASES.items():
            self.assertTrue(code in qdrive.QCODES or code in qdrive.SHIFTED, name)

    def test_unknown_name(self):
        with self.assertRaises(SystemExit) as e: qdrive.chord('escpe')
        self.assertIn("no key named 'escpe'", str(e.exception)); self.assertIn('escape', str(e.exception))
        with self.assertRaises(SystemExit): qdrive.chord('ctrl+é')

    def test_key_sends_a_chord(self):
        fake = FakeQmp(); self.addCleanup(fake.close)
        run(fake, 'key', 'ctrl+shift+escape', 'enter')
        sent = [(e['data']['key']['data'], e['data']['down']) for e in fake.events]
        self.assertEqual(sent, [('ctrl', True), ('shift', True), ('esc', True), ('esc', False), ('shift', False),
                                ('ctrl', False), ('ret', True), ('ret', False)])

    def test_a_wrong_name_sends_nothing(self):
        fake = FakeQmp(); self.addCleanup(fake.close)
        with self.assertRaises(SystemExit): run(fake, 'key', 'ret', 'escpe')
        self.assertEqual(fake.events, [])


class TypeTest(unittest.TestCase):
    def test_ascii(self):
        self.assertEqual(qdrive.type_keys('aB1 !\n'), [['a'], ['shift', 'b'], ['1'], ['spc'], ['shift', '1'], ['ret']])

    def test_no_key_says_what_to_do(self):
        for text in ('café', 'naïve', '²', 'Ä', '\u2014', '\r'):
            with self.assertRaises(SystemExit) as e: qdrive.type_keys(text)
            msg = str(e.exception)
            self.assertIn('ASCII only', msg); self.assertIn('clipboard_write', msg); self.assertIn('ctrl+v', msg)

    def test_nothing_is_typed(self):
        fake = FakeQmp(); self.addCleanup(fake.close)
        with self.assertRaises(SystemExit): run(fake, 'type', 'abc é')
        self.assertEqual(fake.events, [])


class BatchTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeQmp(64, 48); self.addCleanup(self.fake.close)
        self.dir = tempfile.mkdtemp(dir='/vmlab/tmp'); self.addCleanup(shutil.rmtree, self.dir, True)

    def test_steps_share_one_connection(self):
        out = os.path.join(self.dir, 'a.png')
        printed = run(self.fake, 'batch', 'move 10 20', 'click 10 20', 'sleep 0.2', 'key ctrl+a', "type 'hi there'",
                      'drag 0 0 63 47', 'size', f'shot {out}')
        self.assertEqual(self.fake.connections, 1)
        self.assertEqual(self.fake.dumps(), 2)        # the size once, then the shot
        self.assertEqual(printed, f'64x48\n64x48 {out}\n')
        keys = [e['data']['key']['data'] for e in self.fake.events if e['type'] == 'key' and e['data']['down']]
        self.assertEqual(keys, ['ctrl', 'a', 'h', 'i', 'spc', 't', 'h', 'e', 'r', 'e'])

    def test_a_bad_step_stops_it_before_the_first(self):
        for bad, said in (('key escpe', "batch step 2 (key escpe): key: no key named 'escpe'"),
                          ('click 1', 'batch step 2 (click 1): click needs 2 numbers'),
                          ('clik 1 2', "batch step 2 (clik 1 2): no command 'clik'"),
                          ('type é', 'batch step 2 (type é): type: no key'),
                          ("type 'open", 'batch step 2 (type \'open): No closing quotation'),
                          ('sleep soon', 'batch step 2 (sleep soon): sleep: a number'),
                          ('batch "move 1 1"', 'a batch cannot hold a batch'), ('', 'empty')):
            with self.assertRaises(SystemExit) as e: run(self.fake, 'batch', 'move 1 1', bad)
            self.assertIn(said, str(e.exception))
        self.assertEqual(self.fake.connections, 0)

    def test_a_failing_step_is_named(self):
        with self.assertRaises(SystemExit) as e: run(self.fake, 'batch', 'move 1 1', 'qmp \'{"execute": "bad"}\'')
        self.assertEqual(str(e.exception), 'batch step 2 (qmp \'{"execute": "bad"}\'): qmp: no such thing')

    def test_single_commands_unchanged(self):
        self.assertEqual(run(self.fake, 'qmp', '{"execute": "query-status"}'), '{}\n')
        run(self.fake, 'click', '5', '5', 'double')
        self.assertEqual(len([e for e in self.fake.events if e['type'] == 'btn']), 4)
        run(self.fake, 'click', '5', '5', 'right')
        self.assertEqual(self.fake.events[-1]['data'], {'down': False, 'button': 'right'})
        with self.assertRaises(SystemExit) as e: run(self.fake, 'nope')
        self.assertIn('qdrive.py VM shot', str(e.exception))


class VncTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeQmp(); self.addCleanup(self.fake.close)
        self.dir = tempfile.mkdtemp(dir='/vmlab/tmp'); self.addCleanup(shutil.rmtree, self.dir, True)

    def test_shot_and_size_over_vnc(self):
        from PIL import Image
        vnc = FakeVnc(64, 48); self.addCleanup(vnc.close)
        out = os.path.join(self.dir, 'v.png')
        printed = run(self.fake, 'batch', 'move 32 24', f'shot {out}', f'shot {out}', 'size', vnc=vnc)
        self.assertEqual(printed, f'64x48 {out}\n64x48 {out}\n64x48\n')
        self.assertEqual(vnc.connections, 1); self.assertEqual(self.fake.dumps(), 0)
        self.assertIn(-223, vnc.encodings)
        img = Image.open(out); self.assertEqual(img.getpixel((10, 20)), (10, 20, 7))

    def test_a_new_resolution_reconnects(self):
        vnc = FakeVnc(64, 48, resize_to=(80, 40)); self.addCleanup(vnc.close)
        out = os.path.join(self.dir, 'r.png')
        printed = run(self.fake, 'batch', f'shot {out}', f'shot {out}', 'size', vnc=vnc)
        self.assertEqual(printed, f'64x48 {out}\n80x40 {out}\n80x40\n')
        self.assertEqual(vnc.connections, 2)


if __name__ == '__main__':
    unittest.main()
