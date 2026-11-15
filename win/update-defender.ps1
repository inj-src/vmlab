# update-defender.ps1 [-MaxAgeDays N]: Microsoft Defender's definitions brought up to date, for a
# run started with `vm start win [state] --defender` (vm runs this once SSH answers). Windows
# Update stays off in the lab, so they come as Microsoft's offline package, mpam-fe.exe (220 MB),
# kept in the build cache (C:\cache\defender), which reset, states and commit leave alone: it is
# downloaded again only once it is MaxAgeDays old (7). Its signature is checked every time.
# Run over SSH as dev (an administrator).
param([double]$MaxAgeDays = 7)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Defender's service starts with Windows (gpu/win3d/defender-on.sh set it so); its first start
# after the lab's image can take a minute
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Service WinDefend).Status -ne 'Running') {
  if ((Get-Date) -gt $deadline) { throw 'Defender (WinDefend) did not start: was the disk changed by defender-on.sh?' }
  Start-Sleep 2
}

$dir = if (Test-Path C:\cache) { 'C:\cache\defender' } else { 'C:\vmlab\defender' }
New-Item -ItemType Directory -Force $dir | Out-Null
$pkg = Join-Path $dir 'mpam-fe.exe'
if (-not (Test-Path $pkg) -or (Get-Item $pkg).LastWriteTime -lt (Get-Date).AddDays(-$MaxAgeDays)) {
  "downloading Defender's definitions (220 MB) to $dir"
  Invoke-WebRequest 'https://go.microsoft.com/fwlink/?LinkID=121721&arch=x64' -OutFile "$pkg.new"
  Move-Item -Force "$pkg.new" $pkg
}
$sig = Get-AuthenticodeSignature $pkg
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
  Remove-Item $pkg
  throw "mpam-fe.exe is not signed by Microsoft ($($sig.Status), $($sig.SignerCertificate.Subject)): deleted"
}
$p = Start-Process $pkg -ArgumentList '-q' -Wait -PassThru
if ($p.ExitCode) { throw "mpam-fe.exe -q failed: $($p.ExitCode)" }

$s = Get-MpComputerStatus
'Defender on: definitions {0} of {1:yyyy-MM-dd}, real-time protection {2}, tamper protection {3}' -f `
  $s.AntivirusSignatureVersion, $s.AntivirusSignatureLastUpdated, $s.RealTimeProtectionEnabled, $s.IsTamperProtected
