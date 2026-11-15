#!/usr/bin/python3 -I
"""qcow2-sizes.py DISK BASE: how much room each internal snapshot of a qcow2 disk takes, the
Mac's named states (reims/mac26.sh state list). qemu-img tells no snapshot's size.

Prints a line a snapshot, NAME TAB BYTES: for BASE (the default state, `clean`) every data
cluster it uses; for each other snapshot the clusters it uses that BASE does not, so the size
means what a Windows state's file means (win3d/win-venus.sh: the changes since the default
state). Clusters two named states share count for both. Reads only the snapshot table and
the snapshots' L1 and L2 tables, so it is safe while the VM runs (snapshots change only while
it is shut down).
"""
import struct
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: qcow2-sizes.py DISK BASE')
    with open(sys.argv[1], 'rb') as f:
        h = f.read(104)
        if h[:4] != b'QFI\xfb':
            sys.exit('not a qcow2 file')
        version, = struct.unpack('>I', h[4:8])
        cluster_bits, = struct.unpack('>I', h[20:24])
        nb_snapshots, snapshots_offset = struct.unpack('>IQ', h[60:72])
        extended = version >= 3 and struct.unpack('>Q', h[72:80])[0] & (1 << 4)
        entry = 16 if extended else 8          # an L2 entry; extended L2 adds a bitmap after it
        size = 1 << cluster_bits
        offset_mask = ((1 << 56) - 1) & ~(size - 1)
        compressed_bits = 62 - (cluster_bits - 8)

        def clusters(l1_offset, l1_size):
            """The host clusters a snapshot's data is in."""
            found = set()
            f.seek(l1_offset)
            for l1 in struct.unpack(f'>{l1_size}Q', f.read(8 * l1_size)):
                l2_offset = l1 & offset_mask
                if not l2_offset:
                    continue
                f.seek(l2_offset)
                table = f.read(size)
                for i in range(0, size, entry):
                    e, = struct.unpack_from('>Q', table, i)
                    if e & (1 << 62):          # compressed: its bytes start at this offset
                        host = (e & ((1 << compressed_bits) - 1)) >> cluster_bits
                    else:
                        host = (e & offset_mask) >> cluster_bits
                    if host:
                        found.add(host)
            return found

        # The snapshot table: each entry, then its extra data, name and id, padded to 8 bytes
        snaps, pos = {}, snapshots_offset
        for _ in range(nb_snapshots):
            f.seek(pos)
            e = f.read(40)
            l1_offset, l1_size, id_len, name_len = struct.unpack('>QIHH', e[:16])
            extra, = struct.unpack('>I', e[36:40])
            f.seek(pos + 40 + extra + id_len)
            name = f.read(name_len).decode()
            snaps[name] = (l1_offset, l1_size)
            pos += (40 + extra + id_len + name_len + 7) & ~7

        base = clusters(*snaps[sys.argv[2]]) if sys.argv[2] in snaps else set()
        for name, table in snaps.items():
            used = base if name == sys.argv[2] else clusters(*table) - base
            print(f'{name}\t{len(used) * size}')


if __name__ == '__main__':
    main()
