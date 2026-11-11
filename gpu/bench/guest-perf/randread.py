# randread.py FILE: uncached 4 KiB random reads for 5 s, one thread then four; prints reads a second
import os, sys, time, random, fcntl, threading
path = sys.argv[1]; size = os.path.getsize(path)
def run(seconds, out):
    fd = os.open(path, os.O_RDONLY); fcntl.fcntl(fd, 48, 1)   # F_NOCACHE
    n = 0; end = time.time() + seconds
    while time.time() < end:
        os.pread(fd, 4096, random.randrange(0, size - 4096) & ~4095); n += 1
    out.append(n); os.close(fd)
for threads in (1, 4):
    out = []; ts = [threading.Thread(target=run, args=(5, out)) for _ in range(threads)]
    [t.start() for t in ts]; [t.join() for t in ts]
    print(f"{threads} thread(s): {sum(out) / 5:.0f} reads/s, {5e6 * threads / sum(out):.0f} us each")
