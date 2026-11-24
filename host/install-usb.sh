#!/bin/bash
# Run once as root: the udev rule that lets the VMs' QEMU (run as the desktop's user) open ST's
# USB devices for passthrough. A copy of the file is in host/etc/udev/.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
install -m 644 "$here/etc/udev/rules.d/70-vmlab-stm32.rules" /etc/udev/rules.d/70-vmlab-stm32.rules
udevadm control --reload
udevadm trigger --subsystem-match=usb --attr-match=idVendor=0483 --action=change
echo "installed /etc/udev/rules.d/70-vmlab-stm32.rules"
