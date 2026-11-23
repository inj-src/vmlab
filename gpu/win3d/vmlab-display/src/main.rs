//! vmlab-display: the Windows VM's resolution and display scaling, set in one call and kept.
//! scale-watch in win-venus.sh runs it over SSH when the VM's window is shown, hidden or
//! resized. It does what guest-scripts/set-mode.ps1 and set-scale.ps1 do, with the same checks,
//! calls and messages, without pwsh's start, the two C# compiles and the fixed wait (about 3.6 s
//! in Windows for a call that changed nothing; this takes tens of milliseconds).
//!
//! vmlab-display [--mode WxH] [--scale PERCENT] [--scale-always]
//!
//! It prints one line for each step it runs, as scale-watch's PowerShell wrapper (guest_display)
//! does for the scripts, and scale-watch reads them the same way:
//!
//!   @mode RC LINE     the resolution: RC 0 done or already so, 2 the display has no such
//!                     mode (yet), 1 it failed; LINE says what it is now
//!   @scale RC LINE    the scaling: RC 0 done or already so, 2 Windows settled on another
//!                     scaling, 1 it failed
//!   @desktop no       this process is not on the desktop (session 0: a state from before
//!                     desktop-ssh); nothing else is run, exit code 3
//!
//! The scaling runs after the resolution only when that gave 0 (Windows keeps a scaling for each
//! resolution, so one set before the resolution would be lost), or with --scale-always.
//! Without --mode it just runs. With neither option: both are reported, nothing is changed.
//! The exit code is the highest RC of the steps that ran (scale-watch goes by the lines).
//!
//! Run it in the desktop session: SSH's sessions are there since desktop-ssh (346efb2).

#[cfg(not(windows))]
compile_error!("vmlab-display is a Windows program: build.sh builds it in the Windows VM");

use std::process::exit;
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};

type Handle = *mut core::ffi::c_void;

// DEVMODEW, the display half of its unions (wingdi.h)
#[repr(C)]
#[derive(Clone, Copy)]
struct DevModeW {
    device_name: [u16; 32],
    spec_version: u16,
    driver_version: u16,
    size: u16,
    driver_extra: u16,
    fields: u32,
    position_x: i32,
    position_y: i32,
    display_orientation: u32,
    display_fixed_output: u32,
    color: i16,
    duplex: i16,
    y_resolution: i16,
    tt_option: i16,
    collate: i16,
    form_name: [u16; 32],
    log_pixels: u16,
    bits_per_pel: u32,
    pels_width: u32,
    pels_height: u32,
    display_flags: u32,
    display_frequency: u32,
    icm_method: u32,
    icm_intent: u32,
    media_type: u32,
    dither_type: u32,
    reserved1: u32,
    reserved2: u32,
    panning_width: u32,
    panning_height: u32,
}
const _: () = assert!(std::mem::size_of::<DevModeW>() == 220);

#[repr(C)]
struct Point {
    x: i32,
    y: i32,
}

const ENUM_CURRENT_SETTINGS: u32 = 0xFFFF_FFFF;
const DM_PELSWIDTH: u32 = 0x0008_0000;
const DM_PELSHEIGHT: u32 = 0x0010_0000;
const CDS_UPDATEREGISTRY: u32 = 1;
const DISP_CHANGE_SUCCESSFUL: i32 = 0;
const SPI_GETLOGICALDPIOVERRIDE: u32 = 0x9E;
const SPI_SETLOGICALDPIOVERRIDE: u32 = 0x9F;
const SPIF_UPDATEINIFILE: u32 = 1;
const MONITOR_DEFAULTTOPRIMARY: u32 = 1;
const MDT_EFFECTIVE_DPI: i32 = 0;
// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: else GetDpiForMonitor always says 96
const PER_MONITOR_AWARE_V2: isize = -4;

#[link(name = "user32")]
extern "system" {
    fn EnumDisplaySettingsW(device: *const u16, mode: u32, dm: *mut DevModeW) -> i32;
    fn ChangeDisplaySettingsW(dm: *mut DevModeW, flags: u32) -> i32;
    fn SystemParametersInfoW(action: u32, param: u32, value: *mut core::ffi::c_void, flags: u32) -> i32;
    fn SetThreadDpiAwarenessContext(context: Handle) -> Handle;
    fn MonitorFromPoint(pt: Point, flags: u32) -> Handle;
}
#[link(name = "shcore")]
extern "system" {
    fn GetDpiForMonitor(monitor: Handle, kind: i32, x: *mut u32, y: *mut u32) -> i32;
}
#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentProcessId() -> u32;
    fn ProcessIdToSessionId(pid: u32, session: *mut u32) -> i32;
}

// Windows' scaling steps, as Settings lists them
const STEPS: [i32; 12] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];
// set-scale.ps1 waited 500 ms and looked once; this looks until the scaling is there
const SCALE_WAIT: Duration = Duration::from_millis(1500);
const SCALE_POLL: Duration = Duration::from_millis(20);

fn devmode() -> DevModeW {
    // SAFETY: DEVMODEW is plain data; all zeros is a valid value
    let mut dm: DevModeW = unsafe { std::mem::zeroed() };
    dm.size = std::mem::size_of::<DevModeW>() as u16;
    dm
}

/// The mode now, as "WxH" ("" where Windows does not say)
fn mode_now() -> String {
    let mut dm = devmode();
    if unsafe { EnumDisplaySettingsW(null(), ENUM_CURRENT_SETTINGS, &mut dm) } != 0 {
        format!("{}x{}", dm.pels_width, dm.pels_height)
    } else {
        String::new()
    }
}

/// Whether the display lists that mode
fn mode_listed(w: u32, h: u32) -> bool {
    let mut dm = devmode();
    let mut i = 0;
    while unsafe { EnumDisplaySettingsW(null(), i, &mut dm) } != 0 {
        if dm.pels_width == w && dm.pels_height == h {
            return true;
        }
        i += 1;
    }
    false
}

/// Sets it and saves it for this display (CDS_UPDATEREGISTRY); DISP_CHANGE_SUCCESSFUL = done
fn mode_set(w: u32, h: u32) -> i32 {
    let mut dm = devmode();
    if unsafe { EnumDisplaySettingsW(null(), ENUM_CURRENT_SETTINGS, &mut dm) } == 0 {
        return -100;
    }
    dm.pels_width = w;
    dm.pels_height = h;
    dm.fields = DM_PELSWIDTH | DM_PELSHEIGHT;
    unsafe { ChangeDisplaySettingsW(&mut dm, CDS_UPDATEREGISTRY) }
}

fn parse_size(s: &str) -> Option<(u32, u32)> {
    let (w, h) = s.split_once('x')?;
    let digits = |p: &str| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit());
    if !digits(w) || !digits(h) {
        return None;
    }
    Some((w.parse().ok()?, h.parse().ok()?))
}

/// set-mode.ps1 SIZE
fn mode_step(size: &str) -> (i32, String) {
    let now = mode_now();
    let Some((w, h)) = parse_size(size) else { return (1, "usage: --mode WxH".into()) };
    if now == size {
        return (0, format!("mode {now} already"));
    }
    if !mode_listed(w, h) {
        return (2, format!("mode {now}, and the display has no {size}"));
    }
    let rc = mode_set(w, h);
    if rc != DISP_CHANGE_SUCCESSFUL {
        return (1, format!("ChangeDisplaySettings gave {rc}"));
    }
    (0, format!("mode {now} -> {}", mode_now()))
}

/// The primary screen's scaling now, in percent
fn scale_now() -> i32 {
    let (mut x, mut y) = (0u32, 0u32);
    unsafe {
        let monitor = MonitorFromPoint(Point { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut x, &mut y);
    }
    // (Math.Round in the script: ties to even)
    (f64::from(x) * 100.0 / 96.0).round_ties_even() as i32
}

/// set-scale.ps1 PERCENT. Windows has no documented call for this. Settings itself uses
/// SystemParametersInfo with SPI_SETLOGICALDPIOVERRIDE, whose number is a count of steps from
/// the scale Windows recommends for the screen; SPI_GETLOGICALDPIOVERRIDE gives minus the
/// recommended scale's place in the list of steps. PERCENT goes to the nearest step (the lower
/// one on a tie).
fn scale_step(percent: i32) -> (i32, String) {
    let now = scale_now();
    if percent <= 0 {
        return (0, format!("scale {now}%"));
    }
    let (place, want) = STEPS
        .iter()
        .copied()
        .enumerate()
        .min_by_key(|&(_, s)| (i64::from(s) - i64::from(percent)).abs())
        .unwrap();
    if want == now {
        return (0, format!("scale {now}% already"));
    }
    let mut recommended: i32 = 0;
    let ok = unsafe { SystemParametersInfoW(SPI_GETLOGICALDPIOVERRIDE, 0, (&mut recommended as *mut i32).cast(), 0) };
    if ok == 0 {
        return (1, "SPI_GETLOGICALDPIOVERRIDE failed".into());
    }
    let step = place as i32 + recommended; // recommended is minus its place
    if unsafe { SystemParametersInfoW(SPI_SETLOGICALDPIOVERRIDE, step as u32, null_mut(), SPIF_UPDATEINIFILE) } == 0 {
        return (1, "SPI_SETLOGICALDPIOVERRIDE failed".into());
    }
    let deadline = Instant::now() + SCALE_WAIT;
    let mut after = scale_now();
    while after != want && Instant::now() < deadline {
        std::thread::sleep(SCALE_POLL);
        after = scale_now();
    }
    (if after == want { 0 } else { 2 }, format!("scale {now}% -> {after}%"))
}

fn usage() -> ! {
    eprintln!("usage: vmlab-display [--mode WxH] [--scale PERCENT] [--scale-always]");
    exit(64)
}

fn main() {
    let (mut mode, mut scale, mut always) = (None::<String>, None::<i32>, false);
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--mode" => mode = Some(args.next().unwrap_or_else(|| usage())),
            "--scale" => scale = Some(args.next().and_then(|p| p.parse().ok()).unwrap_or_else(|| usage())),
            "--scale-always" => always = true,
            _ => usage(),
        }
    }

    let mut session = u32::MAX;
    if unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) } != 0 && session == 0 {
        println!("@desktop no");
        exit(3);
    }
    unsafe { SetThreadDpiAwarenessContext(PER_MONITOR_AWARE_V2 as Handle) };

    if mode.is_none() && scale.is_none() {
        println!("@mode 0 mode {}", mode_now());
        println!("@scale 0 scale {}%", scale_now());
        return;
    }
    let mut worst = 0;
    let mut mode_rc = None;
    if let Some(size) = &mode {
        let (rc, line) = mode_step(size);
        println!("@mode {rc} {line}");
        mode_rc = Some(rc);
        worst = worst.max(rc);
    }
    if let Some(percent) = scale {
        if always || mode_rc.is_none_or(|rc| rc == 0) {
            let (rc, line) = scale_step(percent);
            println!("@scale {rc} {line}");
            worst = worst.max(rc);
        }
    }
    exit(worst)
}
