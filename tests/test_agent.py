#!/usr/bin/env python3
"""Headless end-to-end tests for vmlab-spice-agent.

Runs on the host against the running `mac` VM. Acts as the SPICE client itself (SpiceClientGLib
over a libvirt graphics fd, main channel only), so the user's real desktop clipboard is never read
or written. Guest-side state is checked over SSH with pbpaste/pbcopy and tests/pbtool.swift.

    tests/test_agent.py              run everything
    tests/test_agent.py text png     run the tests whose names contain any of the words

Only one SPICE client can be connected. If the user opens the viewer, our connection drops: the
run stops with exit code 3 ("user took over") instead of reconnecting.
"""
import ctypes
import hashlib
import io
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time

import gi

gi.require_version("SpiceClientGLib", "2.0")
from gi.repository import Gio, GLib, GObject, SpiceClientGLib as Spice  # noqa: E402
import libvirt  # noqa: E402
from PIL import Image  # noqa: E402

DOMAIN = "macos"
REMOTE = "~/src/spice-agent"
SEL = 0  # VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD
UTF8, PNG, BMP, TIFF, JPG = 1, 2, 3, 4, 5
CAP_BY_DEMAND, CAP_MAX_CLIPBOARD = 5, 10
ctx = GLib.MainContext.default()


class TookOver(Exception):
    pass


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


# ---------------------------------------------------------------------------------------------
# Guest shell over one multiplexed SSH connection (much faster than `vm ssh` per call).

class Guest:
    def __init__(self):
        ip = subprocess.check_output(["vm", "ip", "mac"], text=True).strip()
        self.tmp = tempfile.mkdtemp(prefix="spice-agent-test-")
        home = os.path.expanduser("~")
        self.base = [
            "ssh", "-i", f"{home}/.ssh/vmlab_ed25519",
            "-o", f"UserKnownHostsFile={home}/.cache/vmlab/known_hosts",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=auto", "-o", f"ControlPath={self.tmp}/ctl", "-o", "ControlPersist=120",
            f"dev@{ip}",
        ]

    def run(self, cmd, input=None, check=True):
        p = subprocess.run(self.base + [cmd], input=input, capture_output=True)
        if check and p.returncode != 0:
            raise Fail(f"guest command failed ({p.returncode}): {cmd}\n{p.stderr.decode(errors='replace')}")
        return p.stdout

    def put(self, path, data):
        self.run(f"cat > {path}", input=data)

    def get(self, path):
        return self.run(f"cat {path}")

    def close(self):
        subprocess.run(self.base[:-1] + ["-O", "exit", self.base[-1]], capture_output=True)
        shutil.rmtree(self.tmp, ignore_errors=True)


# ---------------------------------------------------------------------------------------------
# Headless SPICE client

def on(obj, signal, handler):
    return GObject.Object.connect(obj, signal, handler)


def pump(seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        ctx.iteration(False) or time.sleep(0.005)


class Client:
    def __init__(self, max_clipboard=None):
        self.conn = libvirt.open("qemu:///system")
        self.dom = self.conn.lookupByName(DOMAIN)
        self.session = Spice.Session()
        self.main = None
        self.closing = False
        self.lost = False
        self.max_clipboard = max_clipboard
        self.grabs = []          # list of type lists, one per GRAB from the agent
        self.releases = 0
        self.received = []       # (type, bytes) from the agent
        self.requests = []       # types the agent asked us for
        self.offer = {}          # type -> bytes we serve on request
        self.hold_requests = False
        self.held = []
        # Session.connect/Channel.connect are SPICE methods that shadow GObject.connect.
        on(self.session, "channel-new", self._channel_new)
        fd = self.dom.openGraphicsFD(0, 0)
        check(self.session.open_fd(fd), "session.open_fd failed")
        self.wait(lambda: self.main is not None and self.main.get_property("agent-connected"), 30,
                  "agent never connected")
        self.wait(lambda: self.main.agent_test_capability(CAP_BY_DEMAND), 10,
                  "agent did not announce clipboard-by-demand")

    def _channel_new(self, session, ch):
        if isinstance(ch, Spice.MainChannel):
            self.main = ch
            if self.max_clipboard is not None:
                ch.set_property("max-clipboard", self.max_clipboard)
            on(ch, "channel-event", self._event)
            on(ch, "main-clipboard-selection-grab", self._grab)
            on(ch, "main-clipboard-selection-request", self._request)
            on(ch, "main-clipboard-selection", self._data)
            on(ch, "main-clipboard-selection-release", self._release)
        # Other channels (display, inputs, ...) ask for their own fd via "open-fd"; we never
        # answer, so they stay idle and cost nothing.

    def _event(self, ch, event):
        if event != Spice.ChannelEvent.OPENED and not self.closing:
            self.lost = True

    def _grab(self, ch, selection, types_ptr, ntypes):
        # Annotated as an array in the typelib, so GI usually hands over a list already.
        if isinstance(types_ptr, (list, tuple)):
            types = list(types_ptr)
        else:
            types = list((ctypes.c_uint32 * ntypes).from_address(types_ptr)) if ntypes else []
        self.grabs.append(types)
        return True

    def _request(self, ch, selection, type_):
        self.requests.append(type_)
        if self.hold_requests:
            self.held.append(type_)
        else:
            self.serve(type_)
        return True

    def serve(self, type_):
        self.main.clipboard_selection_notify(SEL, type_, self.offer.get(type_, b""))

    def _data(self, ch, selection, type_, ptr, size):
        if isinstance(ptr, (bytes, bytearray, list)):
            data = bytes(ptr)
        else:
            data = ctypes.string_at(ptr, size) if size else b""
        self.received.append((type_, data))

    def _release(self, ch, selection):
        self.releases += 1

    def wait(self, cond, timeout, msg):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if self.lost:
                raise TookOver()
            if cond():
                return
            ctx.iteration(False) or time.sleep(0.005)
        if self.lost:
            raise TookOver()
        raise Fail(msg)

    def pump(self, seconds):
        pump(seconds)
        if self.lost:
            raise TookOver()

    def grab(self, offer):
        self.offer = dict(offer)
        self.requests.clear()
        self.main.clipboard_selection_grab(SEL, list(offer))

    def request(self, type_, timeout=30):
        self.received.clear()
        self.main.clipboard_selection_request(SEL, type_)
        self.wait(lambda: self.received, timeout, f"no clipboard data from the agent for type {type_}")
        return self.received[0]

    def close(self):
        if self.closing:
            return
        self.closing = True
        self.session.disconnect()
        pump(0.5)
        self.conn.close()


# ---------------------------------------------------------------------------------------------
# helpers

def sha(b):
    return hashlib.sha256(b).hexdigest()[:16]


def rand_text(n, seed):
    r = random.Random(seed)
    alphabet = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n.,;"
    return "".join(r.choice(alphabet) for _ in range(n))


def test_image(w=97, h=61, seed=1, mode="RGB"):
    r = random.Random(seed)
    im = Image.new(mode, (w, h))
    im.putdata([tuple(r.randrange(256) for _ in mode) for _ in range(w * h)])
    return im


def encode(im, fmt):
    b = io.BytesIO()
    im.save(b, fmt)
    return b.getvalue()


def pixels(data):
    return Image.open(io.BytesIO(data)).convert("RGB").tobytes()


def wait_guest_text(g, c, expect, timeout=15):
    """Poll pbpaste until it equals expect (bytes)."""
    end = time.monotonic() + timeout
    got = None
    while time.monotonic() < end:
        c.pump(0.2)
        got = g.run("pbpaste")
        if got == expect:
            return
    raise Fail(f"guest pasteboard: expected {len(expect)} B sha {sha(expect)}, got {len(got or b'')} B "
               f"sha {sha(got or b'')}: {got[:60]!r}")


def guest_copy_text(g, data):
    g.put("/tmp/sa-in.txt", data)
    g.run("pbcopy < /tmp/sa-in.txt")


def host_to_guest_text(g, c, text):
    data = text.encode()
    c.grab({UTF8: data})
    c.wait(lambda: UTF8 in c.requests, 10, "agent did not request the host text")
    wait_guest_text(g, c, data, timeout=30)


def guest_to_host_text(g, c, text):
    data = text.encode()
    n = len(c.grabs)
    guest_copy_text(g, data)
    c.wait(lambda: len(c.grabs) > n, 5, "agent did not grab after a guest copy")
    check(UTF8 in c.grabs[-1], f"grab types {c.grabs[-1]} lack UTF8")
    t, got = c.request(UTF8, timeout=60)
    check(t == UTF8, f"reply type {t}")
    check(got == data, f"host got {len(got)} B sha {sha(got)}, expected {len(data)} B sha {sha(data)}")


def agent_log(g, since_lines=0):
    return g.run("tail -n +%d ~/Library/Logs/vmlab-spice-agent.log" % (since_lines + 1), check=False).decode(errors="replace")


def log_lines(g):
    return int(g.run("wc -l < ~/Library/Logs/vmlab-spice-agent.log", check=False).strip() or 0)


# ---------------------------------------------------------------------------------------------
# tests: each takes (guest, client) and may replace the client by returning a new one

def t_text_host_to_guest(g, c):
    host_to_guest_text(g, c, f"hello from the host {random.random()}")


def t_text_guest_to_host(g, c):
    guest_to_host_text(g, c, f"hello from the guest {random.random()}")


NON_ASCII = "héllo wörld — 世界 🎉 ﷽ \x11XON \x13XOFF \rCR\r\n \x03\x04\x1a\x7f tab\t end"


def t_non_ascii_both_ways(g, c):
    # Includes XON/XOFF/CR/^C/^D/^Z: proves the tty is raw and 8-bit clean in both directions.
    host_to_guest_text(g, c, NON_ASCII + " h2g")
    guest_to_host_text(g, c, NON_ASCII + " g2h")


def t_big_text_both_ways(g, c):
    big = rand_text(5 * 1024 * 1024, 7)
    t0 = time.monotonic()
    host_to_guest_text(g, c, big)
    t1 = time.monotonic()
    guest_to_host_text(g, c, big[::-1])
    t2 = time.monotonic()
    print(f"    5 MiB host->guest {t1 - t0:.1f} s, guest->host {t2 - t1:.1f} s")


def t_png_host_to_guest(g, c):
    im = test_image(seed=2)
    png = encode(im, "PNG")
    c.grab({PNG: png})
    g.run("rm -f /tmp/sa-out.png /tmp/sa-out.tiff")
    c.wait(lambda: PNG in c.requests, 10, "agent did not request the PNG")
    end = time.monotonic() + 15
    while time.monotonic() < end:
        c.pump(0.2)
        if g.run(f"{REMOTE}/build/pbtool read public.png /tmp/sa-out.png", check=False) is not None and \
                g.run("test -s /tmp/sa-out.png && echo y", check=False).strip() == b"y":
            break
    got = g.get("/tmp/sa-out.png")
    check(got == png, f"guest public.png differs: {len(got)} B vs {len(png)} B")
    # TIFF-only readers: macOS converts the PNG on demand.
    t0 = time.monotonic()
    g.run(f"{REMOTE}/build/pbtool read public.tiff /tmp/sa-out.tiff")
    check(time.monotonic() - t0 < 5, f"lazy TIFF took {time.monotonic() - t0:.1f} s")
    check(pixels(g.get("/tmp/sa-out.tiff")) == im.tobytes(), "lazy TIFF pixels differ")
    g.run("rm -f /tmp/sa-out.png /tmp/sa-out.tiff")


def t_bmp_jpeg_host_to_guest(g, c):
    im = test_image(seed=3)
    for t, fmt in ((BMP, "BMP"), (JPG, "JPEG")):
        g.run("pbcopy < /dev/null")
        c.pump(1)
        data = encode(im, fmt)
        c.grab({t: data})
        c.wait(lambda: t in c.requests, 10, f"agent did not request {fmt}")
        end = time.monotonic() + 15
        while time.monotonic() < end:
            c.pump(0.2)
            if b"public.png" in g.run(f"{REMOTE}/build/pbtool types"):
                break
        g.run(f"{REMOTE}/build/pbtool read public.png /tmp/sa-out.png")
        got = pixels(g.get("/tmp/sa-out.png"))
        want = pixels(data)
        if t == BMP:
            check(got == want, "BMP->PNG pixels differ")
        else:
            # JPEG decoders (libjpeg here, ImageIO in the guest) round differently; allow that.
            diff = [abs(x - y) for x, y in zip(got, want)]
            check(len(got) == len(want) and sum(diff) / len(diff) < 4, f"JPEG->PNG pixels differ "
                  f"(mean {sum(diff) / max(len(diff), 1):.1f})")


def t_png_guest_to_host(g, c):
    im = test_image(seed=4)
    png = encode(im, "PNG")
    g.put("/tmp/sa-in.png", png)
    n = len(c.grabs)
    g.run(f"{REMOTE}/build/pbtool write public.png /tmp/sa-in.png")
    c.wait(lambda: len(c.grabs) > n, 5, "no grab after a guest PNG copy")
    check(PNG in c.grabs[-1], f"grab types {c.grabs[-1]} lack PNG")
    t, got = c.request(PNG)
    check(t == PNG and got == png, f"host PNG differs ({len(got)} B vs {len(png)} B)")
    # An app that only puts TIFF on the pasteboard: the agent converts to PNG.
    tiff = encode(test_image(seed=5), "TIFF")
    g.put("/tmp/sa-in.tiff", tiff)
    n = len(c.grabs)
    g.run(f"{REMOTE}/build/pbtool write public.tiff /tmp/sa-in.tiff")
    c.wait(lambda: len(c.grabs) > n, 5, "no grab after a guest TIFF copy")
    check(c.grabs[-1] == [PNG], f"grab types {c.grabs[-1]}, expected [PNG]")
    t, got = c.request(PNG)
    check(got[:8] == b"\x89PNG\r\n\x1a\n", "TIFF did not arrive as PNG")
    check(pixels(got) == test_image(seed=5).tobytes(), "TIFF->PNG pixels differ")


def t_echo_loop(g, c):
    # Host -> guest: the agent writes the pasteboard and must not grab it back.
    n = len(c.grabs)
    host_to_guest_text(g, c, f"echo check {random.random()}")
    c.pump(2.5)
    check(len(c.grabs) == n, f"agent grabbed its own write back: {c.grabs[n:]}")
    # Guest -> host: one copy means one grab, also after the host reads it twice.
    guest_to_host_text(g, c, f"single grab {random.random()}")
    n = len(c.grabs)
    c.request(UTF8)
    c.request(UTF8)
    c.pump(2.5)
    check(len(c.grabs) == n, f"extra grabs after the host read: {c.grabs[n:]}")


def t_guest_copy_wins_race(g, c):
    # The host grabs, but its data arrives only after the guest copied something else.
    c.hold_requests = True
    c.held.clear()
    c.grab({UTF8: b"stale host text"})
    c.wait(lambda: c.held, 10, "agent did not request")
    n = len(c.grabs)
    guest = f"newer guest text {random.random()}".encode()
    guest_copy_text(g, guest)
    c.wait(lambda: len(c.grabs) > n, 5, "no grab for the newer guest copy")
    c.hold_requests = False
    c.serve(c.held.pop())
    c.pump(1.5)
    check(g.run("pbpaste") == guest, "late host data overwrote a newer guest copy")
    # And the next host copy goes through normally.
    host_to_guest_text(g, c, f"after race {random.random()}")


def t_max_clipboard(g, c):
    c.close()
    c = Client(max_clipboard=1000)
    try:
        check(c.main.agent_test_capability(CAP_MAX_CLIPBOARD), "agent lacks the max-clipboard cap")
        guest_copy_text(g, b"x" * 5000)
        c.wait(lambda: c.grabs, 5, "no grab")
        t, got = c.request(UTF8)
        check(got == b"", f"agent sent {len(got)} B past a 1000 B limit")
        guest_to_host_text(g, c, "small enough")
    finally:
        c.close()
    return Client()


def t_reconnect(g, c):
    for i in range(3):
        c.close()
        pump(1)
        c = Client()
        host_to_guest_text(g, c, f"reconnect {i} h2g {random.random()}")
        guest_to_host_text(g, c, f"reconnect {i} g2h {random.random()}")
    return c


def t_copy_while_disconnected(g, c):
    # A guest copy made with no client connected is not pushed when a client connects (it would
    # clobber the host clipboard), but the next copy after that is.
    c.close()
    guest_copy_text(g, b"made while nobody watched")
    c = Client()
    c.pump(2)
    check(not c.grabs, f"agent grabbed a stale copy on connect: {c.grabs}")
    guest_to_host_text(g, c, f"after connect {random.random()}")
    return c


def t_agent_restart(g, c):
    lines = log_lines(g)
    g.run("launchctl kickstart -k gui/$(id -u)/local.vmlab.spice-agent")
    c.wait(lambda: not c.main.get_property("agent-connected"), 15, "client never saw the agent go")
    c.wait(lambda: c.main.get_property("agent-connected"), 30, "agent did not come back")
    c.wait(lambda: c.main.agent_test_capability(CAP_BY_DEMAND), 10, "no caps after restart")
    # Not straight away: an early bug let only the first messages after a restart through.
    c.pump(3)
    host_to_guest_text(g, c, f"after restart h2g {random.random()}")
    guest_to_host_text(g, c, f"after restart g2h {random.random()}")
    log = agent_log(g, lines)
    check("starting" in log and "client connected" in log, f"unexpected agent log:\n{log}")


def t_no_mouse_state(g, c):
    # <mouse mode='server'/> in the domain = QEMU agent-mouse=off: the USB tablet keeps the absolute
    # pointer (SPICE reports that as "client" mouse mode) and spice-server never sends MOUSE_STATE.
    pid = subprocess.check_output(["pgrep", "-f", "^/usr/bin/qemu-system-x86_64 -name guest=macos"], text=True).split()[0]
    cmdline = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ")
    check(b"agent-mouse=off" in cmdline, "QEMU runs without agent-mouse=off")
    check("MOUSE_STATE" not in agent_log(g), "agent received MOUSE_STATE messages")


def self_finish(ch, res):
    try:
        return ch.file_copy_finish(res)
    except GLib.Error as e:
        return e.message


def send_files(c, items):
    """Drop each (name, bytes) on the agent, one transfer per file (as the viewer does for one
    file); returns the per-file results (True or an error message)."""
    tmp = tempfile.mkdtemp(prefix="spice-drop-")
    results = []
    try:
        for i, (name, data) in enumerate(items):
            d = os.path.join(tmp, str(i))
            os.mkdir(d)
            p = os.path.join(d, os.path.basename(name))
            open(p, "wb").write(data)
            done = []
            c.main.file_copy_async([Gio.File.new_for_path(p)], Gio.FileCopyFlags.NONE, None, None, None,
                                   lambda ch, res, dn=done: dn.append(self_finish(ch, res)))
            c.wait(lambda: done, 60, f"file transfer of {name} never finished")
            results.append(done[0])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return results


def set_agent_args(g, extra):
    """Reload the LaunchAgent with extra arguments; an empty list puts the installed plist back."""
    plist = "~/Library/LaunchAgents/local.vmlab.spice-agent.plist"
    keep = "/tmp/sa-installed.plist"
    g.run(f"test -e {keep} || cp {plist} {keep}; cp {keep} {plist}")
    for a in extra:
        g.run(f"/usr/libexec/PlistBuddy -c 'Add :ProgramArguments: string {a}' {plist}")
    if not extra:
        g.run(f"rm -f {keep}")
    g.run(f"launchctl bootout gui/$(id -u)/local.vmlab.spice-agent; for i in $(seq 10); do "
          f"launchctl bootstrap gui/$(id -u) {plist} 2>/dev/null && break; sleep 1; done", check=False)


def wait_agent_back(c):
    c.wait(lambda: not c.main.get_property("agent-connected"), 15, "client never saw the agent go")
    c.wait(lambda: c.main.get_property("agent-connected"), 30, "agent did not come back")


def t_file_drop_desktop(g, c):
    # SSH sessions have no TCC access to ~/Desktop: they can stat files there but not read or
    # delete them. So check names and sizes here, and contents in t_file_drop_contents.
    m = f"sa{random.randrange(1 << 30):x}"
    items = [(f"{m} plain.txt", b"hello file\n"), (f"{m} big ü.bin", os.urandom(3 * 1024 * 1024 + 17)),
             (f"{m} empty.dat", b""), (f"{m} plain.txt", b"second copy\n")]
    res = send_files(c, items)
    check(all(r is True for r in res), f"transfer results {res}")
    want = {f"{m} plain.txt": 11, f"{m} big ü.bin": 3 * 1024 * 1024 + 17, f"{m} empty.dat": 0,
            f"{m} plain (1).txt": 12}
    for name, size in want.items():
        got = g.run(f"stat -f %z ~/Desktop/'{name}' 2>/dev/null", check=False).strip()
        check(got == str(size).encode(), f"~/Desktop/{name}: size {got!r}, expected {size}")


def t_file_drop_contents(g, c):
    drop = f"/tmp/sa-drop-{random.randrange(1 << 30):x}"
    g.run(f"mkdir -p {drop}")
    set_agent_args(g, ["--drop-dir", drop])
    try:
        wait_agent_back(c)
        items = [("plain.txt", b"hello file\n"), ("with space ü.bin", os.urandom(3 * 1024 * 1024 + 17)),
                 ("empty.dat", b""), ("../escape.txt", b"no escape"), (".hidden", b"dotfile"),
                 ("plain.txt", b"second copy\n"), ("ctrl\x01chars.txt", b"ctl")]
        res = send_files(c, items)
        check(all(r is True for r in res), f"transfer results {res}")
        want = {"plain.txt": items[0][1], "with space ü.bin": items[1][1], "empty.dat": b"",
                "escape.txt": items[3][1], "hidden": items[4][1], "plain (1).txt": items[5][1],
                "ctrlchars.txt": items[6][1]}
        listing = g.run(f"cd {drop} && shasum -a 256 *").decode()
        got = {line.split("  ", 1)[1]: line.split("  ", 1)[0] for line in listing.splitlines()}
        for name, data in want.items():
            check(got.get(name) == hashlib.sha256(data).hexdigest(), f"{drop}/{name} missing or wrong")
        check(set(got) == set(want), f"unexpected files: {sorted(set(got) - set(want))}")
        check(g.run("test -e /tmp/escape.txt && echo y || echo n").strip() == b"n", "file escaped the drop dir")
    finally:
        set_agent_args(g, [])
        wait_agent_back(c)
        g.run(f"rm -rf {drop}", check=False)


def t_file_cancel(g, c):
    # spice-gtk 0.42 sends no CANCELLED status: it just stops sending data. The agent drops a
    # transfer idle for 20 s and deletes the partial file.
    name = f"sa{random.randrange(1 << 30):x}-cancel.bin"
    tmp = tempfile.mkdtemp(prefix="spice-drop-")
    p = os.path.join(tmp, name)
    open(p, "wb").write(os.urandom(64 * 1024 * 1024))

    def size():
        o = g.run(f"stat -f %z ~/Desktop/{name} 2>/dev/null", check=False).strip()
        return int(o) if o.isdigit() else -1
    try:
        done = []
        cancel = Gio.Cancellable()
        c.main.file_copy_async([Gio.File.new_for_path(p)], Gio.FileCopyFlags.NONE, cancel, None, None,
                               lambda ch, res: done.append(self_finish(ch, res)))
        c.wait(lambda: size() > 1 << 20, 60, "transfer never got going")
        cancel.cancel()
        c.wait(lambda: done, 30, "cancelled transfer never finished")
        check(done[0] is not True, "cancelled transfer reported success")
        c.wait(lambda: size() == -1, 40, "partial file still on the Desktop 40 s after the cancel")
        host_to_guest_text(g, c, f"after cancel {random.random()}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


TESTS = [
    t_text_host_to_guest, t_text_guest_to_host, t_non_ascii_both_ways, t_big_text_both_ways,
    t_png_host_to_guest, t_bmp_jpeg_host_to_guest, t_png_guest_to_host, t_echo_loop,
    t_guest_copy_wins_race, t_max_clipboard, t_reconnect, t_copy_while_disconnected,
    t_agent_restart, t_no_mouse_state, t_file_drop_desktop, t_file_drop_contents, t_file_cancel,
]


def main():
    words = sys.argv[1:]
    tests = [t for t in TESTS if not words or any(w in t.__name__ for w in words)]
    g = Guest()
    try:
        # (Re)build the helper unless it is there and answers.
        if not g.run(f"{REMOTE}/build/pbtool count 2>/dev/null", check=False).strip().isdigit():
            src = open(os.path.join(os.path.dirname(__file__), "pbtool.swift"), "rb").read()
            g.put("/tmp/pbtool.swift", src)
            g.run(f"mkdir -p {REMOTE}/build && swiftc -O -o {REMOTE}/build/pbtool /tmp/pbtool.swift")
        c = Client()
        failed = 0
        for t in tests:
            t0 = time.monotonic()
            try:
                r = t(g, c)
                if isinstance(r, Client):
                    c = r
                print(f"PASS {t.__name__} ({time.monotonic() - t0:.1f} s)", flush=True)
            except TookOver:
                print(f"STOP {t.__name__}: our SPICE connection dropped; the user probably opened the "
                      "viewer. Not reconnecting.", flush=True)
                return 3
            except Fail as e:
                failed += 1
                print(f"FAIL {t.__name__}: {e}", flush=True)
        c.close()
        print(f"{len(tests) - failed}/{len(tests)} passed")
        return 1 if failed else 0
    finally:
        g.close()


if __name__ == "__main__":
    sys.exit(main())
