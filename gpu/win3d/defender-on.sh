#!/usr/bin/env bash
# defender-on.sh DISK: Microsoft Defender Antivirus on in a Windows disk (qcow2) that is shut
# down, for `vm start win [state] --defender` (win-venus.sh start ... --defender). The lab turned
# it off by disabling its services (win/disable-defender-update.reg); this gives them back
# Windows 11's own start types, in the SYSTEM registry hive, before Windows boots. Done offline,
# tamper protection has no say, and any state can be started with Defender on.
#
# All in userspace, no sudo: qemu-storage-daemon shows Windows' partition as a file (a FUSE
# export, its own fusermount3), the NTFS tools read and write a file in it (ntfscat, ntfscp:
# they work on an image; ntfs-3g's mount would need root), and hivex edits the hive. ntfscp
# leaves alone a volume Windows did not shut down cleanly (hibernated, Fast Startup): then this
# fails and nothing is written. Prints what it did; the disk must not be in use.
set -euo pipefail
die(){ echo "defender-on: $*" >&2; exit 1; }
[[ $# == 1 && -f $1 ]] || die "usage: defender-on.sh DISK.qcow2"
disk=$(realpath "$1")
[[ $disk != *,* ]] || die "a path with a comma cannot be given to qemu-storage-daemon: $disk"
# Windows 11's start types: 0 boot, 2 automatic, 3 on demand
declare -A START=([WdBoot]=0 [WdFilter]=0 [WdNisDrv]=3 [WdNisSvc]=3 [WinDefend]=2 [Sense]=3)
HIVE=/Windows/System32/config/SYSTEM

t=$(mktemp -d /vmlab/tmp/defender-on.XXXXXX)
done_(){
  local pid
  if pid=$(cat "$t/qsd.pid" 2>/dev/null); then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  fi
  # the daemon can end with its export still mounted
  mountpoint -q "$t/part" 2>/dev/null && fusermount3 -u "$t/part"
  rm -rf "$t"
}
trap done_ EXIT

# Windows' partition: the largest "basic data" one in the GPT
qemu-img dd -f qcow2 -O raw if="$disk" of="$t/gpt" bs=512 count=34
read -r offset size < <(python3 -I - "$t/gpt" <<'PY'
import struct, sys, uuid
d = open(sys.argv[1], 'rb').read()
if d[512:520] != b'EFI PART':
    sys.exit('defender-on: no GPT on the disk')
start, count, esize = struct.unpack('<QII', d[584:600])
best = None
for i in range(count):
    e = d[start * 512 + i * esize:][:esize]
    if len(e) < 56 or uuid.UUID(bytes_le=e[:16]) != uuid.UUID('ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'):
        continue
    first, last = struct.unpack('<QQ', e[32:48])
    if best is None or last - first > best[1] - best[0]:
        best = (first, last)
if best is None:
    sys.exit('defender-on: no Windows partition on the disk')
print(best[0] * 512, (best[1] - best[0] + 1) * 512)
PY
)
: > "$t/part"
qemu-storage-daemon --daemonize --pidfile "$t/qsd.pid" \
  --blockdev driver=file,node-name=file,filename="$disk" \
  --blockdev driver=qcow2,node-name=disk,file=file \
  --blockdev driver=raw,node-name=part,file=disk,offset="$offset",size="$size" \
  --export type=fuse,id=part,node-name=part,mountpoint="$t/part",writable=on,allow-other=off

ntfscat "$t/part" "$HIVE" > "$t/SYSTEM" || die "no registry in the partition ($HIVE)"
cs=$(printf 'ControlSet%03d' "$(hivexget "$t/SYSTEM" '\Select' Current)")
reg="Windows Registry Editor Version 5.00"$'\n' changed=()
for s in "${!START[@]}"; do
  now=$(hivexget "$t/SYSTEM" "\\$cs\\Services\\$s" Start 2>/dev/null) || continue   # not in this edition
  [[ $now == "${START[$s]}" ]] && continue
  changed+=("$s $now→${START[$s]}")
  reg+=$'\n'"[HKEY_LOCAL_MACHINE\\SYSTEM\\$cs\\Services\\$s]"$'\n'"\"Start\"=dword:0000000${START[$s]}"$'\n'
done
if (( ! ${#changed[@]} )); then echo "Defender is on in the disk already"; exit 0; fi
printf '%s' "$reg" > "$t/on.reg"
cp "$t/SYSTEM" "$t/SYSTEM.new"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$t/SYSTEM.new" "$t/on.reg"
/usr/sbin/ntfscp -q "$t/part" "$t/SYSTEM.new" "$HIVE" || die "the registry was not written (Windows not shut down cleanly?); the disk is as it was"
ntfscat "$t/part" "$HIVE" | cmp -s - "$t/SYSTEM.new" || die "the registry read back differs from what was written"
echo "Defender on in the disk (start types ${changed[*]})"
