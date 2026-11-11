# vmlab Windows dev tools. Run in the interactive session via run-interactive.ps1 (winget needs it).
$ErrorActionPreference = 'Continue'
$pkgs = @(
  'Git.Git',
  'Microsoft.PowerShell',
  'OpenJS.NodeJS.LTS',
  'Python.Python.3.12',
  'astral-sh.uv',
  '7zip.7zip',
  'Microsoft.VisualStudioCode'
)
foreach ($p in $pkgs) {
  Write-Output "=== $p"
  winget install --id $p -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --scope machine
  if ($LASTEXITCODE -ne 0) { winget install --id $p -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity }
}
# pnpm via corepack (ships with Node)
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
corepack enable 2>&1
# Make PowerShell 7 the SSH default shell once it exists
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (Test-Path $pwsh) { New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $pwsh -PropertyType String -Force | Out-Null }
Write-Output '=== versions'
git --version; node --version; npm --version; python --version; uv --version
