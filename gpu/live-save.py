"""live-save.py: save a running VM's disk as a named state, the VM running on (vm save --live).

  live-save.py win QMP_SOCK GA_SOCK DISK TOP TARGET
      Windows: the guest agent has Windows flush its disk and hold writes (VSS, as a backup
      program does); QEMU puts a new layer TOP (made empty by the launcher, on DISK) over
      the running disk, so DISK takes no more writes, and Windows is let go: it was held for
      well under a second. TARGET is then a reflink copy of DISK, which takes no room (the
      two share their blocks, as `vm save` of a stopped VM does), and a commit job puts what
      Windows wrote to TOP meanwhile back into DISK and drops TOP. DISK, TOP and TARGET on
      one XFS file system.
  live-save.py mac QMP_SOCK NAME
      Mac: an internal snapshot NAME in the running disk file, as `qemu-img snapshot -c`
      makes for a stopped one. One taken as "~save" first, so a state NAME of before stays
      until the new one is there.

The disk only, not the memory: a state saved this way starts with a fresh boot. QMP's socket
takes one client at a time and others use it too (vm gui, screenshots), so each command is a
connection of its own. Progress goes to stderr; the last line on stdout says what was saved.
"""
import json
import os
import random
import socket
import subprocess
import sys
import time


def die(msg):
    print(f"live-save: {msg}", file=sys.stderr)
    sys.exit(1)


def qmp(sock, command, args=None, timeout=60):
    """One QMP command on a connection of its own; its return value, or die with its error."""
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    try:
        s.connect(sock)
    except OSError as e:
        die(f"cannot reach QEMU at {sock}: {e}")
    with s, s.makefile('rw') as f:
        f.readline()                                   # the greeting
        f.write('{"execute":"qmp_capabilities"}\n')
        f.flush()
        f.readline()
        msg = {"execute": command}
        if args is not None:
            msg["arguments"] = args
        f.write(json.dumps(msg) + "\n")
        f.flush()
        while True:
            line = f.readline()
            if not line:
                die(f"QEMU closed the connection during {command}")
            r = json.loads(line)
            if "return" in r:
                return r["return"]
            if "error" in r:
                raise QmpError(command, r["error"].get("desc", str(r["error"])))


class QmpError(Exception):
    def __init__(self, command, desc):
        super().__init__(f"{command}: {desc}")


class Agent:
    """The QEMU guest agent in Windows, over its virtio port (a socket here)."""

    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(10)
        try:
            self.s.connect(path)
        except OSError as e:
            die(f"cannot reach the guest agent at {path}: {e}")
        self.f = self.s.makefile('rwb')
        # guest-sync-delimited: the agent answers after a 0xFF byte, which ends whatever an
        # earlier client left half-read in the port; replies before ours are skipped
        token = random.randrange(1, 2**31)
        self.f.write(b"\xff" + json.dumps({"execute": "guest-sync-delimited",
                                           "arguments": {"id": token}}).encode() + b"\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                die("the guest agent closed the connection")
            line = line.lstrip(b"\xff").strip()
            if line and json.loads(line).get("return") == token:
                break

    def run(self, path, *args):
        """A program in Windows (as SYSTEM), waited for; its exit code."""
        pid = self.call("guest-exec", args={"path": path, "arg": list(args)})["pid"]
        for _ in range(100):
            st = self.call("guest-exec-status", args={"pid": pid})
            if st.get("exited"):
                return st.get("exitcode", -1)
            time.sleep(0.1)
        return -1

    def call(self, command, timeout=10, args=None):
        self.s.settimeout(timeout)
        msg = {"execute": command}
        if args is not None:
            msg["arguments"] = args
        self.f.write(json.dumps(msg).encode() + b"\n")
        self.f.flush()
        r = json.loads(self.f.readline())
        if "error" in r:
            raise QmpError(command, r["error"].get("desc", str(r["error"])))
        return r.get("return")


def save_win(qmp_sock, ga_sock, disk, top, target):
    node, job = "vmlab-live-top", "vmlab-live-commit"
    try:
        qmp(qmp_sock, "blockdev-add", {
            "driver": "qcow2", "node-name": node, "backing": None, "discard": "unmap",
            "cache": {"direct": True},
            "file": {"driver": "file", "filename": top, "aio": "io_uring", "cache": {"direct": True}}})
    except QmpError as e:
        die(str(e))
    agent = Agent(ga_sock)
    status = agent.call("guest-fsfreeze-status")
    if status != "thawed":
        qmp(qmp_sock, "blockdev-del", {"node-name": node})
        die(f"Windows' disk is already held ({status}): another save or backup is running")
    # A state saved this way boots as after a power cut, and a run of such boots (a state
    # saved again from one) puts Windows into Automatic Repair, which then fails: its boot
    # manager is told to start Windows all the same (2026-11-24, tried twice each way)
    for arg in (("bootstatuspolicy", "IgnoreAllFailures"), ("recoveryenabled", "No")):
        if agent.run("C:\\Windows\\System32\\bcdedit.exe", "/set", "{current}", *arg) != 0:
            print(f"live-save: bcdedit /set {arg[0]} {arg[1]} failed", file=sys.stderr)
    t = time.monotonic()
    try:
        # VSS: the writers (the file system and the like) flush and hold; Windows lets go by
        # itself after 10 s at the latest
        agent.call("guest-fsfreeze-freeze", timeout=60)
    except QmpError as e:
        qmp(qmp_sock, "blockdev-del", {"node-name": node})
        die(f"Windows did not flush its disk ({e}); nothing was saved")
    flushed = time.monotonic()
    try:
        qmp(qmp_sock, "blockdev-snapshot", {"node": "disk0", "overlay": node})
    except QmpError as e:
        agent.call("guest-fsfreeze-thaw", timeout=30)
        qmp(qmp_sock, "blockdev-del", {"node-name": node})
        die(str(e))
    try:
        agent.call("guest-fsfreeze-thaw", timeout=30)
    except (QmpError, OSError) as e:
        print(f"live-save: Windows was not told to go on ({e}); it does by itself in 10 s",
              file=sys.stderr)
    print(f"live-save: Windows flushed its disk in {flushed - t:.1f} s and held its writes"
          f" {time.monotonic() - flushed:.1f} s", file=sys.stderr)

    # DISK takes no writes now: its copy is the disk of that moment
    copied = subprocess.run(["cp", "--reflink=always", disk, target]).returncode == 0

    # TOP back into DISK, whatever the copy did: the launcher knows only DISK
    try:
        qmp(qmp_sock, "block-commit", {"job-id": job, "device": node, "base-node": "disk0",
                                        "auto-finalize": True, "auto-dismiss": False})
        while True:
            j = {j["id"]: j for j in qmp(qmp_sock, "query-jobs")}.get(job)
            if j is None:
                raise QmpError("block-commit", "the commit job is gone")
            if j["status"] == "ready":
                qmp(qmp_sock, "job-complete", {"id": job})
            elif j["status"] == "concluded":
                qmp(qmp_sock, "job-dismiss", {"id": job})
                if j.get("error"):
                    raise QmpError("block-commit", j["error"])
                break
            time.sleep(0.2)
    except QmpError as e:
        die(f"{e}. Windows still writes to {top}, over {disk}: stopping the VM now loses "
            f"those writes. Commit it by hand (QMP block-commit device {node}, base-node disk0)")
    if not copied:
        die(f"the reflink copy of {disk} failed; nothing was saved")
    print(f"saved {target}")


def save_mac(qmp_sock, name):
    tmp = "~save"            # no state's name (st_valid), so never one of the user's
    have = {s["name"] for s in snapshots(qmp_sock)}
    try:
        if tmp in have:
            qmp(qmp_sock, "blockdev-snapshot-delete-internal-sync", {"device": "disk", "name": tmp})
        qmp(qmp_sock, "blockdev-snapshot-internal-sync", {"device": "disk", "name": tmp})
        if name in have:
            qmp(qmp_sock, "blockdev-snapshot-delete-internal-sync", {"device": "disk", "name": name})
        qmp(qmp_sock, "blockdev-snapshot-internal-sync", {"device": "disk", "name": name})
        qmp(qmp_sock, "blockdev-snapshot-delete-internal-sync", {"device": "disk", "name": tmp})
    except QmpError as e:
        die(str(e))
    print(f"saved {name}")


def snapshots(qmp_sock):
    for b in qmp(qmp_sock, "query-block"):
        if b.get("device") == "disk":
            return b.get("inserted", {}).get("image", {}).get("snapshots", [])
    die("the Mac's disk (drive 'disk') is not in QEMU")


if __name__ == "__main__":
    if len(sys.argv) == 7 and sys.argv[1] == "win":
        save_win(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "mac":
        save_mac(*sys.argv[2:])
    else:
        die("usage: live-save.py win QMP GA DISK TOP TARGET | mac QMP NAME")
