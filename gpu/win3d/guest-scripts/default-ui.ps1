# default-ui.ps1: Windows' own visual effects for dev: animations, fades, shadows, transparency
# (the user's wish, 2026-11-12). win11-base carries the "best performance" set from the time
# the VM had no GPU; this puts back what a new Windows 11 account has. Run over SSH as dev;
# Windows reads these at sign-in, so restart it afterwards. Prints name=value a line.
$ErrorActionPreference = 'Stop'
$desktop = 'HKCU:\Control Panel\Desktop'
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$fx = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
# "Let Windows choose" (no value), and the bits behind its check boxes as Windows 11 ships them
Remove-ItemProperty $fx VisualFXSetting -ErrorAction SilentlyContinue
Set-ItemProperty $desktop UserPreferencesMask ([byte[]](0x9E,0x1E,0x07,0x80,0x12,0x00,0x00,0x00)) -Type Binary
Set-ItemProperty $desktop DragFullWindows '1'
Set-ItemProperty "$desktop\WindowMetrics" MinAnimate '1'
Set-ItemProperty $adv TaskbarAnimations 1 -Type DWord
Set-ItemProperty $adv ListviewAlphaSelect 1 -Type DWord
Set-ItemProperty $adv ListviewShadow 1 -Type DWord
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' EnableTransparency 1 -Type DWord
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' EnableAeroPeek -ErrorAction SilentlyContinue
"mask=" + (((Get-ItemProperty $desktop).UserPreferencesMask | ForEach-Object { $_.ToString('x2') }) -join ' ')
"minanimate=" + (Get-ItemProperty "$desktop\WindowMetrics").MinAnimate
"transparency=" + (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').EnableTransparency
