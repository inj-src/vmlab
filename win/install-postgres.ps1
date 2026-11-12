# install-postgres.ps1: PostgreSQL 16 in the ready state, set up as EDB's installer does it on
# a customer's PC (the user's choice, 2026-11-12, for testing an app's install, backup and
# rollback against a real server). Run in the desktop session, where winget works:
#   C:\vmlab\run-interactive.ps1 -TimeoutSec 1800 -Command 'C:\vmlab\install-postgres.ps1'
# 405 MB to download; about 5 minutes.
#   - service postgresql-x64-16, automatic start, port 5432, data in C:\Program Files\PostgreSQL\16\data
#   - superuser postgres, password postgres
#   - the server and the command line tools (psql, pg_dump, pg_restore in ...\16\bin); no
#     pgAdmin, no Stack Builder. The installer does not put bin on the Path, and the lab does not
#     either: a program under test has to find the tools the way it would on a customer's PC.
$ErrorActionPreference = 'Stop'
# winget names the installer and its hash, curl fetches it: winget's own download gets
# "403 Forbidden" from EDB's server (2026-11-12).
$show = winget show --id PostgreSQL.PostgreSQL.16 --exact --accept-source-agreements --disable-interactivity | Out-String
if ($show -notmatch 'Installer Url:\s*(\S+)') { throw "winget show gave no installer address: $show" }
$url = $Matches[1]
if ($show -notmatch 'Installer SHA256:\s*([0-9a-fA-F]{64})') { throw 'winget show gave no hash' }
$hash = $Matches[1]
$exe = Join-Path $env:TEMP 'postgresql-16-installer.exe'
curl.exe -sS -L --fail -o $exe $url
if ($LASTEXITCODE) { throw "the download failed: $url" }
if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $hash) { throw "the installer's hash is not winget's" }
$run = Start-Process $exe -Wait -PassThru -ArgumentList '--mode', 'unattended', '--unattendedmodeui', 'none',
    '--superpassword', 'postgres', '--serverport', '5432', '--disable-components', 'pgAdmin,stackbuilder'
Remove-Item $exe
if ($run.ExitCode) { throw "the installer ended with $($run.ExitCode)" }
"installer=" + ($url -replace '.*/', '')
$env:PGPASSWORD = 'postgres'
"service=" + (Get-Service postgresql-x64-16).Status
"server=" + (& 'C:\Program Files\PostgreSQL\16\bin\psql.exe' -U postgres -h localhost -At -c 'show server_version')
