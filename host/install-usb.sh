#!/bin/bash
# Run as root (again after a rule changes): the udev rules in host/etc/udev/rules.d that let the
# VMs' QEMU (run as the desktop's user) open USB devices for passthrough: ST's (70-vmlab-stm32),
# Arduino boards and USB-serial chips (71-vmlab-arduino).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
for r in "$here"/etc/udev/rules.d/7?-vmlab-*.rules; do
  install -m 644 "$r" "/etc/udev/rules.d/$(basename "$r")"
  echo "installed /etc/udev/rules.d/$(basename "$r")"
done
udevadm control --reload
udevadm trigger --subsystem-match=usb --action=change
