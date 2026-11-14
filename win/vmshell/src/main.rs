//! vmshell: the shell OpenSSH starts for every session on the Windows VM (its DefaultShell).
//!
//! It runs Git Bash (`ssh win`), or PowerShell 7 when the session asks for it with the
//! environment variable VMLAB_SHELL=pwsh (`ssh win-pwsh`, which sets it with SetEnv; sshd_config
//! has AcceptEnv VMLAB_SHELL). A session then behaves as with that shell itself (quoting, stdin,
//! stderr, exit code, terminal), with these differences:
//!
//! - What the session starts outlives the connection, as programs started from a terminal on a
//!   desktop do. Win32-OpenSSH puts each session in a job object that kills every process in it
//!   when the session ends (KILL_ON_JOB_CLOSE, with BREAKAWAY_OK). vmshell starts the shell
//!   outside that job, in a job of its own that lets everything the shell starts leave it
//!   (SILENT_BREAKAWAY_OK). A dropped connection still ends the command: sshd's process for
//!   the session, vmshell's parent, then ends, and vmshell ends the shell's process tree.
//!   Source of the job limits: PowerShell/openssh-portable,
//!   contrib/win32/win32compat/w32-doexec.c, do_exec_windows().
//! - Path is read from the registry, as a new terminal window does: sshd's own environment is
//!   the one of dev's logon, so a tool installed later (winget, rustup) would be missing.
//! - Without a terminal, the shell's stdin, stdout and stderr are pipes of vmshell's, which it
//!   copies to and from sshd's, and the session ends when the shell does. Windows gives a program
//!   every inheritable handle of the process that starts it, so a program a command leaves
//!   running (`nohup server > log 2>&1 &`, even `start`) would hold sshd's pipes, and the session
//!   would last as long as that program. When the shell ends, vmshell passes on what is left in
//!   its pipes and stops there.
//!
//! Bash is Git's usr\bin\bash.exe with the environment its bin\bash.exe sets up (that one is a
//! launcher, and only it would be in vmshell's job). A command goes in an environment variable
//! that bash evaluates, so it reaches bash exactly as sent. (Programs built on Cygwin, as Git Bash is, split their Windows command line
//! with rules of their own: single quotes quote, and unquoted wildcards are expanded.) A script
//! on stdin and an interactive session (a login shell) are bash's own.
//!
//! PowerShell: with no command and stdin that is not a terminal (`ssh win-pwsh < build.ps1`),
//! stdin is the script: vmshell saves it to a file and runs that, as `ssh host < x.sh` runs a
//! script on Linux. (pwsh would read it line by line as typed input, where a block over several
//! lines and `exit` do not work.) A command (`-c <command>` from sshd) goes to pwsh as
//! -EncodedCommand, so stdin stays the command's (`$input`, a program reading it). Both end with
//! a check of the last command, so the exit code is as in a POSIX shell: `exit N`; else the last
//! command's: a program's own exit code, 1 for a cmdlet that failed, 0 for one that worked; 1
//! after an error that ended the script or kept it from running. (`pwsh -c` returns 1 for a
//! failed program, whatever its exit code was.)

use std::io::{Read, Write};
use std::os::windows::io::{AsRawHandle, FromRawHandle, IntoRawHandle};
use std::os::windows::process::CommandExt;
use std::process::{exit, Child, Command, Stdio};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};

const GIT: &str = r"C:\Program Files\Git";
const PWSH: &str = r"C:\Program Files\PowerShell\7\pwsh.exe";
const BASH_ENV: &str = r"C:\vmlab\bash-env.sh";

const CREATE_SUSPENDED: u32 = 0x0000_0004;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
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
    fn PeekNamedPipe(pipe: Handle, buf: *mut u8, size: u32, read: *mut u32, avail: *mut u32, left: *mut u32) -> i32;
    fn CancelIoEx(file: Handle, overlapped: *mut core::ffi::c_void) -> i32;
    fn SetHandleInformation(h: Handle, mask: u32, flags: u32) -> i32;
    fn GetCurrentProcess() -> Handle;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn WaitForSingleObject(h: Handle, ms: u32) -> u32;
    fn TerminateJobObject(job: Handle, code: u32) -> i32;
}
const SYNCHRONIZE: u32 = 0x0010_0000;
const INFINITE: u32 = u32::MAX;
const STD_OUTPUT_HANDLE: u32 = -11i32 as u32;
const STD_ERROR_HANDLE: u32 = -12i32 as u32;
const HANDLE_FLAG_INHERIT: u32 = 1;
const STD_INPUT_HANDLE: u32 = -10i32 as u32;
const FILE_TYPE_CHAR: u32 = 2;
#[link(name = "ntdll")]
extern "system" {
    fn NtResumeProcess(process: Handle) -> i32;
    fn NtQueryInformationProcess(process: Handle, class: u32, info: *mut u8, len: u32, ret: *mut u32) -> i32;
}

/// The process that started vmshell (sshd's process for the session), to wait on. Opened before
/// the shell starts, while sshd still waits for vmshell, so the ID is still that process's.
fn parent_process() -> Option<Handle> {
    // PROCESS_BASIC_INFORMATION (class 0) is 48 bytes on x64; InheritedFromUniqueProcessId is
    // at offset 40.
    let mut info = [0u8; 48];
    let st = unsafe { NtQueryInformationProcess(GetCurrentProcess(), 0, info.as_mut_ptr(), 48, null_mut()) };
    if st != 0 {
        return None;
    }
    let pid = u64::from_le_bytes(info[40..48].try_into().unwrap()) as u32;
    let h = unsafe { OpenProcess(SYNCHRONIZE, 0, pid) };
    (!h.is_null()).then_some(h)
}
#[link(name = "advapi32")]
extern "system" {
    fn RegGetValueW(key: Handle, sub: *const u16, value: *const u16, flags: u32, ty: *mut u32, data: *mut u8, len: *mut u32) -> i32;
}
// The predefined keys are sign-extended 32-bit values.
const HKEY_CURRENT_USER: isize = 0x8000_0001u32 as i32 as isize;
const HKEY_LOCAL_MACHINE: isize = 0x8000_0002u32 as i32 as isize;
/// REG_SZ; a REG_EXPAND_SZ value comes back expanded.
const RRF_RT_REG_SZ: u32 = 0x2;

/// Ctrl+C and Ctrl+Break are the shell's to handle; vmshell only waits. (A handler, unlike
/// SetConsoleCtrlHandler(NULL, TRUE), is not inherited by the shell.)
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

/// A job that kills the shell when vmshell ends and keeps nothing the shell starts. None if
/// Windows refuses one; the shell then runs without it.
fn own_job() -> Option<Handle> {
    let job = unsafe { CreateJobObjectW(null(), null()) };
    if job.is_null() {
        return None;
    }
    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 144 bytes on x64; BasicLimitInformation.LimitFlags
    // is the u32 at offset 16.
    set_job_flags(job, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK).then_some(job)
}

fn set_job_flags(job: Handle, flags: u32) -> bool {
    let mut info = [0u8; 144];
    info[16..20].copy_from_slice(&flags.to_le_bytes());
    unsafe { SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, info.as_ptr(), 144) != 0 }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// A string value from the registry, expanded.
fn reg_string(root: isize, key: &str, name: &str) -> Option<String> {
    let (key, name) = (wide(key), wide(name));
    let get = |data: *mut u8, len: &mut u32| unsafe {
        RegGetValueW(root as Handle, key.as_ptr(), name.as_ptr(), RRF_RT_REG_SZ, null_mut(), data, len)
    };
    let mut len = 0u32;
    if get(null_mut(), &mut len) != 0 {
        return None;
    }
    let mut buf = vec![0u16; len as usize / 2 + 1];
    len = (buf.len() * 2) as u32;
    if get(buf.as_mut_ptr().cast(), &mut len) != 0 {
        return None;
    }
    buf.truncate(len as usize / 2);
    Some(String::from_utf16_lossy(&buf).trim_end_matches('\0').to_string())
}

/// Path as a new terminal window gets it: the machine's, then the user's, each folder once.
/// sshd's own if the registry cannot be read.
fn session_path() -> String {
    let machine = reg_string(HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment", "Path");
    let Some(machine) = machine else { return std::env::var("Path").unwrap_or_default() };
    let user = reg_string(HKEY_CURRENT_USER, "Environment", "Path").unwrap_or_default();
    let mut seen = std::collections::HashSet::new();
    let dirs: Vec<&str> = machine
        .split(';')
        .chain(user.split(';'))
        .filter(|d| !d.is_empty() && seen.insert(d.to_lowercase()))
        .collect();
    dirs.join(";")
}

/// The command after sshd's `-c`, joined from the arguments as a shell joins what follows -c.
fn command_text() -> Option<String> {
    let a: Vec<String> = std::env::args_os().skip(1).map(|s| s.to_string_lossy().into_owned()).collect();
    let opt = a.first()?.to_ascii_lowercase();
    (a.len() > 1 && (opt == "-c" || opt == "-command")).then(|| a[1..].join(" "))
}

fn stdin_is_terminal() -> bool {
    unsafe { GetFileType(GetStdHandle(STD_INPUT_HANDLE)) == FILE_TYPE_CHAR }
}

/// A script from the client, saved to a file; removed when vmshell ends.
struct Script(std::path::PathBuf);
impl Drop for Script {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn bash() -> Command {
    let mut c = Command::new(format!(r"{GIT}\usr\bin\bash.exe"));
    // What Git's bin\bash.exe sets before it starts this bash.
    let msystem = if std::path::Path::new(&format!(r"{GIT}\ucrt64")).is_dir() { "UCRT64" } else { "MINGW64" };
    let home = std::env::var("USERPROFILE").unwrap_or_default();
    c.env("MSYSTEM", msystem).env("EXEPATH", format!(r"{GIT}\bin")).env("PLINK_PROTOCOL", "ssh");
    let prefix = format!(r"{GIT}\{}\bin;{GIT}\usr\bin;{home}\bin", msystem.to_lowercase());
    c.env("Path", format!("{prefix};{}", session_path()));
    // The lab's setup for every bash, scripts too (win/bash-env.sh: fnm)
    if std::env::var_os("BASH_ENV").is_none() && std::path::Path::new(BASH_ENV).is_file() {
        c.env("BASH_ENV", BASH_ENV.replace('\\', "/"));
    }
    let raw = args_after_program();
    match command_text() {
        Some(text) => {
            // `export -n`: the programs the command starts do not get it.
            c.raw_arg(r#"-c 'export -n VMSHELL_COMMAND; eval "$VMSHELL_COMMAND"'"#).env("VMSHELL_COMMAND", text);
        }
        None if raw.is_empty() && stdin_is_terminal() => {
            c.arg("-l");
        }
        None => {
            c.raw_arg(raw);
        }
    }
    c
}

/// Appended to every pwsh script and command: the exit code of its last statement (`$?` still
/// describes it here). pwsh then exits with SetShouldExit, not `exit`: `exit` would end pwsh
/// before a table still being laid out, and all output after it, is written.
const EXIT_CHECK: &str = "\n$global:vmshellExit = if ($?) { 0 } elseif ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }";

fn save_script(text: &[u8]) -> Option<Script> {
    let path = std::env::temp_dir().join(format!("vmshell-{}.ps1", std::process::id()));
    std::fs::write(&path, [text, EXIT_CHECK.as_bytes()].concat()).ok()?;
    Some(Script(path))
}

/// Runs a saved script. If it did not reach its end: the code of its `exit`, else 1 (an error
/// kept it from running). $LASTEXITCODE is cleared first: the profile may have run a program.
fn run_file(s: &Script, mode: &str) -> String {
    format!(
        "-NoLogo {mode}-Command \"$global:LASTEXITCODE = $null; & '{}'; $host.SetShouldExit($(if ($null -ne $vmshellExit) {{ $vmshellExit }} elseif ($null -ne $LASTEXITCODE) {{ $LASTEXITCODE }} else {{ 1 }}))\"",
        s.0.display()
    )
}

/// -EncodedCommand's argument: base64 of the UTF-16LE text.
fn encoded(text: &str) -> String {
    const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes: Vec<u8> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = c.iter().enumerate().fold(0u32, |n, (i, &b)| n | (b as u32) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= c.len() { B64[(n >> (18 - 6 * i) & 63) as usize] as char } else { '=' });
        }
    }
    out
}

/// pwsh, and the saved script it runs if any (kept until pwsh ends).
fn pwsh() -> (Command, Option<Script>) {
    let mut c = Command::new(PWSH);
    c.env("Path", session_path());
    let raw = args_after_program();
    let mut script = None;
    if raw.is_empty() && !stdin_is_terminal() {
        // A script on stdin; it runs without input.
        let mut text = Vec::new();
        if std::io::Read::read_to_end(&mut std::io::stdin(), &mut text).is_ok() {
            script = save_script(&text);
        }
        match &script {
            Some(s) => c.raw_arg(run_file(s, "-NonInteractive ")).stdin(Stdio::null()),
            None => c.raw_arg(raw),
        };
    } else if let Some(text) = command_text() {
        // A command keeps the client's stdin and terminal. One too long for a command line once
        // encoded (32767 characters) runs from a file.
        let e = encoded(&format!("{text}{EXIT_CHECK}; $host.SetShouldExit($vmshellExit)"));
        if e.len() < 32000 {
            c.raw_arg(format!("-NoLogo -OutputFormat Text -EncodedCommand {e}")); // Text: errors not as CLIXML
        } else if let Some(s) = save_script(text.as_bytes()) {
            c.raw_arg(run_file(&s, ""));
            script = Some(s);
        }
    } else {
        c.raw_arg(raw);
    }
    (c, script)
}

/// Copies the shell's output to ours until the shell has ended and its pipes are empty, and
/// our stdin to the shell's (when it has a pipe for it). Returns the shell's exit code.
fn relay(mut child: Child) -> i32 {
    if let Some(mut to_shell) = child.stdin.take() {
        std::thread::spawn(move || {
            let _ = std::io::copy(&mut std::io::stdin().lock(), &mut to_shell);
        });
    }
    let pipes = [
        child.stdout.take().map(|p| (p.into_raw_handle(), false)),
        child.stderr.take().map(|p| (p.into_raw_handle(), true)),
    ];
    let mut copies = Vec::new();
    for (handle, is_err) in pipes.into_iter().flatten() {
        let pipe = Arc::new(unsafe { std::fs::File::from_raw_handle(handle) });
        // The writer is a thread of its own and writes to a different handle, so the cancel at the
        // end never cuts a write.
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let writer = std::thread::spawn(move || {
            for chunk in rx {
                let ok = if is_err {
                    std::io::stderr().write_all(&chunk).and_then(|_| std::io::stderr().flush())
                } else {
                    std::io::stdout().write_all(&chunk).and_then(|_| std::io::stdout().flush())
                };
                if ok.is_err() {
                    break; // the client is gone
                }
            }
        });
        let p = pipe.clone();
        let reader = std::thread::spawn(move || loop {
            let mut buf = vec![0u8; 64 * 1024];
            match (&*p).read(&mut buf) {
                Ok(0) | Err(_) => break, // every writer closed it, or the read was cancelled
                Ok(n) => {
                    buf.truncate(n);
                    if tx.send(buf).is_err() {
                        break;
                    }
                }
            }
        });
        copies.push((pipe, reader, writer));
    }
    let code = match child.wait() {
        Ok(st) => st.code().unwrap_or(1),
        Err(_) => 1,
    };
    // The shell has ended, so all it wrote is in the pipes; programs it left running may keep
    // them open. Read until a pipe is empty, then cancel the read that waits on it (Rust's end
    // of the pipe is overlapped, so CancelIoEx, not CancelSynchronousIo).
    for (pipe, reader, writer) in copies {
        while !reader.is_finished() {
            let mut avail = 0u32;
            let ok = unsafe { PeekNamedPipe(pipe.as_raw_handle(), null_mut(), 0, null_mut(), &mut avail, null_mut()) };
            if ok == 0 || avail == 0 {
                unsafe { CancelIoEx(pipe.as_raw_handle(), null_mut()) };
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let _ = reader.join();
        let _ = writer.join();
    }
    code
}

fn main() {
    unsafe { SetConsoleCtrlHandler(Some(ignore), 1) };
    // A subsystem: sshd starts sftp-server through the shell (`-c sftp-server.exe`). It is no
    // shell session, and it stalls on pipes other than sshd's: run it as is, with sshd's.
    if let Some(c) = command_text().filter(|c| c.trim().to_ascii_lowercase().ends_with("sftp-server.exe")) {
        let code = Command::new(c.trim()).status().ok().and_then(|st| st.code()).unwrap_or(1);
        exit(code)
    }
    let want_pwsh = std::env::var("VMLAB_SHELL").is_ok_and(|s| s.eq_ignore_ascii_case("pwsh"));
    let (mut cmd, script) = if want_pwsh { pwsh() } else { (bash(), None) };
    let program = if want_pwsh { PWSH } else { "Git Bash" };
    cmd.env_remove("VMLAB_SHELL");
    // Without a terminal, vmshell's own pipes (see the top). A pwsh script from stdin has its
    // stdin set to nothing already.
    let terminal = stdin_is_terminal();
    if !terminal {
        // sshd's pipes came to vmshell inheritable; the shell would pass them on to every
        // program it starts.
        for which in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
            unsafe { SetHandleInformation(GetStdHandle(which), HANDLE_FLAG_INHERIT, 0) };
        }
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        if script.is_none() || !want_pwsh || !args_after_program().is_empty() {
            cmd.stdin(Stdio::piped());
        }
    }
    let job = own_job();
    let parent = parent_process();
    // Without a terminal, a console of its own (no window): the session's console goes away
    // with the session, and with it a program the shell had only just started.
    let console = if terminal { 0 } else { CREATE_NO_WINDOW };

    // Leave sshd's job. Outside a job, or in one that forbids it, start the shell where we are.
    let (child, suspended) = match cmd.creation_flags(CREATE_BREAKAWAY_FROM_JOB | CREATE_SUSPENDED | console).spawn() {
        Ok(c) => (c, true),
        Err(_) => match cmd.creation_flags(console).spawn() {
            Ok(c) => (c, false),
            Err(e) => {
                eprintln!("vmshell: cannot start {program}: {e}");
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
    // The connection dropped: end the shell and what it runs (its process tree; the job would
    // hold only the shell, and Windows has no SIGPIPE to stop a program whose output has no
    // reader any more). A Git Bash program that bash runs by exec (sleep, grep) leaves the tree,
    // as Cygwin's exec ends the process it replaces, and Cygwin does give it SIGPIPE: it ends at
    // its next write, as on Linux. A shell that could not leave sshd's job is in that one,
    // which ends it.
    // Handles go to the thread as numbers; they live as long as vmshell.
    let shell_done = Arc::new(AtomicBool::new(false));
    if let (true, Some(job), Some(parent)) = (suspended, job, parent) {
        let (job, parent, done, pid) = (job as usize, parent as usize, shell_done.clone(), child.id());
        std::thread::spawn(move || unsafe {
            WaitForSingleObject(parent as Handle, INFINITE);
            if !done.load(Ordering::SeqCst) {
                let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
                let _ = Command::new(format!(r"{root}\System32\taskkill.exe"))
                    .args(["/T", "/F", "/PID", &pid.to_string()])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .creation_flags(CREATE_NO_WINDOW)
                    .status();
                TerminateJobObject(job as Handle, 1);
            }
        });
    }
    let code = if terminal {
        let mut child = child;
        child.wait().ok().and_then(|st| st.code()).unwrap_or(1)
    } else {
        relay(child)
    };
    shell_done.store(true, Ordering::SeqCst);
    // The shell ended by itself, so nothing is left to end with it. A program it started just
    // before it ended can still be in the job for a moment (Git Bash moves its processes to a
    // job of its own once started): closing the job must not kill it.
    if let Some(job) = job {
        set_job_flags(job, JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK);
    }
    drop(script);
    exit(code)
}
