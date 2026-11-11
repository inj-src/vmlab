# debloat.ps1: conservative cleanup of the Windows test VM. Run over `vm ssh win` with Windows
# PowerShell (Appx cmdlets are most reliable there):  powershell -NoProfile -File C:\vmlab\debloat.ps1
# Removes consumer apps nobody tests against, quiets suggestions and telemetry, and leaves the
# platform alone: Store, Notepad, Calculator, Paint, Terminal, Photos, Snipping Tool, Windows Search,
# .NET, VC++ runtimes and WebView2 all stay. Reboot afterwards.
$ErrorActionPreference = 'Continue'

# 1. Apps: remove for every user, and deprovision so new profiles don't get them back
$apps = @(
  'Microsoft.Copilot', 'Microsoft.OutlookForWindows', 'MSTeams', 'Clipchamp.Clipchamp',
  'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxSpeechToTextOverlay',
  'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.BingNews', 'Microsoft.BingWeather',
  'Microsoft.BingSearch', 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.WindowsFeedbackHub',
  'Microsoft.WindowsMaps', 'Microsoft.YourPhone', 'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos',
  'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.549981C3F5F10',
  'Microsoft.Windows.DevHome', 'Microsoft.StartExperiencesApp', 'Microsoft.Edge.GameAssist',
  'MicrosoftWindows.Client.WebExperience'   # Widgets board and its taskbar button
)
foreach ($a in $apps) {
  Get-AppxPackage -AllUsers -Name $a | ForEach-Object {
    try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; "removed $a" }
    catch { "FAILED $a : $($_.Exception.Message)" } }
  Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $a |
    ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null; "deprovisioned $a" }
}

# 2. OneDrive (Win32): uninstall and stop it coming back for new users
Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($s in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
  if (Test-Path $s) { Start-Process $s '/uninstall' -Wait; 'onedrive uninstalled' } }
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue |
  ForEach-Object { Start-Process $_.FullName '/uninstall' -Wait }
reg load HKU\Default C:\Users\Default\NTUSER.DAT | Out-Null
reg delete 'HKU\Default\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' /v OneDriveSetup /f 2>$null | Out-Null
[gc]::Collect(); reg unload HKU\Default | Out-Null

# 2b. Copilot desktop app: an Edge-based Win32 install, separate from the Microsoft.Copilot package.
# Its setup.exe insists on a parent under %windir% compared case-sensitively (SSH sets C:\WINDOWS).
$cp = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
  Where-Object DisplayName -eq 'Copilot'
if ($cp) {
  $env:windir = $env:SystemRoot = 'C:\Windows'
  Get-Process | Where-Object Path -match 'Microsoft\\Copilot' | Stop-Process -Force
  $p = Start-Process "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', "`"$($cp.UninstallString) --force-uninstall`"" -Wait -PassThru
  "copilot desktop uninstall exit code: $($p.ExitCode) (19 = success)" }

function Set-Dword($path, $name, $value) {
  if (-not (Test-Path $path)) { New-Item $path -Force | Out-Null }
  Set-ItemProperty $path $name $value -Type DWord }

# 3. Taskbar and Start: no Widgets, Copilot or Task View buttons; no recommendations or Bing
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-Dword 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1
Set-Dword $adv ShowCopilotButton 0
Set-Dword $adv ShowTaskViewButton 0
Set-Dword $adv Start_IrisRecommendations 0
Set-Dword $adv Start_AccountNotifications 0
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' HideRecommendedPersonalizedSites 1
Set-Dword 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' DisableSearchBoxSuggestions 1

# 4. Suggestions, tips, "finish setting up" nags, silent app installs
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($n in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
               'PreInstalledAppsEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled',
               'SystemPaneSuggestionsEnabled', 'SubscribedContentEnabled', 'SubscribedContent-310093Enabled',
               'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
               'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
               'SubscribedContent-353696Enabled', 'SubscribedContent-353698Enabled') { Set-Dword $cdm $n 0 }
Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' ScoobeSystemSettingEnabled 0
Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' Enabled 0
$cc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
Set-Dword $cc DisableWindowsConsumerFeatures 1
Set-Dword $cc DisableSoftLanding 1
Set-Dword $cc DisableConsumerAccountStateContent 1

# 5. Telemetry and services that do nothing useful in a test VM
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' AllowTelemetry 0
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' DoNotShowFeedbackNotifications 1
foreach ($svc in 'DiagTrack', 'dmwappushservice', 'MapsBroker', 'RetailDemo',
                 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc') {
  if (Get-Service $svc -ErrorAction SilentlyContinue) {
    Stop-Service $svc -Force -ErrorAction SilentlyContinue
    Set-Service $svc -StartupType Disabled; "disabled service $svc" } }
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -ErrorAction SilentlyContinue |
  Disable-ScheduledTask | Out-Null
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser' -ErrorAction SilentlyContinue | Out-Null

'DEBLOAT-OK (reboot to apply)'
