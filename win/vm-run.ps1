# vm-run.ps1: the guest's half of `vm run win` and `vm execute win`. The host sends this file and
# the script with every run (nothing to install in the guest), then starts it over SSH:
#   pwsh -NoProfile -File .vmrun-ID.helper.ps1 -Script C:\Users\dev\.vmrun-ID.ps1 -TimeoutSec N
# It runs the script in the logged-on user's desktop session (SSH itself is in Session 0, where
# windows are invisible and there is no GPU), as that user with admin rights, through a one-off
# scheduled task. The script's output comes back as it is written, byte for byte (UTF-8), and
# the exit code is the script's: its `exit N`, else the exit code of the last program it ran, 1
# after an error that ended it, else 0; 124 when it ran out of time (the script and its child
# processes are killed). Every file of a run, this one too, is removed at the end.
param([Parameter(Mandatory)][string]$Script, [int]$TimeoutSec = 3600)
$ErrorActionPreference = 'Stop'
$log = "$Script.log"; $rc = "$Script.rc"; $cmd = "$Script.cmd"
$task = 'vmrun-' + [IO.Path]::GetFileNameWithoutExtension($Script).Replace('.vmrun-', '')

# What the task runs: cmd ties the script's stdout and stderr to the log file at the process
# level, so what it and its programs write arrives whole, whichever stream or API they use.
# Code page 65001 makes that UTF-8; NO_COLOR keeps PowerShell's colour codes out. pwsh loads the
# profile, as an SSH shell does (fnm's environment comes from there). The exit code goes to a
# file that appears only once it is complete; the redirection stands first because cmd reads
# "echo 7> f" as a redirection of handle 7.
@"
@echo off
chcp 65001 >nul
set NO_COLOR=1
cd /d "%USERPROFILE%"
pwsh -ExecutionPolicy Bypass -Command "& '$Script'; if (`$null -ne `$LASTEXITCODE) { exit `$LASTEXITCODE }" > "$log" 2>&1 < NUL
>"$rc.tmp" echo %errorlevel%
move /y "$rc.tmp" "$rc" >nul
"@ | Set-Content -Path $cmd -Encoding ascii

$code = 1; $in = $null
try {
    # schtasks.exe, not the ScheduledTasks cmdlets: the same task in a tenth of the time.
    # /it: in the session of the user who is logged on; /rl highest: with admin rights.
    # "conhost --headless" is a console without a window, so nothing flashes on the desktop.
    $tr = "conhost.exe --headless cmd.exe /d /c `"$cmd`""
    $out = schtasks /create /tn $task /tr $tr /sc once /st 23:59 /it /rl highest /f 2>&1
    if ($LASTEXITCODE) { throw "vm run: could not create the task: $out" }
    $out = schtasks /run /tn $task 2>&1
    if ($LASTEXITCODE) {
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { throw 'vm run: nobody is logged on to the Windows desktop yet (wait a few seconds after vm start)' }
        throw "vm run: could not start the task: $out"
    }

    # Pass the log on as it grows, as bytes, so no code page touches it.
    $stdout = [Console]::OpenStandardOutput(); $buf = [byte[]]::new(65536)
    $pump = {
        if (-not $in -and (Test-Path $log)) { $script:in = [IO.FileStream]::new($log, 'Open', 'Read', 'ReadWrite, Delete') }
        if ($in) { while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $stdout.Write($buf, 0, $n) }; $stdout.Flush() }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path $rc) -and (Get-Date) -lt $deadline) { & $pump; Start-Sleep -Milliseconds 50 }
    if (Test-Path $rc) { & $pump; $code = [int](Get-Content $rc) }
    else {
        # the task's processes are the ones whose command line names its .cmd file (the SSH
        # session's own command line names the script, not that)
        $id = [IO.Path]::GetFileName($cmd)
        Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$id*" } |
            ForEach-Object { taskkill /T /F /PID $_.ProcessId *> $null }
        Start-Sleep -Milliseconds 300; & $pump
        [Console]::Error.WriteLine("vm run: stopped after $TimeoutSec s"); $code = 124
    }
}
catch { [Console]::Error.WriteLine($_.Exception.Message); $code = 1 }
finally {
    if ($in) { $in.Dispose() }
    schtasks /delete /tn $task /f *> $null
    Remove-Item -LiteralPath $Script, $cmd, $log, $rc, "$rc.tmp", $PSCommandPath -Force -ErrorAction SilentlyContinue
}
exit $code
