# vm-run.ps1: the guest's half of `vm run win`. The host sends this file and the script with
# every run (nothing to install in the guest), then starts it over SSH with PowerShell 7:
#   pwsh -NoProfile -File .vmrun-ID.helper.ps1 -Script C:\Users\dev\.vmrun-ID.ps1 -TimeoutSec N
# It runs the script in the logged-on user's desktop session (SSH itself is in Session 0, where
# windows are invisible and there is no GPU), as that user with admin rights, through a one-off
# scheduled task. The script's output comes back as it is written, byte for byte (UTF-8), and
# the exit code is the script's: its `exit N`, 1 after an error that ended it, else 0; 124 when
# it ran out of time (the script and its child processes are killed). Every file of a run,
# this one too, is removed at the end.
param([Parameter(Mandatory)][string]$Script, [int]$TimeoutSec = 3600)
$ErrorActionPreference = 'Stop'
$log = "$Script.log"; $rc = "$Script.rc"; $pidFile = "$Script.pid"; $wrap = "$Script.wrap.ps1"
$task = 'vmrun-' + [IO.Path]::GetFileNameWithoutExtension($Script).Replace('.vmrun-', '')
$q = { param($t) $t -replace "'", "''" }

# What the task runs. No window shows: "conhost --headless" is a console without one. The script
# is its own pwsh process with stdout and stderr tied to the log file, so what it and its programs
# write arrives whole, whichever stream or API they use; code page 65001 makes that UTF-8, and
# NO_COLOR keeps PowerShell's colour codes out of it. It loads the profile, as `vm ssh` does
# (fnm's environment comes from there).
@"
`$PID | Set-Content -Path '$(& $q $pidFile)'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false)
`$env:NO_COLOR = '1'
Set-Location `$HOME
cmd /d /c "pwsh -ExecutionPolicy Bypass -File $Script > $log 2>&1 < NUL"
`$LASTEXITCODE | Set-Content -Path '$(& $q $rc)'
"@ | Set-Content -Path $wrap -Encoding utf8

$code = 1
try {
    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $user) { throw 'vm run: nobody is logged on to the Windows desktop yet (wait a few seconds after vm start)' }
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrap`""
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $task

    # Pass the log on as it grows, as bytes, so no code page touches it.
    $stdout = [Console]::OpenStandardOutput(); $buf = [byte[]]::new(65536); $in = $null
    $pump = {
        if (-not $in -and (Test-Path $log)) { $script:in = [IO.FileStream]::new($log, 'Open', 'Read', 'ReadWrite, Delete') }
        if ($in) { while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $stdout.Write($buf, 0, $n) }; $stdout.Flush() }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path $rc) -and (Get-Date) -lt $deadline) { & $pump; Start-Sleep -Milliseconds 200 }
    if (Test-Path $rc) { & $pump; $code = [int](Get-Content $rc) }
    else {
        if (Test-Path $pidFile) { taskkill /T /F /PID (Get-Content $pidFile) *> $null }
        Start-Sleep -Milliseconds 300; & $pump
        [Console]::Error.WriteLine("vm run: stopped after $TimeoutSec s"); $code = 124
    }
}
catch { [Console]::Error.WriteLine($_.Exception.Message); $code = 1 }
finally {
    if ($in) { $in.Dispose() }
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Script, $wrap, $log, $rc, $pidFile, $PSCommandPath -Force -ErrorAction SilentlyContinue
}
exit $code
