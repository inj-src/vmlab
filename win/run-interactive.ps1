# Run a command in the logged-on user's desktop session (not SSH's Session 0) and wait for it.
# Usage (over SSH):  powershell -File C:\vmlab\run-interactive.ps1 -Command "notepad.exe" [-NoWait]
# Output of the command goes to C:\vmlab\interactive\<id>.log; exit code is returned.
# No window shows for the command's PowerShell: it is started under "conhost.exe --headless",
# a console with no window at all (powershell.exe's own -WindowStyle Hidden opens its console
# window and hides it a moment later, which shows as a flash on the desktop). Windows the
# command itself opens (notepad.exe) show as usual.
param([Parameter(Mandatory)][string]$Command, [switch]$NoWait, [int]$TimeoutSec = 3600)
$ErrorActionPreference = 'Stop'
$dir = 'C:\vmlab\interactive'; New-Item -ItemType Directory -Force $dir | Out-Null
$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$log = "$dir\$id.log"; $rc = "$dir\$id.rc"; $script = "$dir\$id.ps1"
@"
`$ErrorActionPreference = 'Continue'
try { & { $Command } *>&1 | Out-File -FilePath '$log' -Encoding utf8; `$code = if (`$LASTEXITCODE) { `$LASTEXITCODE } else { 0 } }
catch { `$_ | Out-File -Append '$log'; `$code = 1 }
`$code | Out-File -FilePath '$rc' -Encoding ascii
$(if ($NoWait) { "Unregister-ScheduledTask -TaskName 'vmlab-$id' -Confirm:`$false -ErrorAction SilentlyContinue" })
"@ | Set-Content -Path $script -Encoding utf8
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $user) { throw 'No interactive user is logged on' }
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName "vmlab-$id" -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "vmlab-$id"
if ($NoWait) { Write-Output "started vmlab-$id (log: $log)"; exit 0 }
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not (Test-Path $rc) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
Unregister-ScheduledTask -TaskName "vmlab-$id" -Confirm:$false
if (Test-Path $log) { Get-Content $log }
if (-not (Test-Path $rc)) { Write-Error "timed out after $TimeoutSec s"; exit 124 }
exit [int](Get-Content $rc)
