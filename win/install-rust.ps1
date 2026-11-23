# vmlab: Rust for native Windows apps, with what its standard target (x86_64-pc-windows-msvc)
# links with: Microsoft's C++ build tools and the Windows SDK. Run over SSH as dev (an SSH
# session of an admin is elevated; no desktop session needed), then restart Windows (the
# environment below) and `vm commit win`:
#   scp win/install-rust.ps1 to the guest; pwsh -NoProfile -File install-rust.ps1
# Idempotent.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$t = Join-Path $env:TEMP 'vmlab-rust'; New-Item -ItemType Directory -Force $t | Out-Null

# 1. MSVC (compiler, linker, C runtime) and the Windows SDK: Build Tools, these two parts only
$vc = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$have = (Test-Path $vswhere) -and (& $vswhere -products * -requires $vc -property installationPath)
if (-not $have) {
  Write-Output '=== Build Tools'
  Invoke-WebRequest https://aka.ms/vs/17/release/vs_buildtools.exe -OutFile "$t\vs_buildtools.exe"
  $p = Start-Process -Wait -PassThru "$t\vs_buildtools.exe" -ArgumentList @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--add', $vc, '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621')
  if ($p.ExitCode -notin 0, 3010) { throw "the Build Tools installer ended with $($p.ExitCode)" }
}

# 2. Rust: rustup, the stable toolchain without its offline documents, clippy and rustfmt
$cargo = "$env:USERPROFILE\.cargo\bin"
if (-not (Test-Path "$cargo\rustup.exe")) {
  Write-Output '=== rustup'
  Invoke-WebRequest https://win.rustup.rs/x86_64 -OutFile "$t\rustup-init.exe"
  & "$t\rustup-init.exe" -y --profile minimal --default-toolchain stable -c clippy -c rustfmt
  if ($LASTEXITCODE) { throw "rustup-init ended with $LASTEXITCODE" }
}
# 3. sccache: rustc's output per crate, kept on the build cache disk (setup-cache.ps1), so a
# clean build, a fresh checkout or a reset VM reuses what was compiled before. A clean release
# build of ripgrep: 27.5 s without it, 10.4 s with a warm cache (measured n=3, 2026-11-23).
# A release at least a month old, checked against the checksum upstream publishes with it.
$scVer = 'v0.19.0'; $scSha = '28be8c61f6b2c89b9eb2869f6af7f78e6f992e78a8abae0ce855fcc129cbeac1'
$sccache = "$cargo\sccache.exe"
if (-not ((Test-Path $sccache) -and ((& $sccache --version) -eq "sccache $($scVer.TrimStart('v'))"))) {
  Write-Output '=== sccache'
  $name = "sccache-$scVer-x86_64-pc-windows-msvc"
  Invoke-WebRequest "https://github.com/mozilla/sccache/releases/download/$scVer/$name.zip" -OutFile "$t\sccache.zip"
  if ((Get-FileHash "$t\sccache.zip" -Algorithm SHA256).Hash -ne $scSha) { throw 'the sccache download does not match its checksum' }
  Expand-Archive "$t\sccache.zip" -DestinationPath $t
  # an older one's server holds its .exe open
  if (Test-Path $sccache) { & $sccache --stop-server *>$null; $global:LASTEXITCODE = 0 }
  Copy-Item "$t\$name\sccache.exe" $sccache -Force
}
# The machine's environment, as with the Path below. Its folder appears with the first build:
# made now, it would stand where setup-cache.ps1 mounts the disk
foreach ($v in @{ RUSTC_WRAPPER = $sccache; SCCACHE_DIR = 'C:\cache\sccache'; SCCACHE_CACHE_SIZE = '4G' }.GetEnumerator()) {
  [Environment]::SetEnvironmentVariable($v.Key, $v.Value, 'Machine')
}
Remove-Item -Recurse -Force $t
# rustup puts cargo's folder on the user's Path, which SSH sessions do not get: the machine's
# Path too (sshd reads it when it starts, so: after a restart of Windows)
$machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (($machine -split ';') -notcontains $cargo) {
  [Environment]::SetEnvironmentVariable('Path', ($machine.TrimEnd(';') + ';' + $cargo), 'Machine')
}

# 4. Versions, and one program built, linked and run
$env:Path = "$cargo;$env:Path"
# without sccache: see the folder note above
$env:RUSTC_WRAPPER = $null
Write-Output '=== versions'
rustc --version; cargo --version; & $sccache --version
& $vswhere -products * -property catalog_productDisplayVersion
$probe = Join-Path $env:TEMP 'vmlab-rust-probe'
if (Test-Path $probe) { Remove-Item -Recurse -Force $probe }
cargo new --quiet --vcs none $probe
cargo run --quiet --manifest-path "$probe\Cargo.toml"
if ($LASTEXITCODE) { throw 'the probe program did not build and run' }
Remove-Item -Recurse -Force $probe
