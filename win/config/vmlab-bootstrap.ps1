# vmlab first-logon bootstrap. Runs once from the config CD via FirstLogonCommands.
# Goal: make the VM reachable over SSH. Everything else is installed later over SSH.
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force C:\vmlab | Out-Null
Start-Transcript -Path C:\vmlab\bootstrap.log -Append

$cfg = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1. VirtIO guest tools: guest agent, balloon, serial and network drivers.
foreach ($l in 'DEFGH'.ToCharArray()) {
  $exe = "${l}:\virtio-win-guest-tools.exe"
  if (Test-Path $exe) { Write-Host "Installing $exe"; Start-Process $exe -ArgumentList '/passive','/norestart' -Wait; break }
}

# 2. Power and lock: the VM must never sleep or lock, or GUI automation breaks.
powercfg /hibernate off
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization" /v NoLockScreen /t REG_DWORD /d 1 /f
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f
net accounts /maxpwage:unlimited

# 3. Auto-logon forever (unattend's AutoLogon is also set; this makes it permanent).
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $wl AutoAdminLogon '1'
Set-ItemProperty $wl DefaultUserName 'dev'
Set-ItemProperty $wl DefaultPassword 'vmlab'
Remove-ItemProperty $wl AutoLogonCount -ErrorAction SilentlyContinue

# 4. OpenSSH server. First logon can beat DHCP, so wait for the internet (up to 5 min).
for ($i = 0; $i -lt 60 -and -not (Test-NetConnection github.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue); $i++) { Start-Sleep 5 }
# Try the Windows capability first, then fall back to the GitHub MSI.
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue
if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name -ErrorAction SilentlyContinue }
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  Write-Host 'Capability install failed, using Win32-OpenSSH MSI'
  [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
  $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest'
  $msi = ($rel.assets | Where-Object name -like '*Win64*.msi' | Select-Object -First 1).browser_download_url
  Invoke-WebRequest $msi -OutFile C:\vmlab\openssh.msi
  Start-Process msiexec -ArgumentList '/i','C:\vmlab\openssh.msi','/qn' -Wait
}
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'vmlab-sshd' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'vmlab-sshd' -DisplayName 'vmlab OpenSSH' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
}

# Admin accounts read keys from administrators_authorized_keys, which needs strict ACLs.
$ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
Copy-Item (Join-Path $cfg 'authorized_keys') $ak -Force
icacls $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
Restart-Service sshd

# 5. Ping allowed so the host can see the VM is up.
netsh advfirewall firewall add rule name="vmlab-icmp" protocol=icmpv4:8,any dir=in action=allow | Out-Null

'done' | Out-File C:\vmlab\bootstrap.done
Stop-Transcript
