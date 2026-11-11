# set-scale.ps1 [PERCENT]: Windows' display scaling (Settings > Display > Scale), set at once,
# without signing out, and kept. Without PERCENT: say what it is. Run it in the desktop session
# (run-interactive.ps1); win-venus.sh does, with the scale of the screen the VM's window is on.
#
# Windows has no documented call for this. Settings itself uses SystemParametersInfo with
# SPI_SETLOGICALDPIOVERRIDE (0x9F), whose number is a count of steps from the scale Windows
# recommends for the screen; SPI_GETLOGICALDPIOVERRIDE (0x9E) gives minus the recommended
# scale's place in the list of steps. PERCENT goes to the nearest step.
param([int]$Percent = 0)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VmlabScale {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint action, int param, ref int value, uint flags);
    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfo")]
    public static extern bool SystemParametersInfoSet(uint action, int param, IntPtr value, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(long point, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
    // the primary screen's scaling now, in percent
    public static int Now() {
        uint x, y;
        SetThreadDpiAwarenessContext((IntPtr)(-4));    // per monitor, or the answer is always 96
        GetDpiForMonitor(MonitorFromPoint(0, 1), 0, out x, out y);
        return (int)Math.Round(x * 100 / 96.0);
    }
}
'@
$steps = 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500
$now = [VmlabScale]::Now()
if ($Percent -le 0) { "scale $now%"; exit 0 }
$want = $steps | Sort-Object { [math]::Abs($_ - $Percent) } | Select-Object -First 1
if ($want -eq $now) { "scale $now% already"; exit 0 }
$recommended = 0
if (-not [VmlabScale]::SystemParametersInfo(0x9E, 0, [ref]$recommended, 0)) { throw 'SPI_GETLOGICALDPIOVERRIDE failed' }
$step = [array]::IndexOf($steps, $want) + $recommended      # $recommended is minus its place
if (-not [VmlabScale]::SystemParametersInfoSet(0x9F, $step, [IntPtr]::Zero, 1)) { throw 'SPI_SETLOGICALDPIOVERRIDE failed' }
Start-Sleep -Milliseconds 500
$after = [VmlabScale]::Now()
"scale $now% -> $after%"
if ($after -ne $want) { exit 2 }
