//! vmlab-agent: the Windows VM's end of the vsock control channel (see lib.rs for the protocol).
//!
//! It runs in dev's desktop session with admin rights, started at logon as sshd is
//! (win/vsock-agent.ps1), so what it starts runs where `ssh win` runs it: commands go through
//! the same `C:\vmlab\vmshell.exe -c`, which gives them Git Bash (or pwsh), the lab's
//! environment, and a life outside the connection.
//!
//! The socket: viosock.sys (virtio-win) with its Winsock provider. Its address family has no
//! fixed number on Windows: the driver's `\\.\Viosock` device says which (IOCTL_GET_AF). An
//! accepted socket is wrapped in std's TcpStream, whose reads and writes are plain recv and
//! send, which the provider serves for any stream socket.

#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(not(windows))]
fn main() {
    eprintln!("vmlab-agent runs in the Windows VM");
    std::process::exit(2);
}

#[cfg(windows)]
fn main() {
    agent::main()
}

#[cfg(windows)]
mod agent {
    use std::ffi::c_void;
    use std::io::{Read, Write};
    use std::net::{Shutdown, TcpStream};
    use std::os::windows::io::{FromRawSocket, RawSocket};
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::ptr::null_mut;
    use std::sync::{Arc, Mutex};

    use vmlab_vsock::*;

    const VMSHELL: &str = r"C:\vmlab\vmshell.exe";
    const TOKEN_FILE: &str = r"C:\vmlab\agent-token";
    const LOG: &str = r"C:\vmlab\agent.log";

    type Handle = *mut c_void;
    type Socket = usize;
    const INVALID_SOCKET: Socket = !0;
    const INVALID_HANDLE_VALUE: Handle = -1isize as Handle;
    const GENERIC_READ: u32 = 0x8000_0000;
    const FILE_SHARE_READ: u32 = 1;
    const OPEN_EXISTING: u32 = 3;
    const IOCTL_GET_AF: u32 = 0x0801_300C;
    const SOCK_STREAM: i32 = 1;
    const VMADDR_CID_ANY: u32 = u32::MAX;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    #[repr(C)]
    struct SockAddrVm {
        family: u16,
        reserved: u16,
        port: u32,
        cid: u32,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateFileW(name: *const u16, access: u32, share: u32, sa: *mut c_void, disp: u32, flags: u32, tmpl: Handle) -> Handle;
        fn DeviceIoControl(h: Handle, code: u32, inb: *mut c_void, insz: u32, outb: *mut c_void, outsz: u32, ret: *mut u32, ov: *mut c_void) -> i32;
        fn CloseHandle(h: Handle) -> i32;
        fn GetLastError() -> u32;
    }

    #[link(name = "ws2_32")]
    extern "system" {
        fn WSAStartup(ver: u16, data: *mut u8) -> i32;
        fn WSAGetLastError() -> i32;
        fn socket(af: i32, ty: i32, proto: i32) -> Socket;
        fn bind(s: Socket, addr: *const SockAddrVm, len: i32) -> i32;
        fn listen(s: Socket, backlog: i32) -> i32;
        fn accept(s: Socket, addr: *mut SockAddrVm, len: *mut i32) -> Socket;
        fn closesocket(s: Socket) -> i32;
    }

    fn log(msg: &str) {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(LOG) {
            let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let _ = writeln!(f, "{t} {msg}");
        }
    }

    fn fail(msg: String) -> ! {
        log(&msg);
        std::process::exit(1)
    }

    /// viosock's address family (it varies: the Winsock provider gets one when installed).
    fn address_family() -> Result<i32, String> {
        let path: Vec<u16> = r"\\.\Viosock".encode_utf16().chain([0]).collect();
        let h = unsafe { CreateFileW(path.as_ptr(), GENERIC_READ, FILE_SHARE_READ, null_mut(), OPEN_EXISTING, 0, null_mut()) };
        if h == INVALID_HANDLE_VALUE {
            return Err(format!("no viosock device (\\\\.\\Viosock, error {}): is the driver installed and the VM started with vhost-vsock-pci?", unsafe { GetLastError() }));
        }
        let (mut af, mut got) = (0u32, 0u32);
        let ok = unsafe { DeviceIoControl(h, IOCTL_GET_AF, null_mut(), 0, &mut af as *mut u32 as *mut c_void, 4, &mut got, null_mut()) };
        unsafe { CloseHandle(h) };
        if ok == 0 || af == 0 {
            return Err(format!("IOCTL_GET_AF failed (error {})", unsafe { GetLastError() }));
        }
        Ok(af as i32)
    }

    pub fn main() {
        // The log stays small: started afresh past 1 MB.
        if std::fs::metadata(LOG).is_ok_and(|m| m.len() > 1 << 20) {
            let _ = std::fs::remove_file(LOG);
        }
        let token = std::fs::read_to_string(TOKEN_FILE)
            .map_err(|e| format!("{TOKEN_FILE}: {e}"))
            .and_then(|t| parse_token(&t).map_err(|e| format!("{TOKEN_FILE}: {e}")))
            .unwrap_or_else(|e| fail(e));
        let mut wsa = [0u8; 512];
        if unsafe { WSAStartup(0x0202, wsa.as_mut_ptr()) } != 0 {
            fail("WSAStartup failed".into());
        }
        // Without the device (the VM was started without vhost-vsock-pci) wait for it, quietly:
        // the logon task's loop would otherwise start the agent again every few seconds.
        let af = loop {
            match address_family() {
                Ok(af) => break af,
                Err(e) => {
                    static ONCE: std::sync::Once = std::sync::Once::new();
                    ONCE.call_once(|| log(&format!("{e}; waiting for it")));
                    std::thread::sleep(std::time::Duration::from_secs(10));
                }
            }
        };
        let srv = unsafe { socket(af, SOCK_STREAM, 0) };
        if srv == INVALID_SOCKET {
            fail(format!("socket(af {af}) failed: {}", unsafe { WSAGetLastError() }));
        }
        let addr = SockAddrVm { family: af as u16, reserved: 0, port: PORT, cid: VMADDR_CID_ANY };
        if unsafe { bind(srv, &addr, std::mem::size_of::<SockAddrVm>() as i32) } != 0 {
            // Most likely another agent has the port: wait before the loop starts one again.
            let e = unsafe { WSAGetLastError() };
            log(&format!("bind to vsock port {PORT} failed: {e} (another agent running?); retrying in a minute"));
            std::thread::sleep(std::time::Duration::from_secs(60));
            std::process::exit(1);
        }
        if unsafe { listen(srv, 64) } != 0 {
            fail(format!("listen failed: {}", unsafe { WSAGetLastError() }));
        }
        log(&format!("listening on vsock port {PORT} (address family {af})"));
        let token = Arc::new(token);
        loop {
            let mut peer = SockAddrVm { family: 0, reserved: 0, port: 0, cid: 0 };
            let mut len = std::mem::size_of::<SockAddrVm>() as i32;
            let s = unsafe { accept(srv, &mut peer, &mut len) };
            if s == INVALID_SOCKET {
                std::thread::sleep(std::time::Duration::from_millis(50));
                continue;
            }
            // Only the host. (The guest itself, or a second VM, would have another CID.)
            if peer.cid != HOST_CID {
                log(&format!("refused a connection from CID {}", peer.cid));
                unsafe { closesocket(s) };
                continue;
            }
            let stream = unsafe { TcpStream::from_raw_socket(s as RawSocket) };
            let token = token.clone();
            std::thread::spawn(move || {
                if let Err(e) = serve(stream, &token) {
                    log(&format!("request ended: {e}"));
                }
            });
        }
    }

    fn serve(mut s: TcpStream, token: &[u8; TOKEN_LEN]) -> Result<(), String> {
        let op = match read_hello(&mut s, token) {
            Ok(op) => op,
            Err(e) => {
                let _ = write_status(&mut s, Some(&e));
                return Err(e);
            }
        };
        let io = |e: std::io::Error| e.to_string();
        match op {
            OP_PING => {
                write_status(&mut s, None).map_err(io)?;
                write_str(&mut s, concat!("vmlab-agent ", env!("CARGO_PKG_VERSION"))).map_err(io)
            }
            OP_EXEC => exec(s),
            OP_PUT => put(s),
            OP_GET => get(s),
            OP_CONNECT => connect(s),
            other => write_status(&mut s, Some(&format!("unknown op {other}"))).map_err(io),
        }
    }

    /// A command through vmshell, as sshd starts one: `vmshell.exe -c <command>`, VMLAB_SHELL=pwsh
    /// for PowerShell.
    fn exec(mut s: TcpStream) -> Result<(), String> {
        let io = |e: std::io::Error| e.to_string();
        let flags = read_u8(&mut s).map_err(io)?;
        let command = read_str(&mut s).map_err(io)?;
        let mut cmd = Command::new(VMSHELL);
        // One argument after -c, quoted by the rules vmshell's argv is split with (std's
        // quoting): vmshell gets the command exactly as sent.
        if flags & FLAG_COMMAND != 0 {
            cmd.arg("-c").arg(&command);
        }
        if flags & FLAG_PWSH != 0 {
            cmd.env("VMLAB_SHELL", "pwsh");
        }
        // In the home folder, where sshd starts a session.
        if let Some(home) = std::env::var_os("USERPROFILE") {
            cmd.current_dir(home);
        }
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW);
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => return write_status(&mut s, Some(&format!("cannot start {VMSHELL}: {e}"))).map_err(io),
        };
        write_status(&mut s, None).map_err(io)?;
        let pid = child.id();
        // One socket for every thread: viosock's provider cannot duplicate one (try_clone fails
        // with WSAEOPNOTSUPP), and &TcpStream reads and writes. Frames are written whole under
        // the lock.
        let sock = Arc::new(s);
        let out = Arc::new(Mutex::new(()));
        let send = move |sock: &TcpStream, out: &Mutex<()>, kind: u8, data: &[u8]| {
            let _g = out.lock().unwrap();
            let mut w = sock;
            write_frame(&mut w, kind, data)
        };
        let relay = |mut r: Box<dyn Read + Send>, kind: u8| {
            let (sock, out) = (sock.clone(), out.clone());
            std::thread::spawn(move || {
                let mut buf = vec![0u8; 64 << 10];
                while let Ok(n) = r.read(&mut buf) {
                    if n == 0 || send(&sock, &out, kind, &buf[..n]).is_err() {
                        break;
                    }
                }
            })
        };
        let t_out = relay(Box::new(child.stdout.take().unwrap()), STDOUT);
        let t_err = relay(Box::new(child.stderr.take().unwrap()), STDERR);
        // The host's side: stdin, then its EOF. The stream ending while the command runs means
        // the host went away: its process tree ends (and vmshell's job ends the shell).
        let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let mut stdin = child.stdin.take();
        let reader = sock.clone();
        let finished = done.clone();
        std::thread::spawn(move || loop {
            let mut r: &TcpStream = &reader;
            match read_frame(&mut r) {
                Ok(Some((STDIN, data))) => {
                    if let Some(w) = stdin.as_mut() {
                        if w.write_all(&data).is_err() {
                            stdin = None;
                        }
                    }
                }
                Ok(Some((STDIN_EOF, _))) => stdin = None,
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => {
                    if !finished.load(std::sync::atomic::Ordering::SeqCst) {
                        kill_tree(pid);
                    }
                    return;
                }
            }
        });
        let status = child.wait().map_err(io)?;
        done.store(true, std::sync::atomic::Ordering::SeqCst);
        let _ = t_out.join();
        let _ = t_err.join();
        let code = status.code().unwrap_or(1);
        let _ = send(&sock, &out, EXIT, &code.to_le_bytes());
        let _ = sock.shutdown(Shutdown::Write);
        Ok(())
    }

    fn kill_tree(pid: u32) {
        let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        let _ = Command::new(format!(r"{root}\System32\taskkill.exe"))
            .args(["/T", "/F", "/PID", &pid.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .status();
    }

    fn put(mut s: TcpStream) -> Result<(), String> {
        let io = |e: std::io::Error| e.to_string();
        let path = std::path::PathBuf::from(read_str(&mut s).map_err(io)?);
        let size = read_u64(&mut s).map_err(io)?;
        let part = path.with_extension(format!(
            "{}vmlab-part",
            path.extension().map(|e| format!("{}.", e.to_string_lossy())).unwrap_or_default()
        ));
        let result = (|| -> std::io::Result<()> {
            if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
                std::fs::create_dir_all(dir)?;
            }
            let mut f = std::io::BufWriter::with_capacity(1 << 20, std::fs::File::create(&part)?);
            let n = pump(&mut (&mut s).take(size), &mut f)?;
            if n != size {
                return Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, format!("got {n} of {size} bytes")));
            }
            f.flush()?;
            drop(f);
            std::fs::rename(&part, &path)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&part);
        }
        let e = result.err().map(|e| format!("{}: {e}", path.display()));
        write_status(&mut s, e.as_deref()).map_err(io)
    }

    fn get(mut s: TcpStream) -> Result<(), String> {
        let io = |e: std::io::Error| e.to_string();
        let path = read_str(&mut s).map_err(io)?;
        let mut f = match std::fs::File::open(&path) {
            Ok(f) => f,
            Err(e) => return write_status(&mut s, Some(&format!("{path}: {e}"))).map_err(io),
        };
        let size = f.metadata().map_err(io)?.len();
        write_status(&mut s, None).map_err(io)?;
        s.write_all(&size.to_le_bytes()).map_err(io)?;
        pump(&mut (&mut f).take(size), &mut s).map_err(io)?;
        Ok(())
    }

    /// Splice the stream to a TCP port of the guest's own (SSH over vsock).
    fn connect(mut s: TcpStream) -> Result<(), String> {
        let io = |e: std::io::Error| e.to_string();
        let port = read_u16(&mut s).map_err(io)?;
        let t = match TcpStream::connect(("127.0.0.1", port)) {
            Ok(t) => t,
            Err(e) => return write_status(&mut s, Some(&format!("127.0.0.1:{port} in the VM: {e}"))).map_err(io),
        };
        let _ = t.set_nodelay(true);
        write_status(&mut s, None).map_err(io)?;
        // Shared, not cloned (see exec).
        let (s, t) = (Arc::new(s), Arc::new(t));
        let (s2, t2) = (s.clone(), t.clone());
        let up = std::thread::spawn(move || {
            let _ = pump(&mut &*s2, &mut &*t2);
            let _ = t2.shutdown(Shutdown::Write);
        });
        let _ = pump(&mut &*t, &mut &*s);
        let _ = s.shutdown(Shutdown::Write);
        let _ = up.join();
        Ok(())
    }
}
