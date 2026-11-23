#!/usr/bin/env python3
"""pin.py [--one-each] QMP_SOCKET VCPU_CPUS [OTHER_CPUS]: put a running QEMU's threads on chosen host CPUs.

VCPU_CPUS   host CPUs for the guest's CPUs, e.g. 0-5. With as many CPUs as the guest has, guest
            CPU n gets the n-th one to itself; otherwise every guest CPU may use the whole set.
OTHER_CPUS  host CPUs for every other thread of QEMU and of its child processes (the GPU
            translation threads, the Venus render server, I/O). Left alone when not given.
--one-each  one host CPU to each guest CPU, in the guest's topology order (socket, core,
            thread). It refuses unless each guest core lands on a host core of its own: with
            -smp 6,cores=3,threads=2 and 0-5, guest core n gets host CPUs 2n and 2n+1 (one
            fast core, both its threads). Without --one-each, as before.

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


def host_core(cpu):
    """(package, core) of a host CPU, from sysfs: two CPUs with the same are threads of one core."""
    t = f'/sys/devices/system/cpu/cpu{cpu}/topology'
    return tuple(int(open(f'{t}/{n}').read()) for n in ('physical_package_id', 'core_id'))


def one_each(vcpus, want):
    """vcpus: query-cpus-fast entries. Returns [(tid, host cpu)] or exits with the reason."""
    if len(want) != len(vcpus):
        sys.exit(f'pin: --one-each: {len(vcpus)} guest CPUs and {len(want)} host CPUs')
    order = sorted(vcpus, key=lambda c: tuple(c.get('props', {}).get(k, 0) for k in ('socket-id', 'die-id', 'core-id', 'thread-id')) + (c['cpu-index'],))
    pairs = [(c['thread-id'], cpu) for c, cpu in zip(order, want)]
    # guest CPUs of one core must land on host CPUs of one core, and different guest cores on
    # different host cores
    guest_core = {c['thread-id']: tuple(c.get('props', {}).get(k, 0) for k in ('socket-id', 'die-id', 'core-id')) for c in vcpus}
    seen = {}
    for tid, cpu in pairs:
        seen.setdefault(guest_core[tid], set()).add(host_core(cpu))
    if any(len(h) != 1 for h in seen.values()) or len({next(iter(h)) for h in seen.values()}) != len(seen):
        sys.exit(f'pin: --one-each: host CPUs {",".join(map(str, want))} do not match the guest\'s cores and threads')
    return pairs


def main():
    args = sys.argv[1:]
    strict = bool(args) and args[0] == '--one-each'
    if strict:
        args = args[1:]
    if len(args) not in (2, 3):
        sys.exit(__doc__)
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(args[0])
    pid = struct.unpack('3i', s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
    f = s.makefile('rw'); f.readline()

    def qmp(cmd):
        f.write(json.dumps({'execute': cmd}) + '\n'); f.flush()
        while True:
            r = json.loads(f.readline())
            if 'return' in r: return r['return']
            if 'error' in r: sys.exit(f'pin: {cmd}: {r["error"]["desc"]}')
    qmp('qmp_capabilities')
    vcpus = qmp('query-cpus-fast')
    s.close()
    vcpu_tids = [c['thread-id'] for c in sorted(vcpus, key=lambda c: c['cpu-index'])]

    want = cpus(args[1])
    if strict:
        pairs = one_each(vcpus, want)
        for tid, cpu in pairs:
            os.sched_setaffinity(tid, {cpu})
        print(f'pin: {len(pairs)} guest CPUs on host CPUs {args[1]}, one each by core and thread')
    else:
        for n, tid in enumerate(vcpu_tids):
            os.sched_setaffinity(tid, {want[n]} if len(want) == len(vcpu_tids) else set(want))
        print(f'pin: {len(vcpu_tids)} guest CPUs on host CPUs {args[1]}'
              + (', one each' if len(want) == len(vcpu_tids) else ', shared'))
    if len(args) == 3:
        others, pids, count = set(cpus(args[2])), [pid], 0
        for p in pids:                                    # QEMU, then its children, breadth first
            for task in os.listdir(f'/proc/{p}/task'):
                if int(task) not in vcpu_tids:
                    try: os.sched_setaffinity(int(task), others); count += 1
                    except ProcessLookupError: pass
                try: pids += map(int, open(f'/proc/{p}/task/{task}/children').read().split())
                except FileNotFoundError: pass
        print(f'pin: {count} other threads in {len(pids)} processes on host CPUs {args[2]}')


main()
