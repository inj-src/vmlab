# quiet-helpers.ps1: nothing the lab runs in the desktop session shows a console window.
# setup-ready.sh runs it over SSH (after copying the lab's run-interactive.ps1 in).
#   - Cua Driver's logon task (cua-driver-serve) starts cua-driver.exe serve itself, under
#     "conhost.exe --headless". Cua's installer has the task run powershell.exe to Start-Process
#     it: that flashes a console at every logon (without conhost), and Windows PowerShell's start
#     put 1.5 s of the boot before Cua (measured 2026-11-23)
#   - the helper's left-over tasks and logs from earlier runs go
# Prints "helpers=quiet" when the task is as wanted.
$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName cua-driver-serve -ErrorAction SilentlyContinue
if ($task) {
    $a = $task.Actions[0]
    if ($a.Arguments -match "-FilePath '([^']+)' -ArgumentList '([^']+)'(?: .*-WorkingDirectory '([^']+)')?") {
        $dir = if ($Matches[3]) { $Matches[3] } else { $env:USERPROFILE }
        $new = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless `"$($Matches[1])`" $($Matches[2])" -WorkingDirectory $dir
        Set-ScheduledTask -TaskName cua-driver-serve -Action $new | Out-Null
    } elseif ($a.Execute -notmatch 'conhost') {
        $new = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless $($a.Execute) $($a.Arguments)"
        Set-ScheduledTask -TaskName cua-driver-serve -Action $new | Out-Null
    }
}
Get-ScheduledTask | Where-Object { $_.TaskName -match '^vmlab-[0-9a-f]{8}$' -and $_.State -ne 'Running' } |
    Unregister-ScheduledTask -Confirm:$false
Get-ChildItem C:\vmlab\interactive -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-5) } | Remove-Item -Force
$now = (Get-ScheduledTask -TaskName cua-driver-serve -ErrorAction SilentlyContinue).Actions[0]
if (-not $task -or $now.Execute -match 'conhost') { 'helpers=quiet' } else { 'helpers=windowed' }
