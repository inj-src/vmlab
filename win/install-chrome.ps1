# install-chrome.ps1: Google Chrome for the test VM, with no sign-in, sync, promos or update churn.
# Run over `vm ssh win` with Windows PowerShell (needs admin, works from SSH's session):
#   powershell -NoProfile -File C:\vmlab\install-chrome.ps1
# Afterwards, from the desktop: launch Chrome once to clear anything first-run left, then make it
# the default browser in Settings > Apps > Default apps > Google Chrome > Set default (Windows
# protects that choice with a hash, so only the Settings UI can set it).
$ErrorActionPreference = 'Stop'
$msi = 'C:\vmlab\chrome.msi'
curl.exe -fsSL -o $msi 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
$p = Start-Process msiexec.exe -ArgumentList '/i', $msi, '/qn', '/norestart' -Wait -PassThru
"msiexec exit code: $($p.ExitCode)"
if ($p.ExitCode -notin 0, 3010) { exit 1 }
Remove-Item $msi

# Policies (the same set as mac's profile, plus no background mode so tests start from no Chrome)
$pol = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
if (-not (Test-Path $pol)) { New-Item $pol -Force | Out-Null }
@{ BrowserSignin = 0; SyncDisabled = 1; DefaultBrowserSettingEnabled = 0; PromotionsEnabled = 0
   PasswordManagerEnabled = 0; MetricsReportingEnabled = 0; PrivacySandboxPromptEnabled = 0
   BackgroundModeEnabled = 0 }.GetEnumerator() | ForEach-Object { Set-ItemProperty $pol $_.Key $_.Value -Type DWord }

# First-run defaults for new profiles
$app = "$env:ProgramFiles\Google\Chrome\Application"
@'
{
  "distribution": {
    "skip_first_run_ui": true,
    "suppress_first_run_default_browser_prompt": true,
    "suppress_first_run_bubble": true,
    "import_bookmarks": false, "import_history": false, "import_home_page": false,
    "import_saved_passwords": false, "import_search_engine": false,
    "make_chrome_default": false, "make_chrome_default_for_user": false,
    "do_not_create_desktop_shortcut": true, "do_not_create_quick_launch_shortcut": true
  },
  "browser": { "check_default_browser": false }
}
'@ | Set-Content "$app\initial_preferences" -Encoding ascii

# Freeze the version: Google Update policies only apply on domain-joined PCs, so switch off
# the updater's services and scheduled tasks instead.
Get-Service GoogleUpdater*, gupdate, gupdatem -ErrorAction SilentlyContinue | ForEach-Object {
  Stop-Service $_.Name -Force -ErrorAction SilentlyContinue; Set-Service $_.Name -StartupType Disabled }
Get-ScheduledTask -TaskName 'GoogleUpdater*', 'GoogleUpdateTask*' -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
Remove-Item "$env:PUBLIC\Desktop\Google Chrome.lnk" -ErrorAction SilentlyContinue

"chrome: $((Get-Item "$app\chrome.exe").VersionInfo.ProductVersion)"
'CHROME-OK'
