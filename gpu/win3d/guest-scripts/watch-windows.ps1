# watch-windows.ps1 [SECONDS] [OUT]: which windows show up on the desktop during SECONDS (10).
# Run it in the desktop session (run-interactive.ps1 -NoWait). Every visible top-level window
# that was not there at the start is written to OUT (C:\vmlab\interactive\watch.log) once:
# "ms class | process | title". For checking that a helper shows no window (a console's flash
# lasts a few frames: the desktop is polled every 10 ms).
param([int]$Seconds = 10, [string]$Out = 'C:\vmlab\interactive\watch.log')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class VmlabWatch {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static List<string> Visible() {
        var list = new List<string>();
        EnumWindows((h, l) => {
            if (IsWindowVisible(h)) {
                var c = new StringBuilder(256); var t = new StringBuilder(256); uint pid;
                GetClassNameW(h, c, 256); GetWindowTextW(h, t, 256); GetWindowThreadProcessId(h, out pid);
                list.Add(h.ToInt64() + "\t" + c + "\t" + pid + "\t" + t);
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
$seen = @{}
foreach ($w in [VmlabWatch]::Visible()) { $seen[$w.Split("`t")[0]] = 1 }
"watching $Seconds s" | Set-Content $Out -Encoding utf8
$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
    foreach ($w in [VmlabWatch]::Visible()) {
        $h, $class, $procId, $title = $w.Split("`t")
        if (-not $seen[$h]) {
            $seen[$h] = 1
            $name = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
            "$([int]$clock.Elapsed.TotalMilliseconds) $class | $name | $title" | Add-Content $Out -Encoding utf8
        }
    }
    Start-Sleep -Milliseconds 10
}
"done" | Add-Content $Out -Encoding utf8
