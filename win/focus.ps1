# focus.ps1 <window>: bring a window to the front and give it the keyboard, from a test script.
# <window> is part of its title, a process name (notepad) or a process id. Run it in the
# desktop session:  C:\vmlab\run-interactive.ps1 -Command "C:\vmlab\focus.ps1 notepad"
# Prints the window it focused; exit code 1 when there is no such window or it did not come
# forward (the line says what is in front).
#
# Why a helper: Windows lets only the program in front hand the foreground on, so a plain
# SetForegroundWindow or AppActivate from a script fails most of the time and the test types
# into whatever was in front. This joins the input queue of the window in front for the
# switch (AttachThreadInput), which sends no key press that a keyboard hook under test could see.
param([Parameter(Mandatory)][string]$Window)
Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class VmlabFocus {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
    public static List<IntPtr> Windows() {      // visible, titled, front to back
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { if (IsWindowVisible(h) && Title(h).Length > 0) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }
    public static void Front(IntPtr h) {
        uint pid; uint me = GetCurrentThreadId();
        uint front = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        if (IsIconic(h)) ShowWindow(h, 9);      // SW_RESTORE
        if (front != 0 && front != me) AttachThreadInput(me, front, true);
        BringWindowToTop(h); SetForegroundWindow(h);
        if (front != 0 && front != me) AttachThreadInput(me, front, false);
    }
}
'@
function Describe($h) { $id = 0; [void][VmlabFocus]::GetWindowThreadProcessId($h, [ref]$id); '"{0}" (pid {1}, {2})' -f [VmlabFocus]::Title($h), $id, (Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName }
$target = $null
foreach ($h in [VmlabFocus]::Windows()) {
    $id = 0; [void][VmlabFocus]::GetWindowThreadProcessId($h, [ref]$id)
    $name = (Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName
    if ($Window -match '^\d+$') { $hit = $id -eq [int]$Window }
    else { $hit = [VmlabFocus]::Title($h) -like "*$Window*" -or $name -eq ($Window -replace '\.exe$', '') }
    if ($hit) { $target = $h; break }
}
if (-not $target) { "no window like '$Window'. Open: " + (([VmlabFocus]::Windows() | ForEach-Object { Describe $_ }) -join '; '); exit 1 }
foreach ($try in 1..5) {
    [VmlabFocus]::Front($target); Start-Sleep -Milliseconds 200
    if ([VmlabFocus]::GetForegroundWindow() -eq $target) { "focused: $(Describe $target)"; exit 0 }
}
"not in front: $(Describe $target); in front is $(Describe ([VmlabFocus]::GetForegroundWindow()))"; exit 1
