# vmlab: the host's shared folder in the Windows guest, at C:\share. Run over SSH as dev, then
# `vm commit win`. Idempotent.
# The host side is QEMU's private Samba server at \\10.0.2.4\qemu (win-venus.sh, SHARE), which
# takes everyone as a guest and cannot sign. Windows 11 refuses both by default, in the desktop
# session ("your computer is configured to require SMB signing"; an SSH session got through
# without), so the SMB client here is told to accept them. The VM reaches no other SMB server
# through this: the network is QEMU's NAT.
$ErrorActionPreference = 'Stop'
Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -RequireSecuritySignature $false -Confirm:$false
# A plain path, for SSH sessions and the desktop alike
if (-not (Test-Path C:\share)) { cmd /c mklink /D C:\share \\10.0.2.4\qemu | Out-Null }
Get-SmbClientConfiguration | Format-List EnableInsecureGuestLogons, RequireSecuritySignature
