//! vmshell: the shell OpenSSH starts for every session on the Windows VM (its DefaultShell).
//!
//! It runs pwsh with the command line sshd gave it, so a session behaves as with pwsh itself
//! (quoting, stdin, stderr, exit code, terminal), with one difference: what the session starts
//! outlives the connection, as programs started from a terminal on a desktop do. Win32-OpenSSH
//! puts each session in a job object that kills every process in it when the session ends
//! (KILL_ON_JOB_CLOSE, with BREAKAWAY_OK). vmshell starts pwsh outside that job, in a job of its
//! own that kills pwsh with vmshell (so a dropped connection still ends the command) and lets
//! everything pwsh starts leave it (SILENT_BREAKAWAY_OK).
//!
//! Source of the job limits: PowerShell/openssh-portable, contrib/win32/win32compat/w32-doexec.c,
//! do_exec_windows().
//!
//! With no command and stdin that is not a terminal (`ssh win < build.ps1`, `ssh win <<'EOF'`),
//! stdin is the script: vmshell saves it to a file and runs that, as `ssh host < x.sh` runs a
//! script on Linux. (pwsh would read it line by line as typed input, where a block over several
//! lines and `exit` do not work.) The exit code is the script's `exit N`, else that of the last
//! program it ran, 1 after an error that ended it, else 0.

use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::process::{exit, Command};
use std::ptr::null;

const PWSH: &str = r"C:\Program Files\PowerShell\7\pwsh.exe";

const CREATE_SUSPENDED: u32 = 0x0000_0004;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
const JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK: u32 = 0x1000;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: i32 = 9;

type Handle = *mut core::ffi::c_void;

#[link(name = "kernel32")]
extern "system" {
    fn GetCommandLineW() -> *const u16;
    fn SetConsoleCtrlHandler(h: Option<extern "system" fn(u32) -> i32>, add: i32) -> i32;
    fn CreateJobObjectW(attrs: *const core::ffi::c_void, name: *const u16) -> Handle;
    fn SetInformationJobObject(job: Handle, class: i32, info: *const u8, len: u32) -> i32;
    fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
    fn GetStdHandle(which: u32) -> Handle;
    fn GetFileType(h: Handle) -> u32;
}
const STD_INPUT_HANDLE: u32 = -10i32 as u32;
const FILE_TYPE_CHAR: u32 = 2;
#[link(name = "ntdll")]
extern "system" {
    fn NtResumeProcess(process: Handle) -> i32;
}

/// Ctrl+C and Ctrl+Break are pwsh's to handle; vmshell only waits. (A handler, unlike
/// SetConsoleCtrlHandler(NULL, TRUE), is not inherited by pwsh.)
extern "system" fn ignore(_: u32) -> i32 {
    1
}

/// Our command line without our own program name, exactly as sshd wrote it.
fn args_after_program() -> String {
    let line = unsafe {
        let p = GetCommandLineW();
        let mut n = 0;
        while *p.add(n) != 0 {
            n += 1;
        }
        String::from_utf16_lossy(std::slice::from_raw_parts(p, n))
    };
    let rest = match line.strip_prefix('"') {
        Some(r) => r.find('"').map_or("", |i| &r[i + 1..]),
        None => line.find([' ', '\t']).map_or("", |i| &line[i..]),
    };
    rest.trim_start().to_string()
}

/// A job that kills pwsh when vmshell ends and keeps nothing pwsh starts. None if Windows
/// refuses one; pwsh then runs without it.
fn own_job() -> Option<Handle> {
    let job = unsafe { CreateJobObjectW(null(), null()) };
    if job.is_null() {
        return None;
    }
    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 144 bytes on x64; BasicLimitInformation.LimitFlags
    // is the u32 at offset 16.
    let mut info = [0u8; 144];
    let flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
    info[16..20].copy_from_slice(&flags.to_le_bytes());
    let ok = unsafe {
        SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, info.as_ptr(), 144)
    };
    (ok != 0).then_some(job)
}

/// A script that came on stdin, saved to a file; removed when vmshell ends.
struct StdinScript(std::path::PathBuf);
impl Drop for StdinScript {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn stdin_script() -> Option<StdinScript> {
    let console = unsafe { GetFileType(GetStdHandle(STD_INPUT_HANDLE)) } == FILE_TYPE_CHAR;
    if console {
        return None;
    }
    let mut text = Vec::new();
    std::io::Read::read_to_end(&mut std::io::stdin(), &mut text).ok()?;
    let path = std::env::temp_dir().join(format!("vmshell-{}.ps1", std::process::id()));
    std::fs::write(&path, text).ok()?;
    Some(StdinScript(path))
}

fn main() {
    unsafe { SetConsoleCtrlHandler(Some(ignore), 1) };
    let mut args = args_after_program();
    let script = if args.is_empty() { stdin_script() } else { None };
    if let Some(s) = &script {
        args = format!(
            "-NoLogo -NonInteractive -Command \"& '{}'; if ($null -ne $LASTEXITCODE) {{ exit $LASTEXITCODE }}\"",
            s.0.display()
        );
    }
    let job = own_job();
    let spawn = |flags: u32| {
        let mut c = Command::new(PWSH);
        c.raw_arg(&args).creation_flags(flags);
        if script.is_some() {
            c.stdin(std::process::Stdio::null()); // stdin was the script
        }
        c.spawn()
    };

    // Leave sshd's job. Outside a job, or in one that forbids it, start pwsh where we are.
    let (mut child, suspended) = match spawn(CREATE_BREAKAWAY_FROM_JOB | CREATE_SUSPENDED) {
        Ok(c) => (c, true),
        Err(_) => match spawn(0) {
            Ok(c) => (c, false),
            Err(e) => {
                eprintln!("vmshell: cannot start {PWSH}: {e}");
                exit(1)
            }
        },
    };
    if suspended {
        let h = child.as_raw_handle() as Handle;
        if let Some(job) = job {
            unsafe { AssignProcessToJobObject(job, h) };
        }
        unsafe { NtResumeProcess(h) };
    }
    let code = match child.wait() {
        Ok(st) => st.code().unwrap_or(1),
        Err(_) => 1,
    };
    drop(script);
    exit(code)
}
