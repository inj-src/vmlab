# vsock-agent.ps1: the Windows end of the vsock control channel (../vsock). Run from the host:
#   /vmlab/tools/vmlab/win/install-vsock-agent.sh   (copies this, the driver, the source and the
#                                                    token to C:\vmlab and runs it)
# The VM must be running with vhost-vsock-pci (win-venus.sh adds it when QEMU has it).
#
# - viosock: virtio-win's socket driver and its Winsock provider (the VirtioSocketWSP service,
#   which the driver's INF installs), from the ISO's viosock\w11\amd64.
# - vmlab-agent.exe, built here from its source, as vmshell is.
# - C:\vmlab\agent-token: the host's ~/.config/vmlab/agent-token; only administrators and
#   SYSTEM read it.
# - The agent runs in dev's desktop session with the highest rights, from dev's logon on, as
#   sshd does (desktop-ssh.ps1): the commands it runs through vmshell are where `ssh win` runs
#   them. A loop starts it again if it ends.
$ErrorActionPreference = 'Stop'

# 1. The driver, for the device that is there now
pnputil /add-driver C:\vmlab\viosock\viosock.inf /install | Out-Host
# 0: installed; 3010: installed, a restart finishes it; 259: it was installed already
if ($LASTEXITCODE -notin 0, 259, 3010) { throw "pnputil failed ($LASTEXITCODE)" }
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.HardwareID -match 'VEN_1AF4&DEV_(1012|1053)' }
if (-not $dev) { throw 'no virtio socket device: start the VM with vhost-vsock-pci (win-venus.sh)' }
"device: $($dev.FriendlyName), $($dev.Status)"

# 2. The agent, built here from its source
$target = Join-Path $env:TEMP 'vsock-target'
cargo build --release --quiet --manifest-path C:\vmlab\vsock\Cargo.toml --bin vmlab-agent --target-dir $target
if ($LASTEXITCODE) { throw 'vmlab-agent did not build' }
# The running agent and its loop: Stop-ScheduledTask does not reach the loop (it runs under a
# headless conhost), which would start the old agent again.
Stop-ScheduledTask -TaskName vmlab-agent -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*agent-loop.cmd*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process vmlab-agent -ErrorAction SilentlyContinue | Stop-Process -Force
$exe = 'C:\vmlab\vmlab-agent.exe'
Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
if (Test-Path $exe) { Rename-Item $exe "$exe.old" }
Copy-Item "$target\release\vmlab-agent.exe" $exe
Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $target

# 3. The token: administrators and SYSTEM only (the agent runs elevated)
icacls C:\vmlab\agent-token /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE) { throw 'icacls failed on C:\vmlab\agent-token' }

# 4. The agent in the desktop session from dev's logon on. The loop is a batch file (cmd starts
#    in milliseconds), written beside and renamed over (cmd reads a running batch file by offset).
$loopFile = 'C:\vmlab\agent-loop.cmd'
Set-Content "$loopFile.new" -Encoding ascii -Value @(
    '@echo off', 'rem vmlab: vmlab-agent in the desktop session, started again if it ends (vsock-agent.ps1)',
    ':again', $exe, 'ping -n 3 127.0.0.1 >nul', 'goto again')
Move-Item -Force "$loopFile.new" $loopFile
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless cmd.exe /d /c $loopFile"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\dev"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\dev" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName vmlab-agent -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName vmlab-agent
"vmlab-agent is set up and running"
