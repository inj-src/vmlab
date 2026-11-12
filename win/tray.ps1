# tray.ps1 <program>: keep a program's tray icon beside the clock, where a test can see and
# click it. <program> is part of its path or file name (pebble, myapp.exe). Run over SSH as dev,
# after the program has shown its icon once: Windows 11 puts every new icon under the "Show
# Hidden Icons" arrow and has no setting for "show all"; it keeps one entry per program under
# HKCU\Control Panel\NotifyIconSettings, made when the icon first appears, and IsPromoted=1
# there is the switch that Settings > Personalization > Taskbar > Other system tray icons sets.
# Prints each entry it promoted; exit code 1 when Windows has none for the program yet.
param([Parameter(Mandatory)][string]$Program)
$found = Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue |
    Where-Object { (Get-ItemProperty $_.PSPath).ExecutablePath -like "*$Program*" }
if (-not $found) { "no tray icon of a program like '$Program' yet: start it, wait for its icon, run this again"; exit 1 }
foreach ($key in $found) {
    Set-ItemProperty $key.PSPath IsPromoted 1 -Type DWord
    "beside the clock: " + (Get-ItemProperty $key.PSPath).ExecutablePath
}
