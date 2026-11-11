# set-mode.ps1 [WxH]: the desktop's resolution, set and kept. Without WxH: say what it is. Run
# it in the desktop session (run-interactive.ps1). win-venus.sh does, with the size its window
# offered Windows, for the times Windows did not take it by itself: shown a size it has not
# seen before while it starts, Windows sometimes settles on 1024x768 and remembers that for the
# size. Exit code 2: the display has no such mode (yet).
param([string]$Size = '')
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VmlabMode {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettingsW(string device, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsW(ref DEVMODE dm, uint flags);
    static DEVMODE New() { var dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE)); return dm; }
    // the mode now, as "WxH"
    public static string Now() {
        var dm = New();
        return EnumDisplaySettingsW(null, -1, ref dm) ? dm.dmPelsWidth + "x" + dm.dmPelsHeight : "";
    }
    // whether the display lists that mode
    public static bool Has(uint w, uint h) {
        var dm = New();
        for (int i = 0; EnumDisplaySettingsW(null, i, ref dm); i++) { if (dm.dmPelsWidth == w && dm.dmPelsHeight == h) return true; }
        return false;
    }
    // sets it and saves it for this display (CDS_UPDATEREGISTRY); 0 = done
    public static int Set(uint w, uint h) {
        var dm = New();
        if (!EnumDisplaySettingsW(null, -1, ref dm)) return -100;
        dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x80000 | 0x100000;   // DM_PELSWIDTH | DM_PELSHEIGHT
        return ChangeDisplaySettingsW(ref dm, 1);
    }
}
'@
$now = [VmlabMode]::Now()
if (-not $Size) { "mode $now"; exit 0 }
if ($Size -notmatch '^(\d+)x(\d+)$') { throw "usage: set-mode.ps1 [WxH]" }
$w = [uint32]$Matches[1]; $h = [uint32]$Matches[2]
if ($now -eq $Size) { "mode $now already"; exit 0 }
if (-not [VmlabMode]::Has($w, $h)) { "mode $now, and the display has no $Size"; exit 2 }
$rc = [VmlabMode]::Set($w, $h)
if ($rc -ne 0) { throw "ChangeDisplaySettings gave $rc" }
"mode $now -> $([VmlabMode]::Now())"
