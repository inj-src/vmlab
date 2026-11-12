# Run a command in the logged-on user's desktop session (not SSH's Session 0).
# Usage (over SSH; from pwsh 7 put `Remove-Item Env:PSModulePath;` first):
#   powershell -File C:\vmlab\run-interactive.ps1 -Command "<PowerShell>" [-TimeoutSec N] [-NoWait]
#       waits for it and gives back its output and its exit code. -NoWait: returns at once; the
#       output goes to the log file it names.
#   powershell -File C:\vmlab\run-interactive.ps1 -Start "<command line>" [-Log FILE] [-Dir DIR]
#       starts a program that stays (a GUI app, a server) and returns at once with its log file
#       and a process id. The program's stdout and stderr are the log FILE itself, not a pipe,
#       so nothing breaks when this helper is gone (Electron's main process dies with EPIPE on
#       a pipe whose reader has left). `taskkill /T /F /PID <id>` stops it and what it started.
# Output of the command goes to C:\vmlab\interactive\<id>.log.
# No window shows for the command's PowerShell: it is started under "conhost.exe --headless",
# a console with no window at all (powershell.exe's own -WindowStyle Hidden opens its console
# window and hides it a moment later, which shows as a flash on the desktop). Windows the
# command itself opens (notepad.exe) show as usual.
[CmdletBinding(DefaultParameterSetName = 'Command')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Command')][string]$Command,
    [Parameter(ParameterSetName = 'Command')][switch]$NoWait,
    [Parameter(Mandatory, ParameterSetName = 'Start')][string]$Start,
    [Parameter(ParameterSetName = 'Start')][string]$Log,
    [Parameter(ParameterSetName = 'Start')][string]$Dir = 'C:\Users\dev',
    [int]$TimeoutSec = 3600)
$ErrorActionPreference = 'Stop'
# (PowerShell's names ignore case: $work and $out, not $dir and $log, beside -Dir and -Log)
$work = 'C:\vmlab\interactive'; New-Item -ItemType Directory -Force $work | Out-Null
$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$out = "$work\$id.log"; $rc = "$work\$id.rc"; $script = "$work\$id.ps1"
if ($Start) {
    # cmd.exe, in a hidden console of its own, holds the redirection: `program > log 2>&1`
    if (-not $Log) { $Log = "$work\$id.app.log" }
    $q = { param($t) $t -replace "'", "''" }
    $Command = "`$p = Start-Process `$env:ComSpec -WindowStyle Hidden -PassThru -WorkingDirectory '$(& $q $Dir)' -ArgumentList '/d /s /c `"$(& $q $Start) > `"$(& $q $Log)`" 2>&1`"'; `"started: pid `$(`$p.Id), log $(& $q $Log)`""
    $TimeoutSec = 60
}
@"
`$ErrorActionPreference = 'Continue'
try { & { $Command } *>&1 | Out-File -FilePath '$out' -Encoding utf8; `$code = if (`$LASTEXITCODE) { `$LASTEXITCODE } else { 0 } }
catch { `$_ | Out-File -Append '$out'; `$code = 1 }
`$code | Out-File -FilePath '$rc' -Encoding ascii
$(if ($NoWait) { "Unregister-ScheduledTask -TaskName 'vmlab-$id' -Confirm:`$false -ErrorAction SilentlyContinue" })
"@ | Set-Content -Path $script -Encoding utf8
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $user) { throw 'No interactive user is logged on' }
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName "vmlab-$id" -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "vmlab-$id"
if ($NoWait) { Write-Output "started vmlab-$id (log: $out)"; exit 0 }
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not (Test-Path $rc) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
Unregister-ScheduledTask -TaskName "vmlab-$id" -Confirm:$false
if (Test-Path $out) { Get-Content $out }
if (-not (Test-Path $rc)) { Write-Error "timed out after $TimeoutSec s"; exit 124 }
exit [int](Get-Content $rc)
