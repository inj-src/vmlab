# d3d12-mode.ps1 [bridge|native|status]: which d3d12.dll Windows has. Run it elevated in Windows
# PowerShell (win-venus.sh d3d12 ... does), then restart Windows.
#
#   bridge   the driver package's (Direct3D 12 through vkd3d-proton) in System32, and Microsoft's
#            own as vmlab-win3d\native\d3d12.dll beside it: the lab's default. A native D3D12
#            program gets a device on this GPU, and Chrome and Electron work.
#   native   Microsoft's own in System32. No Direct3D 12 on this GPU (the driver has none).
#   status   which one is there now
#
# Why the second copy: the bridge is unsigned, and a Chromium GPU process takes only
# Microsoft-signed DLLs once it runs. A page that makes it look for video encoders makes it load
# d3d12.dll; Windows refuses the bridge (error 577), Chrome ends its GPU process on purpose, and
# after three of those it has no WebGL until it is started again. The lab's Direct3D driver
# (guest-patches/9004), which that process loads before the restriction starts, loads the copy
# first: the later load by name then finds a d3d12.dll already in the process and takes it
# (../README.md). The copy must be named d3d12.dll for that, so the package's own
# vmlab-win3d\d3d12-native.dll does not do.
#
# The package's boot task, vmlab-win3d-repair, puts the bridge back at every boot: native turns
# the task off, bridge turns it on and runs it (its own way of installing the bridge).
param([ValidateSet('bridge', 'native', 'status')][string]$Mode = 'status')
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\vmlab-win3d'
$task = 'vmlab-win3d-repair'
$arches = @(@{ Name = 'x64'; Dir = "$env:windir\System32" }, @{ Name = 'x86'; Dir = "$env:windir\SysWOW64" })

function Get-Kind($a) {
    $sys = Join-Path $a.Dir 'd3d12.dll'
    if ((Get-FileHash $sys).Hash -eq (Get-FileHash "$root\bundle\runtime\$($a.Name)\d3d12.dll").Hash) { return 'bridge' }
    if ((Get-AuthenticodeSignature $sys).Status -eq 'Valid') { return 'native' }
    return 'unknown'
}

if ($Mode -eq 'native') {
    Disable-ScheduledTask -TaskName $task | Out-Null
    Remove-Item "$root\trash\d3d12-*.dll" -Force -ErrorAction SilentlyContinue     # an earlier run's, if no longer loaded
    $state = Get-Content "$root\state.json" -Raw | ConvertFrom-Json
    foreach ($a in $arches) {
        if ((Get-Kind $a) -ne 'bridge') { continue }
        $sys = Join-Path $a.Dir 'd3d12.dll'
        $native = Join-Path $a.Dir 'vmlab-win3d\d3d12-native.dll'      # the package's copy of Microsoft's file
        if ((Get-AuthenticodeSignature $native).Status -ne 'Valid') { throw "$native is not a signed file" }
        takeown.exe /F $sys /A | Out-Null
        icacls.exe $sys /grant '*S-1-5-32-544:F' | Out-Null
        # a loaded DLL can be renamed, not overwritten
        Move-Item $sys "$root\trash\d3d12-$($a.Name)-$(Get-Date -Format yyyyMMddHHmmss).dll"
        Copy-Item $native $sys
        # the owner (TrustedInstaller) and ACL Microsoft's file had, as the package recorded them
        $sddl = $state."native_d3d12_$($a.Name)".sddl
        if ($sddl) {
            $acl = Get-Acl $sys
            $acl.SetSecurityDescriptorSddlForm($sddl, 'Owner, Group, Access')
            Set-Acl $sys $acl
        }
    }
}

if ($Mode -eq 'bridge') {
    Enable-ScheduledTask -TaskName $task | Out-Null
    Start-ScheduledTask -TaskName $task
    $deadline = (Get-Date).AddSeconds(90)
    do { Start-Sleep 1 } while ((Get-ScheduledTask -TaskName $task).State -eq 'Running' -and (Get-Date) -lt $deadline)
    foreach ($a in $arches) {
        if ((Get-Kind $a) -ne 'bridge') { throw "$($a.Dir)\d3d12.dll is not the bridge after the boot task ran" }
        $native = Join-Path $a.Dir 'vmlab-win3d\d3d12-native.dll'      # the package's copy of Microsoft's file
        if ((Get-AuthenticodeSignature $native).Status -ne 'Valid') { throw "$native is not a signed file" }
        $copy = Join-Path $a.Dir 'vmlab-win3d\native\d3d12.dll'
        if ((Test-Path $copy) -and (Get-FileHash $copy).Hash -eq (Get-FileHash $native).Hash) { continue }
        New-Item -ItemType Directory -Force (Split-Path $copy) | Out-Null
        # Windows' own WebView2 programs (Search, Widgets) have it loaded: renamed, not overwritten
        if (Test-Path $copy) { Move-Item $copy "$root\trash\d3d12-copy-$($a.Name)-$(Get-Date -Format yyyyMMddHHmmss).dll" }
        Copy-Item $native $copy
    }
}

foreach ($a in $arches) {
    $sys = Join-Path $a.Dir 'd3d12.dll'
    "{0}: {1}, {2}, owner {3}" -f $sys, (Get-Kind $a), (Get-AuthenticodeSignature $sys).Status, (Get-Acl $sys).Owner
    $copy = Join-Path $a.Dir 'vmlab-win3d\native\d3d12.dll'
    "{0}: {1}" -f $copy, $(if (Test-Path $copy) { "Microsoft's for Chromium, $((Get-AuthenticodeSignature $copy).Status)" } else { 'not there' })
}
"boot task ${task}: $((Get-ScheduledTask -TaskName $task).State)"
if ($Mode -ne 'status') { 'restart Windows for every program to have it' }
