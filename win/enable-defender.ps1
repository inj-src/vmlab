# enable-defender.ps1: Microsoft Defender Antivirus back on, as on a customer's PC. For the saved
# state `defender` only (vm start win defender): the clean state keeps it off, where it would
# scan every file a build writes. Run over SSH as dev, then restart Windows.
#
# The lab switched it off by disabling its services (win/disable-defender-update.reg, written
# into the image before the first boot). These are Windows 11's own start types. While the
# services are off nothing guards their keys, so an administrator can write them; once Defender
# runs, its tamper protection refuses the way back, and the state is left by `vm reset win`.
# Windows Update stays off, so the definitions come as Microsoft's offline package, after the
# restart (README-defender.txt has the steps; MpCmdRun -SignatureUpdate -MMPC failed here with
# 0x80070652).
$ErrorActionPreference = 'Stop'
$start = [ordered]@{ WdBoot = 0; WdFilter = 0; WdNisDrv = 3; WdNisSvc = 3; WinDefend = 2; Sense = 3 }
foreach ($s in $start.Keys) {
  Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -Name Start -Value $start[$s] -Type DWord
  "{0}={1}" -f $s, (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$s").Start
}
