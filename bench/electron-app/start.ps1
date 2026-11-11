# Start Bench Form in the current (desktop) session. Results go to $env:BENCH_DIR or C:\bench.
param([string]$Dir = 'C:\bench')
$env:BENCH_DIR = $Dir
New-Item -ItemType Directory -Force $Dir | Out-Null
Start-Process -FilePath "$PSScriptRoot\node_modules\electron\dist\electron.exe" -ArgumentList "`"$PSScriptRoot`"" -WorkingDirectory $PSScriptRoot
