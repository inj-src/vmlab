#!/usr/bin/env python3
"""disk.py DIR: uncached disk speed in DIR. Sequential 1 GiB write (flushed) and read in MB/s, random 4 KiB reads and writes a second."""
import fcntl, mmap, os, random, sys, time
path = os.path.join(sys.argv[1], 'disk-bench.tmp'); MB = 1 << 20; SIZE = 1024 * MB
flags = os.O_RDWR | os.O_CREAT | (os.O_DIRECT if sys.platform == 'linux' else 0)
fd = os.open(path, flags, 0o600)
if sys.platform == 'darwin': fcntl.fcntl(fd, 48, 1)          # F_NOCACHE
def flush(): fcntl.fcntl(fd, 51) if sys.platform == 'darwin' else os.fsync(fd)   # F_FULLFSYNC
big = mmap.mmap(-1, MB); big.write(os.urandom(MB)); small = mmap.mmap(-1, 4096); small.write(os.urandom(4096))
t = time.time()
for i in range(SIZE // MB): os.pwrite(fd, big, i * MB)
flush(); w = SIZE / MB / (time.time() - t)
t = time.time()
for i in range(SIZE // MB): os.preadv(fd, [big], i * MB)
r = SIZE / MB / (time.time() - t)
def rand(op):
    n = 0; t = time.time()
    while time.time() - t < 4:
        off = random.randrange(SIZE // 4096) * 4096
        os.preadv(fd, [small], off) if op == 'r' else os.pwrite(fd, small, off); n += 1
    if op == 'w': flush()
    return n / (time.time() - t)
rr = rand('r'); rw = rand('w')
os.close(fd); os.unlink(path)
print(f'seq write {w:.0f} MB/s  seq read {r:.0f} MB/s  random 4K read {rr:.0f}/s  random 4K write {rw:.0f}/s')
