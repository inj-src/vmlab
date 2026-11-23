#!/bin/bash
# Run once as root: compressed swap in memory (zram, zstd) ahead of /swap.img, and /vmlab
# trimmed by fstrim.timer instead of on every delete. Copies of the files are in host/etc/.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }

DEBIAN_FRONTEND=noninteractive apt-get install -y -q systemd-zram-generator </dev/null
install -m 644 "$here/etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
install -m 644 "$here/etc/sysctl.d/91-vmlab-zram.conf" /etc/sysctl.d/91-vmlab-zram.conf
sysctl -q -p /etc/sysctl.d/91-vmlab-zram.conf
systemctl daemon-reload
systemctl restart systemd-zram-setup@zram0.service

# /vmlab: no online discard (each delete or qcow2 unmap waits for the SSD); the weekly
# fstrim.timer trims instead
if grep -q '^LABEL=vmlab .*discard' /etc/fstab; then
  cp -a /etc/fstab /var/backups/vmlab/fstab.before-nodiscard 2>/dev/null || { mkdir -p /var/backups/vmlab; cp -a /etc/fstab /var/backups/vmlab/fstab.before-nodiscard; }
  sed -i 's|^\(LABEL=vmlab /vmlab xfs defaults,nofail\),discard |\1 |' /etc/fstab
  mount -o remount,nodiscard /vmlab
fi
systemctl enable --now fstrim.timer >/dev/null
swapon --show
findmnt -no OPTIONS /vmlab
