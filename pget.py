#!/usr/bin/env python3
"""Parallel ranged downloader (curl per segment, resumable). Usage: pget.py URL OUT SIZE [PARTS]"""
import os, subprocess, sys, threading

url, out, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
parts = int(sys.argv[4]) if len(sys.argv) > 4 else 8
seg = -(-size // parts)
tmp = out + ".parts"
os.makedirs(tmp, exist_ok=True)

def fetch(i):
    start, end = i * seg, min(size, (i + 1) * seg) - 1
    p = os.path.join(tmp, f"{i:03d}")
    want = end - start + 1
    for attempt in range(30):
        have = os.path.getsize(p) if os.path.exists(p) else 0
        if have >= want:
            return
        subprocess.run(["curl", "-sS", "--fail", "-r", f"{start + have}-{end}", url, "-o", "-"],
                       stdout=open(p, "ab"), timeout=None)
    raise SystemExit(f"segment {i} failed")

threads = [threading.Thread(target=fetch, args=(i,)) for i in range(parts)]
[t.start() for t in threads]
[t.join() for t in threads]
with open(out, "wb") as f:
    for i in range(parts):
        p = os.path.join(tmp, f"{i:03d}")
        with open(p, "rb") as s:
            while chunk := s.read(1 << 24):
                f.write(chunk)
assert os.path.getsize(out) == size, "size mismatch"
for i in range(parts):
    os.remove(os.path.join(tmp, f"{i:03d}"))
os.rmdir(tmp)
print("OK", out)
