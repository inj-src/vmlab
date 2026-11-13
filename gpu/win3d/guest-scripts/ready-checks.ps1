# ready-checks.ps1: what setup-ready.sh checks before it makes a disk the ready state, one
# name=value a line. Run over SSH (elevated).
$gpu = Get-CimInstance Win32_VideoController | Where-Object Name -like '*VirtIO GPU 3D*'
"gpu=" + $gpu.Status
# HWCursor of the device that is there now: Windows keeps one set of driver settings for each
# PCI slot the GPU has ever been in, and a moved GPU starts again from the driver's default, 0
$driver = (Get-PnpDevice -Class Display -PresentOnly | Where-Object FriendlyName -like '*VirtIO GPU 3D*' |
    Get-PnpDeviceProperty -KeyName DEVPKEY_Device_Driver).Data
"hwcursor=" + (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$driver" -ErrorAction SilentlyContinue).HWCursor
"umd=" + (Get-FileHash "$env:WINDIR\System32\viogpu_d3d10.dll" -Algorithm SHA256).Hash.ToLower()
"kmd=" + (Get-FileHash ((Get-CimInstance Win32_SystemDriver | Where-Object Name -eq VioGpu3D).PathName) -Algorithm SHA256).Hash.ToLower()
# d3d12: the package's bridge is unsigned (NotSigned); d3d12chromium: Microsoft's, which the lab's
# Direct3D driver loads first in a Chromium GPU process (d3d12-mode.ps1)
"d3d12=" + (Get-AuthenticodeSignature "$env:WINDIR\System32\d3d12.dll").Status
"d3d12chromium=" + (("System32", "SysWOW64" | ForEach-Object {
    $f = "$env:WINDIR\$_\vmlab-win3d\native\d3d12.dll"
    if (Test-Path $f) { (Get-AuthenticodeSignature $f).Status } else { 'Missing' } }) -join ',')
"lockout=" + ((net accounts | Select-String 'Lockout threshold').ToString() -replace '.*:\s*', '')
$windows = "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'"
"licence=" + ((Get-CimInstance SoftwareLicensingProduct -Filter $windows | ForEach-Object LicenseStatus) -join ',')
