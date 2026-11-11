disable-defender-update.reg is applied OFFLINE (VM shut off) with
  sudo virt-win-reg --merge /vmlab/images/win11-base.qcow2 disable-defender-update.reg
so Tamper Protection cannot block it. Defender service list matches cschneegans/unattend-generator.
Note: the regedit parser needs a blank line between keys and no comments.
Add-WindowsCapability needs wuauserv; re-enable it temporarily (Start=3) if you need a capability.
