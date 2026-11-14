# retire-edge.ps1: take Microsoft Edge out of the way without uninstalling it, keep WebView2.
# Run over `ssh win-pwsh` with PowerShell 7:  pwsh -NoProfile -File C:\vmlab\retire-edge.ps1
# Why not uninstall: Edge's setup.exe only uninstalls in the EEA, and switching DeviceRegion to
# Ireland (even with a reboot) still returns 532 "Stable is not uninstallable for process"; the
# region seems fixed at first setup. Removing it anyway needs unofficial hacks that Windows repairs.
# So: no shortcuts, no updater, no startup boost or background mode, and Chrome is the default
# browser (set in Settings), so nothing an agent does opens Edge by accident.
$ErrorActionPreference = 'Stop'
function Set-Dword($path, $name, $value) {
  if (-not (Test-Path $path)) { New-Item $path -Force | Out-Null }
  Set-ItemProperty $path $name $value -Type DWord }

$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Set-Dword $edge StartupBoostEnabled 0
Set-Dword $edge BackgroundModeEnabled 0
Set-Dword $edge HideFirstRunExperience 1
Set-Dword $edge DefaultBrowserSettingEnabled 0

# Edge Update: no Edge installs or updates. It also updates WebView2, which is fine to freeze in a
# test VM whose Windows Update is already off.
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 0
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' UpdateDefault 0
Get-Service edgeupdate, edgeupdatem, MicrosoftEdgeElevationService -ErrorAction SilentlyContinue | ForEach-Object {
  Stop-Service $_.Name -Force -ErrorAction SilentlyContinue; Set-Service $_.Name -StartupType Disabled; "disabled $($_.Name)" }
Get-ScheduledTask -TaskName 'MicrosoftEdgeUpdate*' -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null

# Shortcuts (the taskbar pin is removed from the desktop session: right-click > Unpin)
Remove-Item "$env:PUBLIC\Desktop\Microsoft Edge.lnk", "$env:USERPROFILE\Desktop\Microsoft Edge.lnk",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" -ErrorAction SilentlyContinue
Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
'EDGE-RETIRED'
