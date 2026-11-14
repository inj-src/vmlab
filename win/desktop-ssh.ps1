# desktop-ssh.ps1: SSH into the Windows VM lands on dev's desktop. Run once, from the host:
#   /vmlab/tools/vmlab/win/install-desktop-ssh.sh    (copies this and vmshell\ to C:\vmlab,
#                                                     runs it and restarts the VM)
# After it, `ssh win "<command>"` runs in the logged-on desktop session (windows show, the GPU
# is there, winget works) as dev with admin rights, and programs a command starts keep running
# after the connection ends.
#
# - sshd runs in the desktop: a task started at dev's logon, with the highest rights. It is the
#   same sshd.exe with the same sshd_config and host keys as the service, so nothing changes for
#   the client. An sshd that is not SYSTEM can log in only its own user, which is all the lab
#   uses. The sshd service is disabled (both would want port 22); until dev is logged on, which
#   auto-login does seconds after boot, SSH does not answer.
# - DefaultShell is vmshell.exe (see vmshell\src\main.rs): pwsh, outside sshd's job object.
# - pwsh writes UTF-8 to pipes and the terminal (the system's profile), so non-ASCII output
#   arrives whole over SSH.
$ErrorActionPreference = 'Stop'
$src = 'C:\vmlab\vmshell'
$sshd = 'C:\Program Files\OpenSSH\sshd.exe'

# 1. vmshell, built here from its source
$target = Join-Path $env:TEMP 'vmshell-target'
cargo build --release --quiet --manifest-path "$src\Cargo.toml" --target-dir $target
if ($LASTEXITCODE) { throw "vmshell did not build" }
# A running exe cannot be overwritten, but it can be renamed (this very session runs in one).
$exe = 'C:\vmlab\vmshell.exe'
Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
if (Test-Path $exe) { Rename-Item $exe "$exe.old" }
Copy-Item "$target\release\vmshell.exe" $exe
Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $target
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value C:\vmlab\vmshell.exe -PropertyType String -Force | Out-Null

# 2. Every pwsh (AllUsersAllHosts profile): UTF-8, and no colour codes in output to a pipe
#    (an SSH command's output is one; error messages came with escape codes). An SSH session
#    takes Path from the registry, as a new terminal window does: sshd's own environment is the
#    one of dev's logon, so a tool installed later (winget, rustup) would be missing until a
#    restart. These go first, before the fnm lines that add to Path.
$profileFile = Join-Path $PSHOME 'profile.ps1'
$lines = @(
    '# vmlab: an SSH session takes Path from the registry, as a new terminal window does',
    'if ($env:SSH_CONNECTION) { $env:Path = (([Environment]::GetEnvironmentVariable(''Path'', ''Machine''), [Environment]::GetEnvironmentVariable(''Path'', ''User'')) -split '';'' | Where-Object { $_ } | Select-Object -Unique) -join '';'' }',
    '# vmlab: UTF-8 for output to pipes and terminals (SSH sessions too) and to native programs',
    '[Console]::OutputEncoding = [Console]::InputEncoding = $OutputEncoding = [Text.UTF8Encoding]::new($false)',
    '# vmlab: plain text when the output goes to a pipe',
    'if ([Console]::IsOutputRedirected) { $PSStyle.OutputRendering = ''PlainText'' }'
)
$old = if (Test-Path $profileFile) { Get-Content $profileFile | Where-Object { $_ -notmatch '^# vmlab: |^\[Console\]::OutputEncoding = |^if \(\[Console\]::IsOutputRedirected\) \{ \$PSStyle|^if \(\$env:SSH_CONNECTION\) \{ \$env:Path = ' } } else { @() }
Set-Content -Path $profileFile -Value ($lines + @($old)) -Encoding utf8

# 3. sshd in the desktop session, from dev's logon on. The loop starts it again if it ends;
#    conhost --headless gives it a console without a window.
$loop = "while (`$true) { & '$sshd' -f C:\ProgramData\ssh\sshd_config; Start-Sleep -Seconds 2 }"
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless pwsh.exe -NoProfile -NonInteractive -Command `"$loop`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\dev"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\dev" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName vmlab-sshd -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

# 4. The service gives up port 22 from the next boot (stopping it now would end this session).
Set-Service sshd -StartupType Disabled
"desktop SSH is set up; it takes over at the next boot"
