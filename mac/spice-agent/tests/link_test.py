#!/usr/bin/env python3
"""link_test.py [ROUNDS [MEGABYTES]]: the agent's link, end to end, from the host.

Run on the host with the Mac running (no window needed) and the agent installed. The script is
its own client: it forwards the agent's socket with `ssh -L` to a socket of its own and speaks
the protocol there, so neither the lab's window nor the host's clipboard takes part. The guest's
pasteboard is read and written with pbpaste and pbcopy over SSH.

  - text host to guest and guest to host
  - a second connection replaces the first, which is closed
  - the agent restarted: the connection ends, and the next one works
  - ROUNDS times (default 4): MEGABYTES (default 60) of text each way, compared by SHA-256.
    The virtio serial port this link replaced stalled within 130 MB; 30 rounds are 3.6 GB.

Uses only the Python standard library.
"""
import hashlib
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

PORT = 2227
KEY = os.path.expanduser("~/.ssh/vmlab_ed25519")
KNOWN = "/vmlab/reims-dev/data/reims-ctl/vms/mac26d/known_hosts"
GUEST_SOCK = "/Users/dev/Library/Caches/vmlab-spice-agent.sock"
SSH = ["ssh", "-i", KEY, "-o", "UserKnownHostsFile=" + KNOWN, "-o", "StrictHostKeyChecking=accept-new",
       "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "-p", str(PORT)]
HOST = "dev@127.0.0.1"

CLIPBOARD, ANNOUNCE, GRAB, REQUEST, RELEASE = 4, 6, 7, 8, 9
UTF8 = 1
CAPS = 1 << 5 | 1 << 10          # clipboard by demand, max clipboard
CLIENT_PORT, CHUNK = 1, 2048


class Fail(Exception):
    pass


def guest(command, data=None):
    r = subprocess.run(SSH + [HOST, command], input=data, capture_output=True, timeout=300)
    if r.returncode:
        raise Fail(f"guest command failed ({command}): {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


class Client:
    """One connection to the agent."""

    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.pending = bytearray()      # payload bytes of chunks, not yet a whole message
        self.caps = None

    def close(self):
        self.s.close()

    def send(self, kind, data=b""):
        message = struct.pack("<IIQI", 1, kind, 0, len(data)) + data
        wire = bytearray()
        for i in range(0, len(message), CHUNK):
            part = message[i:i + CHUNK]
            wire += struct.pack("<II", CLIENT_PORT, len(part)) + part
        self.s.sendall(wire)

    def _read(self, n, deadline):
        out = bytearray()
        while len(out) < n:
            self.s.settimeout(max(0.01, deadline - time.monotonic()))
            try:
                got = self.s.recv(min(1 << 20, n - len(out)))
            except socket.timeout:
                raise Fail("nothing from the agent in time") from None
            if not got:
                raise EOFError
            out += got
        return out

    def recv(self, wait=10.0):
        """The next message: (type, data). `wait` is the longest silence, not the whole time."""
        while True:
            if len(self.pending) >= 20:
                kind, size = struct.unpack_from("<I", self.pending, 4)[0], struct.unpack_from("<I", self.pending, 16)[0]
                if len(self.pending) >= 20 + size:
                    data = bytes(self.pending[20:20 + size])
                    del self.pending[:20 + size]
                    return kind, data
            _, size = struct.unpack("<II", self._read(8, time.monotonic() + wait))
            self.pending += self._read(size, time.monotonic() + wait)

    def expect(self, kind, wait=10.0):
        """The next message of that type; announcements update `caps`, the rest is passed over."""
        end = time.monotonic() + 600
        while time.monotonic() < end:
            got, data = self.recv(wait)
            if got == ANNOUNCE:
                self.caps = data
            if got == kind:
                return data
        raise Fail(f"no message of type {kind}")

    def greet(self):
        self.send(ANNOUNCE, struct.pack("<II", 1, CAPS))
        self.expect(ANNOUNCE)

    def to_guest(self, text):
        """Offer text, serve the agent's request for it."""
        self.send(GRAB, struct.pack("<I", UTF8))
        asked = self.expect(REQUEST)
        if struct.unpack("<I", asked[:4])[0] != UTF8:
            raise Fail(f"the agent asked for type {asked!r}")
        self.send(CLIPBOARD, struct.pack("<I", UTF8) + text)

    def from_guest(self):
        """Wait for the agent's offer, fetch its text."""
        offer = self.expect(GRAB, wait=15)
        types = struct.unpack(f"<{len(offer) // 4}I", offer)
        if UTF8 not in types:
            raise Fail(f"the agent offered {types}, no text")
        self.send(REQUEST, struct.pack("<I", UTF8))
        data = self.expect(CLIPBOARD, wait=30)
        return data[4:]


def pasteboard_is(want, wait=20.0):
    """Whether the guest's pasteboard holds `want` within `wait` seconds (by hash when large)."""
    digest = hashlib.sha256(want).hexdigest()
    end = time.monotonic() + wait
    while True:
        got = guest("pbpaste | shasum -a 256").split()[0].decode()
        if got == digest:
            return
        if time.monotonic() > end:
            raise Fail(f"the guest's pasteboard is not what was sent ({len(want)} bytes)")
        time.sleep(0.5)


def text_of(megabytes, seed):
    """Printable ASCII with line ends, different for every seed, cheap to make."""
    block = hashlib.sha256(seed.encode()).hexdigest().encode() * 16 + b"\n"      # 1025 bytes
    lines = megabytes * (1 << 20) // len(block)
    return b"".join(b"%08d " % i + block for i in range(lines))


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    megabytes = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    tmp = tempfile.mkdtemp(prefix="vmlab-link-")
    sock = os.path.join(tmp, "agent.sock")
    forward = subprocess.Popen(SSH + ["-N", "-T", "-o", "ExitOnForwardFailure=yes", "-L", f"{sock}:{GUEST_SOCK}", HOST])
    failed = 0
    try:
        for _ in range(100):
            if os.path.exists(sock):
                break
            time.sleep(0.1)

        def step(name, body):
            nonlocal failed
            start = time.monotonic()
            try:
                note = body() or ""
                print(f"ok    {name} ({time.monotonic() - start:.1f} s) {note}", flush=True)
            except (Fail, EOFError, OSError) as e:
                failed += 1
                print(f"FAIL  {name}: {e!r}", flush=True)

        c = Client(sock)

        def small():
            c.greet()
            text = f"host to guest {time.time()}\nzwei Zeilen, äöü €".encode()
            c.to_guest(text)
            pasteboard_is(text)
            back = f"guest to host {time.time()} äöü".encode()
            guest("pbcopy", back)
            if c.from_guest() != back:
                raise Fail("the guest's text came back different")
        step("text both ways", small)

        def replaced():
            nonlocal c
            newer = Client(sock)
            newer.greet()
            try:
                c.recv(wait=5)
                raise Fail("the first connection still gets messages")
            except EOFError:
                pass
            c.close()
            c = newer
            text = b"after the second connection"
            c.to_guest(text)
            pasteboard_is(text)
        step("a second connection replaces the first", replaced)

        def restarted():
            nonlocal c
            guest("launchctl kickstart -k gui/$(id -u)/local.vmlab.spice-agent")
            try:
                while True:
                    c.recv(wait=10)
            except EOFError:
                pass
            c.close()
            end = time.monotonic() + 20
            while True:
                try:
                    c = Client(sock)
                    c.greet()
                    break
                except (EOFError, OSError, Fail):
                    if time.monotonic() > end:
                        raise Fail("no connection to the restarted agent in 20 s") from None
                    time.sleep(0.5)
            text = b"after the agent's restart"
            c.to_guest(text)
            pasteboard_is(text)
        step("the agent restarted", restarted)

        total = 0
        for n in range(rounds):
            def big():
                nonlocal total
                down = text_of(megabytes, f"down {n} {time.time()}")
                c.to_guest(down)
                pasteboard_is(down, wait=120)
                up = text_of(megabytes, f"up {n} {time.time()}")
                guest("cat > /tmp/vmlab-link-up.txt && pbcopy < /tmp/vmlab-link-up.txt && rm /tmp/vmlab-link-up.txt", up)
                got = c.from_guest()
                if hashlib.sha256(got).digest() != hashlib.sha256(up).digest():
                    raise Fail(f"{len(got)} bytes came back, not the {len(up)} sent")
                total += len(down) + len(up)
                return f"{total / (1 << 30):.2f} GB so far"
            step(f"{megabytes} MB each way, round {n + 1}", big)
        c.close()
    finally:
        forward.terminate()
        forward.wait()
        try:
            os.unlink(sock)
        except OSError:
            pass
        os.rmdir(tmp)
    print("all passed" if not failed else f"{failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
