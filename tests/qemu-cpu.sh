#!/usr/bin/env bash
# qemu-cpu.sh [secs]: average CPU of the macos QEMU process over <secs> (default 60), in % of one
# host core, from utime+stime in /proc/<pid>/stat. Same method the lab uses for idle numbers.
set -euo pipefail
secs=${1:-60}
pid=$(pgrep -f '^/usr/bin/qemu-system-x86_64 -name guest=macos' | head -1)
[[ -n $pid ]] || { echo "macos qemu not running" >&2; exit 1; }
hz=$(getconf CLK_TCK)
t(){ awk '{print $14+$15}' "/proc/$pid/stat"; }
a=$(t); sleep "$secs"; b=$(t)
awk -v a="$a" -v b="$b" -v hz="$hz" -v s="$secs" 'BEGIN{printf "%.1f\n", (b-a)/hz/s*100}'
