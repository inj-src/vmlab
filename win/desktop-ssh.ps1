# desktop-ssh.ps1: SSH into the Windows VM lands on dev's desktop. Run once, from the host:
#   /vmlab/tools/vmlab/win/install-desktop-ssh.sh    (copies this and vmshell\ to C:\vmlab,
#                                                     runs it and restarts the VM)
# After it, `ssh win "<command>"` runs in Git Bash, `ssh win-pwsh "<command>"` in PowerShell 7,
# both in the logged-on desktop session (windows show, the GPU is there, winget works) as dev
# with admin rights, and programs a command starts keep running after the connection ends.
#
# - sshd runs in the desktop: a task started at dev's logon, with the highest rights. It is the
#   same sshd.exe with the same sshd_config and host keys as the service, so nothing changes for
#   the client. An sshd that is not SYSTEM can log in only its own user, which is all the lab
#   uses. The sshd service is disabled (both would want port 22); until dev is logged on, which
#   auto-login does seconds after boot, SSH does not answer.
# - DefaultShell is vmshell.exe (see vmshell\src\main.rs): Git Bash, or pwsh for a session that
#   sets VMLAB_SHELL=pwsh (sshd accepts that one variable), outside sshd's job object.
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
#    (an SSH command's output is one; error messages came with escape codes). These go first,
#    before the fnm lines that add to Path. (An older version of this script also set Path here;
#    vmshell does that now, and the filter below removes the line.)
$profileFile = Join-Path $PSHOME 'profile.ps1'
$lines = @(
    '# vmlab: UTF-8 for output to pipes and terminals (SSH sessions too) and to native programs',
    '[Console]::OutputEncoding = [Console]::InputEncoding = $OutputEncoding = [Text.UTF8Encoding]::new($false)',
    '# vmlab: plain text when the output goes to a pipe',
    'if ([Console]::IsOutputRedirected) { $PSStyle.OutputRendering = ''PlainText'' }'
)
$old = if (Test-Path $profileFile) { Get-Content $profileFile | Where-Object { $_ -notmatch '^# vmlab: |^\[Console\]::OutputEncoding = |^if \(\[Console\]::IsOutputRedirected\) \{ \$PSStyle|^if \(\$env:SSH_CONNECTION\) \{ \$env:Path = ' } } else { @() }
Set-Content -Path $profileFile -Value ($lines + @($old)) -Encoding utf8

# 2b. Every Git Bash reads the lab's bash-env.sh: a command from sshd reads ~/.bashrc (bash's
#     rule for a shell sshd starts), a terminal ~/.bash_profile, which reads ~/.bashrc, and the
#     rest BASH_ENV, which vmshell sets. LF line ends: bash takes a CR for part of the command.
$bashrc = Join-Path $env:USERPROFILE '.bashrc'
$keep = if (Test-Path $bashrc) { @(Get-Content $bashrc | Where-Object { $_ -notmatch '^# vmlab: |/c/vmlab/bash-env\.sh' }) } else { @() }
$text = @('# vmlab: the lab''s bash setup (C:\vmlab\bash-env.sh)', '[ -f /c/vmlab/bash-env.sh ] && . /c/vmlab/bash-env.sh') + $keep
[IO.File]::WriteAllText($bashrc, (($text -join "`n") + "`n"))
$bashProfile = Join-Path $env:USERPROFILE '.bash_profile'
$keep = if (Test-Path $bashProfile) { @(Get-Content $bashProfile | Where-Object { $_ -notmatch '^# vmlab: |/c/vmlab/bash-env\.sh' }) } else { @() }
if (-not ($keep -match '\.bashrc')) { $keep = @('[ -f ~/.bashrc ] && . ~/.bashrc') + $keep }
[IO.File]::WriteAllText($bashProfile, (($keep -join "`n") + "`n"))

# 3. sshd passes VMLAB_SHELL on to vmshell (AcceptEnv is global, so before the first Match)
$cfg = 'C:\ProgramData\ssh\sshd_config'
$text = Get-Content $cfg
if (-not ($text -match '^AcceptEnv VMLAB_SHELL$')) {
    $first = @($text | Select-String -Pattern '^Match ' | Select-Object -First 1)
    $at = if ($first) { $first[0].LineNumber - 1 } else { $text.Count }
    $text = @($text | Select-Object -First $at) + 'AcceptEnv VMLAB_SHELL' + @($text | Select-Object -Skip $at)
    Set-Content $cfg $text -Encoding ascii
}
& $sshd -t -f $cfg
if ($LASTEXITCODE) { throw "sshd rejects $cfg" }

# 4. sshd in the desktop session, from dev's logon on. The loop starts it again if it ends;
#    conhost --headless gives it a console without a window.
$loop = "while (`$true) { & '$sshd' -f C:\ProgramData\ssh\sshd_config; Start-Sleep -Seconds 2 }"
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless pwsh.exe -NoProfile -NonInteractive -Command `"$loop`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\dev"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\dev" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName vmlab-sshd -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

# 5. The service gives up port 22 from the next boot (stopping it now would end this session).
Set-Service sshd -StartupType Disabled
"desktop SSH is set up; it takes over at the next boot"
