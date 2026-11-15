disable-defender-update.reg is applied OFFLINE (VM shut off) with
  sudo virt-win-reg --merge /vmlab/images/win11-base.qcow2 disable-defender-update.reg
so Tamper Protection cannot block it. Defender service list matches cschneegans/unattend-generator.
Note: the regedit parser needs a blank line between keys and no comments.
Add-WindowsCapability needs wuauserv; re-enable it temporarily (Start=3) if you need a capability.
(The same can be done without sudo the way gpu/win3d/defender-on.sh writes the hive.)

Defender on for one run, from any state:
  vm start win [state] --defender
gpu/win3d/defender-on.sh turns its services on in the stopped disk (Windows 11's start types,
the same as enable-defender.ps1 sets from inside), then vm runs update-defender.ps1 in the
guest: the definitions from Microsoft's offline package
  https://go.microsoft.com/fwlink/?LinkID=121721&arch=x64  (mpam-fe.exe, 220 MB)
kept in C:\cache\defender, downloaded again at a week old, its signature checked (Valid,
Microsoft Corporation), installed with mpam-fe.exe -q. It prints the definitions' version and
that real-time and tamper protection are on.
Checked on 2026-11-16: the whole start took 95 s, the first download included (5 s for the
definitions step with the package cached); Defender found the EICAR test file on write
(Virus:DOS/EICAR_Test_File) and refused every read of it.
Checked on 2026-11-12 with the old `defender` state (deleted 2026-11-16, the flag replaced it):
the EICAR test file was removed on write,
and an unsigned exe with the Mark-of-the-Web started through Explorer gave "Windows protected
your PC". That second box is SmartScreen, which the lab never turned off: the default state
shows it too.
