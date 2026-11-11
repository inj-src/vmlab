# ready-checks.ps1: what setup-ready.sh checks before it makes a disk the ready state, one
# name=value a line. Run over SSH (elevated).
$gpu = Get-CimInstance Win32_VideoController | Where-Object Name -like '*VirtIO GPU 3D*'
"gpu=" + $gpu.Status
$class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
"hwcursor=" + (Get-ChildItem $class -ErrorAction SilentlyContinue |
    ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).HWCursor } |
    Where-Object { $_ -eq 1 } | Select-Object -First 1)
"umd=" + (Get-FileHash "$env:WINDIR\System32\viogpu_d3d10.dll" -Algorithm SHA256).Hash.ToLower()
"kmd=" + (Get-FileHash ((Get-CimInstance Win32_SystemDriver | Where-Object Name -eq VioGpu3D).PathName) -Algorithm SHA256).Hash.ToLower()
"d3d12=" + (Get-AuthenticodeSignature "$env:WINDIR\System32\d3d12.dll").Status
"lockout=" + ((net accounts | Select-String 'Lockout threshold').ToString() -replace '.*:\s*', '')
$windows = "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'"
"licence=" + ((Get-CimInstance SoftwareLicensingProduct -Filter $windows | ForEach-Object LicenseStatus) -join ',')
