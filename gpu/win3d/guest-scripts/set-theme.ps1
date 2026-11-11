# set-theme.ps1: make "Windows (light)" the theme (aero.theme, with apps and Windows itself in
# light mode). Run it in the desktop session (run-interactive.ps1); setup-ready.sh does.
# Opening a .theme file is how Windows applies one; it opens Settings to do it, which is closed
# again here. Prints "theme ... already" or "theme A -> B". Exit 2: the theme did not apply.
$ErrorActionPreference = 'Stop'
$want = 'C:\Windows\Resources\Themes\aero.theme'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'

function Get-Now {
    $p = Get-ItemProperty "$key\Personalize" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Theme = (Get-ItemProperty $key).CurrentTheme
        Light = ($p -and $p.AppsUseLightTheme -eq 1 -and $p.SystemUsesLightTheme -eq 1)
    }
}

$was = Get-Now
if ($was.Theme -eq $want -and $was.Light) { "theme $want already"; exit 0 }
Start-Process $want
foreach ($i in 1..30) {
    Start-Sleep -Milliseconds 500
    $now = Get-Now
    if ($now.Theme -eq $want -and $now.Light) { break }
}
Start-Sleep -Seconds 2
Get-Process SystemSettings -ErrorAction SilentlyContinue | Stop-Process -Force
$now = Get-Now
if ($now.Theme -ne $want -or -not $now.Light) { "theme still $($now.Theme), light: $($now.Light)"; exit 2 }
"theme $($was.Theme) -> $want"
