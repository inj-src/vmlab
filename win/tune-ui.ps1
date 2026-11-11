# tune-ui.ps1: lighter desktop rendering for a GPU-less VM. Run over SSH as dev; takes effect at next logon.
# Turns off animations, fades, shadows and transparency (the "best performance" set) but keeps
# ClearType, because blurry text makes screenshots harder for computer-use models to read.
$ErrorActionPreference = 'Stop'
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' VisualFXSetting 3 -Type DWord  # 3 = custom
Set-ItemProperty 'HKCU:\Control Panel\Desktop' UserPreferencesMask ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary
Set-ItemProperty 'HKCU:\Control Panel\Desktop' FontSmoothing '2'
Set-ItemProperty 'HKCU:\Control Panel\Desktop' FontSmoothingType 2 -Type DWord
Set-ItemProperty 'HKCU:\Control Panel\Desktop' DragFullWindows '0'
Set-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' MinAnimate '0'
Set-ItemProperty $adv TaskbarAnimations 0 -Type DWord
Set-ItemProperty $adv ListviewAlphaSelect 0 -Type DWord
Set-ItemProperty $adv ListviewShadow 0 -Type DWord
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' EnableTransparency 0 -Type DWord
if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\DWM')) { New-Item 'HKCU:\Software\Microsoft\Windows\DWM' -Force | Out-Null }
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' EnableAeroPeek 0 -Type DWord
'UI tuned (sign out or reboot to apply)'
