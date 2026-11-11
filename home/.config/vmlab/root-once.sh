#!/bin/bash
# root-once.sh: the one root step of the vmlab GPU work. Run as root through `sudo -A`.
#   1. Removes the 23:00-03:00 time rule (pam_time), keeping backups in /var/backups/vmlab.
#   2. Installs the build packages for reims-vgpu and for a Venus-capable QEMU.
# Safe to run again: each step skips what is already done.
set -u
[[ $EUID == 0 ]] || { echo "run as root"; exit 2; }
rc=0
bak=/var/backups/vmlab; mkdir -p "$bak"; stamp=$(date +%Y%m%d-%H%M%S)

# remove_line FILE ERE: delete the single line matching ERE, and undo unless that is the only change
remove_line() {
  local f=$1 re=$2 n
  n=$(grep -cE "$re" "$f")
  if [[ $n == 0 ]]; then echo "pam: $f already clean"; return 0; fi
  if [[ $n != 1 ]]; then echo "pam: $f has $n matching lines, expected 1; left alone"; return 1; fi
  cp -a "$f" "$bak/$(basename "$f").$stamp"
  sed -i -E "/$re/d" "$f"
  if [[ $(diff "$bak/$(basename "$f").$stamp" "$f" | grep -c '^[<>]') == 1 ]]; then
    echo "pam: removed the rule from $f (backup $bak/$(basename "$f").$stamp)"
  else
    cp -a "$bak/$(basename "$f").$stamp" "$f"; echo "pam: unexpected change to $f, restored"; return 1
  fi
}
remove_line /etc/pam.d/common-auth '^account[[:space:]]+required[[:space:]]+pam_time\.so[[:space:]]*$' || rc=1
remove_line /etc/security/time.conf '^\*;\*;\*;!Al2300-0300[[:space:]]*$' || rc=1

# Build packages. The -dev headers must match the installed libraries, so apt also brings
# Mesa and GLib to the current Ubuntu point release.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
pkgs=(ninja-build flex bison cmake clang lld libglib2.0-dev libpixman-1-dev libslirp-dev libfdt-dev
  libpipewire-0.3-dev libpulse-dev libasound2-dev libx11-dev libxext-dev libxrandr-dev libxcursor-dev
  libxi-dev libxfixes-dev libxss-dev libxtst-dev libxkbcommon-dev libwayland-dev libwayland-bin
  libdecor-0-dev libegl-dev libgl-dev libdrm-dev libgbm-dev libgtk-3-dev
  meson libvulkan-dev libsdl2-dev libepoxy-dev liburing-dev libaio-dev libspice-server-dev
  libspice-protocol-dev libva-dev libcap-ng-dev libseccomp-dev)
apt-get update -q || echo "apt: update failed, trying the install with the lists already here"
if apt-get install -y -q -o Dpkg::Options::=--force-confold "${pkgs[@]}"; then echo "apt: packages installed"
else echo "apt: install FAILED"; rc=1; fi

# reims-vgpu on NVIDIA maps guest memory a 4 KiB page at a time; below about 2.2 million maps an
# 8 GiB guest's buffers are copied instead, which is slower (its installer asks for this).
if (( $(cat /proc/sys/vm/max_map_count) < 4194304 )); then
  echo 'vm.max_map_count = 4194304' > /etc/sysctl.d/90-vmlab-reims.conf
  sysctl -q -p /etc/sysctl.d/90-vmlab-reims.conf && echo "sysctl: vm.max_map_count=4194304" || rc=1
fi

echo "ROOT-ONCE exit=$rc"
exit $rc
