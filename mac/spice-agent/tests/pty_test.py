#!/usr/bin/env python3
"""pty_test.py AGENT_BINARY: device-level tests, run inside the VM (test_agent.py copies it over).

Runs a second copy of the agent against a pseudo-terminal that stands in for the virtio port, so
the port can be made to go missing, close and come back, which the real device cannot do on demand:
  - device absent at start: the agent retries, then opens it once it appears, announces caps
  - client ANNOUNCE fed one byte at a time: reassembled, answered
  - one message split over three chunks of odd sizes plus an empty chunk: reassembled, answered
  - CLIENT_DISCONNECTED in the middle of a client message: the half message is dropped
  - chunk for an unknown port: protocol error, the agent reopens the port and announces again
  - the port closes (master side hangs up) and a new one appears: reopened, announced again
Exclusive open is checked on the real device by test_agent.py: macOS ptys ignore TIOCEXCL.
Uses only the Python standard library (the Command Line Tools' python3).
"""
import os
import select
import struct
import subprocess
import sys
import tempfile
import time

ANNOUNCE, REPLY, MONITORS_CONFIG, CLIENT_DISCONNECTED = 6, 3, 2, 13
CLIENT, SERVER = 1, 2

agent_bin = sys.argv[1]
tmp = tempfile.mkdtemp(prefix="sa-pty-")
link = os.path.join(tmp, "port")
failures = []


def chunk(port, payload):
    return struct.pack("<II", port, len(payload)) + payload


def msg(type_, data=b""):
    return struct.pack("<IIQI", 1, type_, 0, len(data)) + data


class Pty:
    def __init__(self):
        self.master, slave = os.openpty()
        self.name = os.ttyname(slave)
        os.close(slave)
        self.buf = b""
        self.msgs = []
        self.partial = {CLIENT: b"", SERVER: b""}
        tmp_link = link + ".new"
        if os.path.lexists(tmp_link):
            os.unlink(tmp_link)
        os.symlink(self.name, tmp_link)
        os.replace(tmp_link, link)

    def write(self, b, bytewise=False):
        if bytewise:
            for i in range(len(b)):
                os.write(self.master, b[i:i + 1])
                time.sleep(0.002)
        else:
            os.write(self.master, b)

    def read_msgs(self, timeout):
        """Collect agent->client messages for up to `timeout` s; returns new (type, data) list."""
        end = time.monotonic() + timeout
        out = []
        while time.monotonic() < end:
            r, _, _ = select.select([self.master], [], [], 0.1)
            if not r:
                if out:
                    break
                continue
            try:
                self.buf += os.read(self.master, 65536)
            except OSError:          # EIO while no one has the slave open
                time.sleep(0.1)
                continue
            while len(self.buf) >= 8:
                port, size = struct.unpack("<II", self.buf[:8])
                if len(self.buf) < 8 + size:
                    break
                self.partial[port] = self.partial.get(port, b"") + self.buf[8:8 + size]
                self.buf = self.buf[8 + size:]
                p = self.partial[port]
                while len(p) >= 20:
                    _, t, _, n = struct.unpack("<IIQI", p[:20])
                    if len(p) < 20 + n:
                        break
                    out.append((t, p[20:20 + n]))
                    p = p[20 + n:]
                self.partial[port] = p
        return out

    def close(self):
        os.close(self.master)


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what, flush=True)
    if not cond:
        failures.append(what)


def announces(msgs, request=None):
    return [m for m in msgs if m[0] == ANNOUNCE and (request is None or struct.unpack("<I", m[1][:4])[0] == request)]


def client_announce():
    # request=1, caps word with clipboard-by-demand (bit 5)
    return msg(ANNOUNCE, struct.pack("<II", 1, 1 << 5))


def monitors_config():
    return msg(MONITORS_CONFIG, struct.pack("<II", 1, 0) + bytes(20))


def replies(msgs):
    return [m for m in msgs if m[0] == REPLY and struct.unpack("<I", m[1][:4])[0] == MONITORS_CONFIG]


log_path = os.path.join(tmp, "agent.log")
logf = open(log_path, "w")
agent = subprocess.Popen([agent_bin, "--drop-dir", os.path.join(tmp, "drop"), link], stderr=logf, stdout=logf)
try:
    time.sleep(1.5)
    log = open(log_path).read()
    check("cannot open" in log and agent.poll() is None, "device absent: agent waits and retries")

    p = Pty()
    m = p.read_msgs(6)
    check(len(announces(m, 1)) == 1, f"device appears: agent opens it and announces (got {[t for t, _ in m]})")

    p.write(chunk(CLIENT, client_announce()), bytewise=True)
    m = p.read_msgs(3)
    check(len(announces(m, 0)) == 1, "client ANNOUNCE fed byte by byte: agent answers")

    mc = monitors_config()
    p.write(chunk(CLIENT, mc[:3]) + chunk(CLIENT, b"") + chunk(CLIENT, mc[3:25]) + chunk(CLIENT, mc[25:]))
    m = p.read_msgs(3)
    check(len(replies(m)) == 1, "message split over odd chunks and an empty chunk: reassembled")

    p.write(chunk(CLIENT, mc[:30]) + chunk(SERVER, msg(CLIENT_DISCONNECTED)) + chunk(CLIENT, mc))
    m = p.read_msgs(3)
    check(len(replies(m)) == 1, f"CLIENT_DISCONNECTED mid-message: half message dropped ({len(replies(m))} replies)")

    p.write(chunk(7, b"junk"))
    m = p.read_msgs(5)
    check(len(announces(m, 1)) == 1, "chunk for an unknown port: agent reopens and announces again")

    p.close()
    time.sleep(3)
    check(agent.poll() is None, "port hung up: agent still running")
    p = Pty()
    m = p.read_msgs(8)
    check(len(announces(m, 1)) == 1, "a new port appears: agent reopens and announces again")
    p.write(chunk(CLIENT, monitors_config()))
    check(len(replies(p.read_msgs(3))) == 1, "after the reopen: messages flow")
    p.close()
finally:
    for proc in (agent,):
        if proc and proc.poll() is None:
            proc.terminate()
            proc.wait()
    logf.close()
    if failures:
        print("--- agent log ---\n" + open(log_path).read())
    subprocess.call(["rm", "-rf", tmp])
print("pty: all passed" if not failures else f"pty: {len(failures)} failed")
sys.exit(1 if failures else 0)
