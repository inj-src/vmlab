# vmlab: the build cache disk in the Windows guest, at C:\cache. Run over SSH as dev, then
# `vm commit win`. Idempotent.
# The disk is the launcher's second one (win-venus.sh, CACHE; serial vmlabcache), which `vm
# reset` and `vm commit` leave alone. C:\cache\src is where `vm push` puts repositories, so a
# checkout and its build output outlive a reset; cargo's downloads (registry, git) are kept
# there too, through links from dev's .cargo folder.
$ErrorActionPreference = 'Stop'
$disk = Get-Disk | Where-Object SerialNumber -eq 'vmlabcache'
if (-not $disk) { throw 'no disk with the serial vmlabcache: was the VM started with VMLAB_CACHE=off?' }
if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
if ($disk.PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $disk.Number -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel cache -Confirm:$false | Out-Null
}
$part = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic'
if ($part.AccessPaths -notcontains 'C:\cache\') {
    # C:\cache may still be the mount point of an earlier cache disk, made anew since
    if (Test-Path C:\cache) { cmd /c 'mountvol C:\cache /D 2>nul'; $global:LASTEXITCODE = 0 }
    if (-not (Test-Path C:\cache)) { New-Item -ItemType Directory C:\cache | Out-Null }
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath C:\cache
}
foreach ($d in 'src', 'cargo\registry', 'cargo\git') { New-Item -ItemType Directory -Force "C:\cache\$d" | Out-Null }
# cargo's downloads: links, so CARGO_HOME (and rustup's files in it) stay where they are
foreach ($d in 'registry', 'git') {
    $link = "$env:USERPROFILE\.cargo\$d"
    $item = Get-Item $link -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'Junction') { continue }
    if ($item) { Remove-Item $link -Recurse -Force }
    New-Item -ItemType Junction -Path $link -Target "C:\cache\cargo\$d" | Out-Null
}
Get-Volume -FileSystemLabel cache | Format-List FileSystemLabel, FileSystem, Size, SizeRemaining
Get-ChildItem C:\cache -Force | Select-Object -ExpandProperty Name
