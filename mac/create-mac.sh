#!/usr/bin/env bash
# Define the macOS (Sequoia) libvirt domain from OSX-KVM's template, adapted for vmlab.
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system
K=/vmlab/tools/OSX-KVM
IMG=/vmlab/images/macos-base.qcow2
[ -f "$IMG" ] || qemu-img create -q -f qcow2 -o cluster_size=2M,lazy_refcounts=on "$IMG" 128G
cp -n "$K/OVMF_VARS-1920x1080.fd" /vmlab/nvram/macos_VARS.fd
cp -n "$K/OpenCore/OpenCore.qcow2" /vmlab/images/macos-opencore.qcow2

cat > /vmlab/tools/vmlab/mac/macos.xml <<XML
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>macos</name>
  <title>macOS Sequoia (vmlab)</title>
  <memory unit='GiB'>8</memory>
  <vcpu placement='static'>4</vcpu>
  <cpu mode='custom'><topology sockets='1' dies='1' cores='4' threads='1'/></cpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>$K/OVMF_CODE_4M.fd</loader>
    <nvram>/vmlab/nvram/macos_VARS.fd</nvram>
  </os>
  <features><acpi/><apic/></features>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/><timer name='pit' tickpolicy='delay'/><timer name='hpet' present='no'/>
  </clock>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='/vmlab/images/macos-opencore.qcow2'/>
      <target dev='sda' bus='sata'/><boot order='1'/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' discard='unmap'/>
      <source file='$IMG'/>
      <target dev='sdb' bus='sata'/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='writeback'/>
      <source file='/vmlab/iso/BaseSystem.img'/>
      <target dev='sdc' bus='sata'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='vmxnet3'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
    </interface>
    <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <video><model type='vmvga' vram='65536' heads='1' primary='yes'/></video>
    <controller type='usb' model='qemu-xhci'><address type='pci' domain='0x0000' bus='0x00' slot='0x06' function='0x0'/></controller>
    <input type='keyboard' bus='usb'/>
    <input type='tablet' bus='usb'/>
    <memballoon model='none'/>
  </devices>
  <qemu:commandline>
    <qemu:arg value='-device'/><qemu:arg value='isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'/>
    <qemu:arg value='-smbios'/><qemu:arg value='type=2'/>
    <qemu:arg value='-cpu'/><qemu:arg value='Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'/>
  </qemu:commandline>
</domain>
XML
virsh define /vmlab/tools/vmlab/mac/macos.xml
