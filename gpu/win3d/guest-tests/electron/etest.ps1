# etest.ps1 x64|ia32 [plain|webgpu|venc|on12]: run the Electron test app in the guest's desktop
# session and report its GPU process. On the host: an Electron release unpacked to
# /vmlab/share/etest/<arch>, and main.js, package.json and ../venc.html in /vmlab/share/etest/app.
# Then: vm ssh win 'pwsh -File C:\share\etest\etest.ps1 x64 venc'
param([ValidateSet('x64', 'ia32')][string]$Arch = 'x64', [ValidateSet('plain', 'webgpu', 'venc', 'on12')][string]$Variant = 'plain')
$dir = "C:\Users\dev\etest"; $out = "$dir\result-$Arch.txt"
# Chromium switches that make the GPU process load d3d12.dll, which a plain Electron does not do
$extra = @{ plain = @(); webgpu = @('--enable-unsafe-webgpu', '--ignore-gpu-blocklist');
            venc = @('--enable-features=D3D12VideoEncodeAccelerator,D3D12VideoDecoder', '--ignore-gpu-blocklist');
            on12 = @('--use-angle=d3d11on12') }[$Variant]
$argList = (@($extra) + @("$dir\app", "--out=$out") | ForEach-Object { "'$_'" }) -join ','
if (-not (Test-Path "$dir\$Arch\electron.exe")) { New-Item -ItemType Directory -Force $dir | Out-Null; Copy-Item "C:\share\etest\$Arch" "$dir\$Arch" -Recurse }
Remove-Item "$dir\app" -Recurse -Force -ErrorAction SilentlyContinue; Copy-Item C:\share\etest\app "$dir\app" -Recurse
Remove-Item $out -ErrorAction SilentlyContinue
Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue
powershell -File C:\vmlab\run-interactive.ps1 -Command "Start-Process '$dir\$Arch\electron.exe' -ArgumentList $argList" -TimeoutSec 30 | Out-Null
Start-Sleep 14
foreach ($c in Get-CimInstance Win32_Process -Filter "Name='electron.exe'") {
  if ($c.CommandLine -notmatch '--type=gpu-process') { continue }
  $id = $c.ProcessId
  $list = "(Get-Process -Id $id).Modules | Where-Object { `$_.ModuleName -match '^(d3d12|d3d12core|viogpu_d3d10|vkd3dcore)\.dll$' } | ForEach-Object { `$_.FileName }"
  $ps = if ($Arch -eq 'ia32') { "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" } else { "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
  $mods = & $ps -NoProfile -Command $list
  "[$Variant] gpu process pid ${id}: MicrosoftSignedOnly=$((Get-ProcessMitigation -Id $id).BinarySignature.MicrosoftSignedOnly); modules: $($mods -join '; ')"
}
$n = 0; while ($n -lt 30 -and -not ((Test-Path $out) -and (Select-String -Path $out -Pattern '^end$' -Quiet))) { Start-Sleep 1; $n++ }
"--- $out"; Get-Content $out -ErrorAction SilentlyContinue
"electron processes left: $(@(Get-Process electron -ErrorAction SilentlyContinue).Count)"
