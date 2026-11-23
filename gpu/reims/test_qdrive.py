#!/usr/bin/env python3
"""Tests of qdrive.py on the host, with no VM: a fake QMP socket that answers what qdrive sends.
Run: python3 -m unittest gpu/reims/test_qdrive.py (or python3 gpu/reims/test_qdrive.py)."""
import json, os, socket, sys, tempfile, threading, unittest
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
        self.commands, self.events = [], []
        self.srv = socket.socket(socket.AF_UNIX); self.srv.bind(self.path); self.srv.listen(4)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try: c, _ = self.srv.accept()
            except OSError: return
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
        self.srv.close()

    def dumps(self):
        return self.commands.count('screendump')


def run(fake, *argv):
    with mock.patch.object(qdrive.time, 'sleep'), mock.patch.object(sys, 'argv', ['qdrive.py', fake.path, *argv]):
        qdrive.main()


class SizeTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeQmp(); self.addCleanup(self.fake.close)
        qdrive.VNC = None

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
        with mock.patch('builtins.print') as p: run(self.fake, 'size')
        p.assert_called_with('1280x800')

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


if __name__ == '__main__':
    unittest.main()
