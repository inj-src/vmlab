#!/usr/bin/env python3
"""pin.py QMP_SOCKET VCPU_CPUS [OTHER_CPUS]: put a running QEMU's threads on chosen host CPUs.

VCPU_CPUS   host CPUs for the guest's CPUs, e.g. 0-5. With as many CPUs as the guest has, guest
            CPU n gets the n-th one to itself; otherwise every guest CPU may use the whole set.
OTHER_CPUS  host CPUs for every other thread of QEMU and of its child processes (the GPU
            translation threads, the Venus render server, I/O). Left alone when not given.

This laptop: CPUs 0-7 are the four fast cores (pairs 0/1 2/3 4/5 6/7), 8-11 the slow ones.
It prints what it did. No root needed: the threads are the user's own.
"""
import json, os, socket, struct, sys


def cpus(text):
    out = []
    for part in text.split(','):
        a, _, b = part.partition('-')
        out += range(int(a), int(b or a) + 1)
    return out


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
    pid = struct.unpack('3i', s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
    f = s.makefile('rw'); f.readline()

    def qmp(cmd):
        f.write(json.dumps({'execute': cmd}) + '\n'); f.flush()
        while True:
            r = json.loads(f.readline())
            if 'return' in r: return r['return']
            if 'error' in r: sys.exit(f'pin: {cmd}: {r["error"]["desc"]}')
    qmp('qmp_capabilities')
    vcpu_tids = [c['thread-id'] for c in sorted(qmp('query-cpus-fast'), key=lambda c: c['cpu-index'])]
    s.close()

    want = cpus(sys.argv[2])
    for n, tid in enumerate(vcpu_tids):
        os.sched_setaffinity(tid, {want[n]} if len(want) == len(vcpu_tids) else set(want))
    print(f'pin: {len(vcpu_tids)} guest CPUs on host CPUs {sys.argv[2]}'
          + (', one each' if len(want) == len(vcpu_tids) else ', shared'))
    if len(sys.argv) == 4:
        others, pids, count = set(cpus(sys.argv[3])), [pid], 0
        for p in pids:                                    # QEMU, then its children, breadth first
            for task in os.listdir(f'/proc/{p}/task'):
                if int(task) not in vcpu_tids:
                    try: os.sched_setaffinity(int(task), others); count += 1
                    except ProcessLookupError: pass
                try: pids += map(int, open(f'/proc/{p}/task/{task}/children').read().split())
                except FileNotFoundError: pass
        print(f'pin: {count} other threads in {len(pids)} processes on host CPUs {sys.argv[3]}')


main()
