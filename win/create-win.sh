#!/usr/bin/env bash
# Create the win11 libvirt domain and start the unattended install into the base image.
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system
IMG=/vmlab/images/win11-base.qcow2
[ -f "$IMG" ] || qemu-img create -q -f qcow2 -o cluster_size=2M,lazy_refcounts=on "$IMG" 150G

virt-install --name win11 --osinfo win11 \
  --memory 8192 --vcpus 6,sockets=1,cores=6,threads=1 --cpu host-passthrough \
  --boot uefi --tpm default \
  --disk path="$IMG",format=qcow2,bus=virtio,cache=none,discard=unmap,boot.order=2 \
  --disk /vmlab/iso/win11.iso,device=cdrom,bus=sata,boot.order=1 \
  --disk /vmlab/iso/virtio-win.iso,device=cdrom,bus=sata \
  --disk /vmlab/iso/win-config.iso,device=cdrom,bus=sata \
  --network network=default,model=virtio \
  --graphics spice,listen=none --video virtio \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --import --noautoconsole

# Windows ISOs on UEFI wait for "Press any key to boot from CD"; press it for them.
for _ in $(seq 25); do virsh send-key win11 KEY_ENTER >/dev/null 2>&1 || true; sleep 1; done
echo "win11 install started"
