disable-defender-update.reg is applied OFFLINE (VM shut off) with
  sudo virt-win-reg --merge /vmlab/images/win11-base.qcow2 disable-defender-update.reg
so Tamper Protection cannot block it. Defender service list matches cschneegans/unattend-generator.
Note: the regedit parser needs a blank line between keys and no comments.
Add-WindowsCapability needs wuauserv; re-enable it temporarily (Start=3) if you need a capability.

The saved state `defender` (vm start win defender) has Defender on again. `vm commit win
--drop-states` and a new ready state delete it; to build it again (10 minutes, 1.5 GB):
  vm reset win; vm start win
  copy enable-defender.ps1 to C:\vmlab and run it with pwsh over SSH, then restart Windows
  in the guest, download https://go.microsoft.com/fwlink/?LinkID=121721&arch=x64 as mpam-fe.exe
    (220 MB), check Get-AuthenticodeSignature says Valid and Microsoft, run: mpam-fe.exe -q
  Get-MpComputerStatus: RealTimeProtectionEnabled and IsTamperProtected are True
  vm stop win; vm save win defender "note with the definitions' date"
Checked on 2026-11-12: the EICAR test file was removed on write, and an unsigned exe with the
Mark-of-the-Web started through Explorer gave "Windows protected your PC". That second box is
SmartScreen, which the lab never turned off: the clean state shows it too.
