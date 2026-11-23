//! vmlab-vx: the host's end of the vsock control channel to the Windows VM (lib.rs has the
//! protocol, vmlab-agent.rs the other end).
//!
//!   vmlab-vx ping                         the agent's name and version
//!   vmlab-vx exec [--pwsh] [COMMAND...]   as `ssh win "COMMAND"` (`ssh win-pwsh` with --pwsh):
//!                                         Git Bash, stdin passed on, the command's exit code;
//!                                         no COMMAND: stdin is the script
//!   vmlab-vx put LOCAL REMOTE             a file into the VM (REMOTE: a Windows path)
//!   vmlab-vx get REMOTE LOCAL             a file out of it (LOCAL "-": stdout)
//!   vmlab-vx proxy PORT                   stdin and stdout to 127.0.0.1:PORT in the VM, for
//!                                         ssh's ProxyCommand
//!
//! When the agent does not answer (a VM state from before it, a VM started without vsock),
//! `exec` runs `ssh win` (or `ssh win-pwsh`) in its place, and `proxy` connects to
//! `--fallback HOST:PORT`, so callers work either way; VMLAB_VX_FALLBACK=0 turns that off.
//! Exit code 255: the channel failed (as ssh's).
//!
//! VMLAB_VSOCK_CID (default 3) is the VM's CID; the token is read from
//! ~/.config/vmlab/agent-token (VMLAB_AGENT_TOKEN_FILE).

#[cfg(not(unix))]
fn main() {
    eprintln!("vmlab-vx runs on the Linux host");
    std::process::exit(2);
}

#[cfg(unix)]
fn main() {
    host::main()
}

#[cfg(unix)]
mod host {
    use std::io::{self, Read, Write};
    use std::os::fd::FromRawFd;
    use std::os::unix::net::UnixStream;
    use std::os::unix::process::CommandExt;
    use std::process::exit;

    use vmlab_vsock::*;

    fn die(msg: impl std::fmt::Display) -> ! {
        eprintln!("vmlab-vx: {msg}");
        exit(255)
    }

    fn usage() -> ! {
        eprintln!(
            "usage: vmlab-vx ping | exec [--pwsh] [COMMAND...] | put LOCAL REMOTE | get REMOTE LOCAL | proxy PORT [--fallback HOST:PORT]"
        );
        exit(2)
    }

    fn token() -> Result<[u8; TOKEN_LEN], String> {
        let path = std::env::var_os("VMLAB_AGENT_TOKEN_FILE").map(std::path::PathBuf::from).unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config/vmlab/agent-token")
        });
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        parse_token(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    fn cid() -> u32 {
        std::env::var("VMLAB_VSOCK_CID").ok().and_then(|s| s.parse().ok()).unwrap_or(WIN_CID)
    }

    /// The QEMU process of the VM now running, from its pid file: what a "no agent" note is for.
    fn qemu_pid() -> Option<String> {
        let f = std::env::var("VMLAB_VSOCK_PIDFILE").unwrap_or_else(|_| "/vmlab/run/win-venus/qemu.pid".into());
        std::fs::read_to_string(f).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
    }

    /// Where a connect that timed out is noted (the VM has no vsock driver or no device): later
    /// calls to the same QEMU process go to the fallback at once.
    fn no_agent_note() -> std::path::PathBuf {
        let dir = std::env::var_os("XDG_RUNTIME_DIR").unwrap_or_else(|| "/tmp".into());
        std::path::PathBuf::from(dir).join(format!("vmlab-vx-noagent-{}", cid()))
    }

    /// A vsock stream to the agent. A guest without the driver never answers, so the wait is
    /// short: 500 ms (a guest with it answers in under a millisecond, busy or not).
    fn dial() -> io::Result<UnixStream> {
        let pid = qemu_pid();
        if pid.is_some() && std::fs::read_to_string(no_agent_note()).ok().map(|s| s.trim().to_string()) == pid {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "no answer earlier in this VM run"));
        }
        let r = dial_once();
        if let (Err(e), Some(pid)) = (&r, pid) {
            if e.raw_os_error() == Some(libc::ETIMEDOUT) {
                let _ = std::fs::write(no_agent_note(), pid);
            }
        }
        r
    }

    fn dial_once() -> io::Result<UnixStream> {
        unsafe {
            let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let s = UnixStream::from_raw_fd(fd);
            let tv = libc::timeval { tv_sec: 0, tv_usec: 500_000 };
            // SO_VM_SOCKETS_CONNECT_TIMEOUT (linux/vm_sockets.h; the old timeval form)
            libc::setsockopt(fd, libc::AF_VSOCK, 6, &tv as *const _ as *const libc::c_void, std::mem::size_of_val(&tv) as u32);
            let mut addr: libc::sockaddr_vm = std::mem::zeroed();
            addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
            addr.svm_port = PORT;
            addr.svm_cid = cid();
            let rc = libc::connect(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_vm>() as u32);
            if rc != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(s)
        }
    }

    /// Connect and send the opening; Err if the agent cannot be reached or refuses.
    fn open(op: u8) -> Result<UnixStream, String> {
        let token = token()?;
        let mut s = dial().map_err(|e| format!("no agent at vsock CID {} port {PORT}: {e}", cid()))?;
        write_hello(&mut s, &token, op).map_err(|e| format!("agent: {e}"))?;
        Ok(s)
    }

    fn fallback_allowed() -> bool {
        std::env::var("VMLAB_VX_FALLBACK").map_or(true, |v| v != "0")
    }

    pub fn main() {
        let args: Vec<String> = std::env::args().skip(1).collect();
        let Some(verb) = args.first() else { usage() };
        let rest = &args[1..];
        match verb.as_str() {
            "ping" => ping(),
            "exec" => exec(rest),
            "put" if rest.len() == 2 => put(&rest[0], &rest[1]),
            "get" if rest.len() == 2 => get(&rest[0], &rest[1]),
            "proxy" => proxy(rest),
            _ => usage(),
        }
    }

    fn ping() {
        let t = std::time::Instant::now();
        let mut s = open(OP_PING).unwrap_or_else(|e| die(e));
        match read_status(&mut s) {
            Ok(Ok(())) => {}
            Ok(Err(e)) => die(format!("agent: {e}")),
            Err(e) => die(format!("agent: {e}")),
        }
        let name = read_str(&mut s).unwrap_or_else(|e| die(e));
        println!("{name}, {:.2} ms", t.elapsed().as_secs_f64() * 1000.0);
    }

    fn exec(rest: &[String]) {
        let pwsh = rest.first().is_some_and(|a| a == "--pwsh");
        let words = &rest[pwsh as usize..];
        let words = if words.first().is_some_and(|a| a == "--") { &words[1..] } else { words };
        let command = words.join(" ");
        let has_command = !words.is_empty();
        let mut s = match open(OP_EXEC) {
            Ok(s) => s,
            Err(e) if fallback_allowed() => {
                // Nothing of stdin has been read: ssh gets all of it.
                let host = if pwsh { "win-pwsh" } else { "win" };
                let mut ssh = std::process::Command::new("ssh");
                ssh.arg(host);
                if has_command {
                    ssh.arg(&command);
                }
                if std::env::var_os("VMLAB_VX_QUIET").is_none() {
                    eprintln!("vmlab-vx: {e}; using ssh {host}");
                }
                die(ssh.exec())
            }
            Err(e) => die(e),
        };
        let mut head = Vec::new();
        head.push(if pwsh { FLAG_PWSH } else { 0 } | if has_command { FLAG_COMMAND } else { 0 });
        write_str(&mut head, &command).unwrap();
        s.write_all(&head).unwrap_or_else(|e| die(format!("agent: {e}")));
        match read_status(&mut s) {
            Ok(Ok(())) => {}
            Ok(Err(e)) => die(format!("agent: {e}")),
            Err(e) => die(format!("agent: {e}")),
        }
        let mut up = s.try_clone().unwrap_or_else(|e| die(e));
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 64 << 10];
            let mut stdin = io::stdin().lock();
            loop {
                match stdin.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if write_frame(&mut up, STDIN, &buf[..n]).is_err() {
                            return;
                        }
                    }
                }
            }
            let _ = write_frame(&mut up, STDIN_EOF, &[]);
        });
        let (mut out, mut err) = (io::stdout().lock(), io::stderr().lock());
        loop {
            match read_frame(&mut s) {
                Ok(Some((STDOUT, d))) => {
                    let _ = out.write_all(&d).and_then(|_| out.flush());
                }
                Ok(Some((STDERR, d))) => {
                    let _ = err.write_all(&d).and_then(|_| err.flush());
                }
                Ok(Some((EXIT, d))) if d.len() == 4 => exit(i32::from_le_bytes(d.try_into().unwrap())),
                Ok(Some(_)) => {}
                Ok(None) => die("the agent closed the connection before the command ended"),
                Err(e) => die(format!("lost the connection to the agent: {e}")),
            }
        }
    }

    fn put(local: &str, remote: &str) {
        let mut f = std::fs::File::open(local).unwrap_or_else(|e| die(format!("{local}: {e}")));
        let size = f.metadata().unwrap_or_else(|e| die(e)).len();
        let mut s = open(OP_PUT).unwrap_or_else(|e| die(e));
        let mut head = Vec::new();
        write_str(&mut head, remote).unwrap();
        head.extend_from_slice(&size.to_le_bytes());
        s.write_all(&head).unwrap_or_else(|e| die(format!("agent: {e}")));
        pump(&mut (&mut f).take(size), &mut s).unwrap_or_else(|e| die(format!("sending {local}: {e}")));
        match read_status(&mut s) {
            Ok(Ok(())) => {}
            Ok(Err(e)) => die(e),
            Err(e) => die(format!("agent: {e}")),
        }
    }

    fn get(remote: &str, local: &str) {
        let mut s = open(OP_GET).unwrap_or_else(|e| die(e));
        let mut head = Vec::new();
        write_str(&mut head, remote).unwrap();
        s.write_all(&head).unwrap_or_else(|e| die(format!("agent: {e}")));
        match read_status(&mut s) {
            Ok(Ok(())) => {}
            Ok(Err(e)) => die(e),
            Err(e) => die(format!("agent: {e}")),
        }
        let size = read_u64(&mut s).unwrap_or_else(|e| die(format!("agent: {e}")));
        if local == "-" {
            let n = pump(&mut (&mut s).take(size), &mut io::stdout().lock()).unwrap_or_else(|e| die(e));
            if n != size {
                die(format!("got {n} of {size} bytes"));
            }
            return;
        }
        let part = format!("{local}.vmlab-part");
        let mut f = io::BufWriter::with_capacity(1 << 20, std::fs::File::create(&part).unwrap_or_else(|e| die(format!("{part}: {e}"))));
        let n = pump(&mut (&mut s).take(size), &mut f).unwrap_or_else(|e| die(e));
        if n != size {
            let _ = std::fs::remove_file(&part);
            die(format!("got {n} of {size} bytes"));
        }
        f.flush().unwrap_or_else(|e| die(e));
        std::fs::rename(&part, local).unwrap_or_else(|e| die(format!("{local}: {e}")));
    }

    /// stdin and stdout to the VM's 127.0.0.1:PORT over vsock (or to the fallback over TCP).
    fn proxy(rest: &[String]) {
        let Some(port) = rest.first().and_then(|p| p.parse::<u16>().ok()) else { usage() };
        let fallback = match rest.get(1).map(String::as_str) {
            Some("--fallback") => Some(rest.get(2).cloned().unwrap_or_else(|| usage())),
            Some(_) => usage(),
            None => None,
        };
        let via_vsock = open(OP_CONNECT).and_then(|mut s| {
            s.write_all(&port.to_le_bytes()).map_err(|e| format!("agent: {e}"))?;
            match read_status(&mut s) {
                Ok(Ok(())) => Ok(s),
                Ok(Err(e)) => Err(format!("agent: {e}")),
                Err(e) => Err(format!("agent: {e}")),
            }
        });
        let (mut down, mut up): (Box<dyn Read + Send>, Box<dyn Write + Send>);
        let close_up: Box<dyn Fn() + Send>;
        match via_vsock {
            Ok(s) => {
                let w = s.try_clone().unwrap_or_else(|e| die(e));
                let w2 = s.try_clone().unwrap_or_else(|e| die(e));
                close_up = Box::new(move || {
                    let _ = w2.shutdown(std::net::Shutdown::Write);
                });
                (down, up) = (Box::new(s), Box::new(w));
            }
            Err(e) => {
                let Some(addr) = fallback.filter(|_| fallback_allowed()) else { die(e) };
                let t = std::net::TcpStream::connect(&addr).unwrap_or_else(|e2| die(format!("{e}; {addr}: {e2}")));
                let _ = t.set_nodelay(true);
                let w = t.try_clone().unwrap_or_else(|e| die(e));
                let w2 = t.try_clone().unwrap_or_else(|e| die(e));
                close_up = Box::new(move || {
                    let _ = w2.shutdown(std::net::Shutdown::Write);
                });
                (down, up) = (Box::new(t), Box::new(w));
            }
        }
        std::thread::spawn(move || {
            let _ = pump(&mut io::stdin().lock(), &mut up);
            close_up();
        });
        // ssh reads its ProxyCommand's stdout unbuffered: write each read through at once.
        let mut out = io::stdout().lock();
        let mut buf = vec![0u8; 256 << 10];
        loop {
            match down.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out.write_all(&buf[..n]).and_then(|_| out.flush()).is_err() {
                        break;
                    }
                }
            }
        }
        exit(0)
    }
}
