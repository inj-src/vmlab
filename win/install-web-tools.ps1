# install-web-tools.ps1: what a JavaScript project needs beyond the VM's Node, in the ready state
# (the agents' feedback, 2026-11-12). Run over SSH as dev (elevated), then restart Windows: SSH
# sessions get the machine's Path and variables as they were at Windows' start.
#   - pnpm, standalone (C:\Program Files\pnpm). Node 26 has no corepack, and pnpm from
#     `npm i -g` gets a PowerShell shim that prints nothing. It runs the version a project
#     names in "packageManager" by itself.
#   - fnm (C:\Program Files\fnm), for a project that needs another Node than the VM's:
#     `fnm install 24` once, then `fnm use 24` in a pwsh session, or
#     `fnm exec --using=24 -- <command>` anywhere. Every session starts on the VM's own node,
#     whatever fnm's default is, and changes only at a `fnm use` (no switch at `cd`: fnm's
#     falls back to its default, or to any version that fits package.json's "engines").
#   - downloads kept on the build cache disk (C:\cache), which reset leaves alone: fnm's Node
#     versions, pnpm's own versions, Electron's zips, electron-builder's, npm's cache.
#   - host.vmlab: the host machine's name (10.0.2.2), for what cannot use `vm forward`.
# Prints name=value a line at the end.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
function Get-Asset($repo, $name, $dest) {
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
    $asset = $release.assets | Where-Object name -eq $name
    if (-not $asset) { throw "$repo $($release.tag_name) has no $name" }
    $zip = Join-Path $env:TEMP $name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive $zip $dest; Remove-Item $zip
}
Get-Asset 'pnpm/pnpm' 'pnpm-win32-x64.zip' 'C:\Program Files\pnpm'
Get-Asset 'Schniz/fnm' 'fnm-windows.zip' 'C:\Program Files\fnm'
# (a zip that holds one folder: its files go up)
foreach ($dir in 'C:\Program Files\pnpm', 'C:\Program Files\fnm') {
    $inner = @(Get-ChildItem $dir)
    if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { Get-ChildItem $inner[0].FullName | Move-Item -Destination $dir; Remove-Item $inner[0].FullName }
}

$path = [Environment]::GetEnvironmentVariable('Path', 'Machine').TrimEnd(';')
foreach ($dir in 'C:\Program Files\pnpm', 'C:\Program Files\fnm') {
    if (($path -split ';') -notcontains $dir) { $path += ";$dir" }
}
[Environment]::SetEnvironmentVariable('Path', $path, 'Machine')
$vars = [ordered]@{
    FNM_DIR                = 'C:\cache\fnm'
    PNPM_HOME              = 'C:\cache\pnpm'
    electron_config_cache  = 'C:\cache\electron'
    ELECTRON_BUILDER_CACHE = 'C:\cache\electron-builder'
    npm_config_cache       = 'C:\cache\npm'
}
foreach ($v in $vars.GetEnumerator()) { [Environment]::SetEnvironmentVariable($v.Key, $v.Value, 'Machine') }

# `fnm use` works in every pwsh session (SSH's too); with no argument it reads the folder's
# .node-version or .nvmrc
$hook = @'
# vmlab: fnm's shell hook (win/install-web-tools.ps1). Without a `fnm use`, node is the VM's own.
if (Get-Command fnm -ErrorAction SilentlyContinue) {
    # (`fnm use system`: fnm makes the first version anyone installs its default, and its
    # versions are on the cache disk, which outlives a reset: every session starts on the VM's node)
    try { fnm env --shell powershell | Out-String | Invoke-Expression; fnm use system *> $null } catch { }
}
'@
$profilePath = 'C:\Program Files\PowerShell\7\profile.ps1'
$kept = if (Test-Path $profilePath) { (Get-Content $profilePath -Raw) -replace '(?s)# vmlab: fnm.*?\r?\n}\r?\n?', '' } else { '' }
Set-Content $profilePath ($kept.TrimEnd() + "`r`n" + $hook).TrimStart() -Encoding utf8

$hosts = 'C:\Windows\System32\drivers\etc\hosts'
if (-not (Select-String -Path $hosts -SimpleMatch 'host.vmlab' -Quiet)) { Add-Content $hosts "`r`n10.0.2.2 host.vmlab" }

"pnpm=" + (& 'C:\Program Files\pnpm\pnpm.exe' --version)
"fnm=" + ((& 'C:\Program Files\fnm\fnm.exe' --version) -replace '^fnm ', '')
"hosts=" + ((Select-String -Path $hosts -SimpleMatch 'host.vmlab').Line.Trim())
