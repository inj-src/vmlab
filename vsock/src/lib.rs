//! The protocol between `vmlab-vx` (host) and `vmlab-agent` (the Windows VM), over one
//! virtio-vsock stream per request. Little-endian throughout.
//!
//! Request: `VMLA`, version (u8), the token (32 bytes), the op (u8), then the op's header.
//! Answer: a status byte, 0 for yes; otherwise a string (why) and the stream ends. Then:
//!
//! - `PING`: a string, the agent's name and version.
//! - `EXEC` (header: flags u8, command string): the command runs as `ssh win "<command>"` runs
//!   it, through `C:\vmlab\vmshell.exe -c` (Git Bash, or pwsh with `FLAG_PWSH`); without
//!   `FLAG_COMMAND`, stdin is the script. Frames follow both ways: the host sends `STDIN` and
//!   one `STDIN_EOF`; the agent sends `STDOUT`, `STDERR` and last `EXIT` (i32). If the host
//!   goes away first, the agent ends the command's process tree.
//! - `PUT` (header: path string, size u64, then that many bytes): written beside the path and
//!   renamed over it; folders are made. Then a status byte (and a string if not 0).
//! - `GET` (header: path string): status, then size u64 and the bytes.
//! - `CONNECT` (header: port u16): a TCP connection to 127.0.0.1:port in the guest, spliced to
//!   this stream both ways (SSH over vsock: `vmlab-vx proxy 22`).
//!
//! The token is the trust: the agent takes requests only from the host (CID 2) and only with
//! the token, a copy of `~/.config/vmlab/agent-token` (64 hex digits) at
//! `C:\vmlab\agent-token`. Anyone who can read the host's copy can run anything in the VM,
//! as anyone with the lab's SSH key can.

use std::io::{self, Read, Write};

pub const MAGIC: &[u8; 4] = b"VMLA";
pub const VERSION: u8 = 1;
/// The agent's vsock port.
pub const PORT: u32 = 5150;
/// The host's CID: the only peer the agent answers.
pub const HOST_CID: u32 = 2;
/// The Windows VM's CID (`guest-cid` in win-venus.sh).
pub const WIN_CID: u32 = 3;
pub const TOKEN_LEN: usize = 32;

pub const OP_PING: u8 = 1;
pub const OP_EXEC: u8 = 2;
pub const OP_PUT: u8 = 3;
pub const OP_GET: u8 = 4;
pub const OP_CONNECT: u8 = 5;

pub const FLAG_PWSH: u8 = 1;
pub const FLAG_COMMAND: u8 = 2;

pub const STDIN: u8 = 0;
pub const STDIN_EOF: u8 = 1;
pub const STDOUT: u8 = 2;
pub const STDERR: u8 = 3;
pub const EXIT: u8 = 4;

/// Longest string or frame accepted (a command, a path, a chunk of output).
pub const MAX_FIELD: u32 = 16 << 20;

pub fn write_str(w: &mut impl Write, s: &str) -> io::Result<()> {
    w.write_all(&(s.len() as u32).to_le_bytes())?;
    w.write_all(s.as_bytes())
}

pub fn read_u8(r: &mut impl Read) -> io::Result<u8> {
    let mut b = [0u8; 1];
    r.read_exact(&mut b)?;
    Ok(b[0])
}

pub fn read_u16(r: &mut impl Read) -> io::Result<u16> {
    let mut b = [0u8; 2];
    r.read_exact(&mut b)?;
    Ok(u16::from_le_bytes(b))
}

pub fn read_u32(r: &mut impl Read) -> io::Result<u32> {
    let mut b = [0u8; 4];
    r.read_exact(&mut b)?;
    Ok(u32::from_le_bytes(b))
}

pub fn read_u64(r: &mut impl Read) -> io::Result<u64> {
    let mut b = [0u8; 8];
    r.read_exact(&mut b)?;
    Ok(u64::from_le_bytes(b))
}

pub fn read_bytes(r: &mut impl Read) -> io::Result<Vec<u8>> {
    let n = read_u32(r)?;
    if n > MAX_FIELD {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("field of {n} bytes")));
    }
    let mut v = vec![0u8; n as usize];
    r.read_exact(&mut v)?;
    Ok(v)
}

pub fn read_str(r: &mut impl Read) -> io::Result<String> {
    String::from_utf8(read_bytes(r)?).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "not UTF-8"))
}

pub fn write_frame(w: &mut impl Write, kind: u8, data: &[u8]) -> io::Result<()> {
    let mut head = [0u8; 5];
    head[0] = kind;
    head[1..].copy_from_slice(&(data.len() as u32).to_le_bytes());
    w.write_all(&head)?;
    w.write_all(data)
}

/// A frame: (kind, data). `None` at a clean end of the stream before a frame.
pub fn read_frame(r: &mut impl Read) -> io::Result<Option<(u8, Vec<u8>)>> {
    let mut kind = [0u8; 1];
    if r.read(&mut kind)? == 0 {
        return Ok(None);
    }
    Ok(Some((kind[0], read_bytes(r)?)))
}

/// The request's opening: magic, version, token, op.
pub fn write_hello(w: &mut impl Write, token: &[u8; TOKEN_LEN], op: u8) -> io::Result<()> {
    let mut b = Vec::with_capacity(4 + 1 + TOKEN_LEN + 1);
    b.extend_from_slice(MAGIC);
    b.push(VERSION);
    b.extend_from_slice(token);
    b.push(op);
    w.write_all(&b)
}

/// Read a request's opening; the op if the magic, version and token are right.
pub fn read_hello(r: &mut impl Read, token: &[u8; TOKEN_LEN]) -> Result<u8, String> {
    let mut b = [0u8; 4 + 1 + TOKEN_LEN + 1];
    r.read_exact(&mut b).map_err(|e| format!("short request: {e}"))?;
    if &b[..4] != MAGIC {
        return Err("not a vmlab request".into());
    }
    if b[4] != VERSION {
        return Err(format!("protocol version {} (the agent speaks {VERSION})", b[4]));
    }
    if !same(&b[5..5 + TOKEN_LEN], token) {
        return Err("wrong token".into());
    }
    Ok(b[5 + TOKEN_LEN])
}

/// Compare in time that does not depend on where they differ.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn write_status(w: &mut impl Write, err: Option<&str>) -> io::Result<()> {
    match err {
        None => w.write_all(&[0]),
        Some(e) => {
            w.write_all(&[1])?;
            write_str(w, e)
        }
    }
}

/// A status byte, and the reason if it is not 0.
pub fn read_status(r: &mut impl Read) -> io::Result<Result<(), String>> {
    Ok(match read_u8(r)? {
        0 => Ok(()),
        _ => Err(read_str(r).unwrap_or_else(|e| format!("(no reason: {e})"))),
    })
}

/// The token from its file: 64 hex digits (whitespace around them is ignored).
pub fn parse_token(text: &str) -> Result<[u8; TOKEN_LEN], String> {
    let t = text.trim();
    if t.len() != TOKEN_LEN * 2 || !t.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!("not {} hex digits", TOKEN_LEN * 2));
    }
    let mut out = [0u8; TOKEN_LEN];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(&t[2 * i..2 * i + 2], 16).unwrap();
    }
    Ok(out)
}

/// Copy `r` to `w` until `r` ends; the count.
pub fn pump(r: &mut impl Read, w: &mut impl Write) -> io::Result<u64> {
    let mut buf = vec![0u8; 256 << 10];
    let mut n = 0u64;
    loop {
        let k = match r.read(&mut buf) {
            Ok(0) => return Ok(n),
            Ok(k) => k,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        w.write_all(&buf[..k])?;
        n += k as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_roundtrip_and_refusals() {
        let token = [7u8; TOKEN_LEN];
        let mut b = Vec::new();
        write_hello(&mut b, &token, OP_EXEC).unwrap();
        assert_eq!(read_hello(&mut &b[..], &token), Ok(OP_EXEC));
        assert_eq!(read_hello(&mut &b[..], &[8u8; TOKEN_LEN]), Err("wrong token".into()));
        let mut bad = b.clone();
        bad[4] = 9;
        assert!(read_hello(&mut &bad[..], &token).unwrap_err().contains("version 9"));
        assert!(read_hello(&mut &b"SSH-2.0-OpenSSH"[..], &token).is_err());
    }

    #[test]
    fn frames_and_strings() {
        let mut b = Vec::new();
        write_frame(&mut b, STDOUT, b"hi").unwrap();
        write_str(&mut b, "C:\\x").unwrap();
        let mut r = &b[..];
        assert_eq!(read_frame(&mut r).unwrap(), Some((STDOUT, b"hi".to_vec())));
        assert_eq!(read_str(&mut r).unwrap(), "C:\\x");
        assert_eq!(read_frame(&mut r).unwrap(), None);
        let mut huge = Vec::new();
        huge.extend_from_slice(&(MAX_FIELD + 1).to_le_bytes());
        assert!(read_bytes(&mut &huge[..]).is_err());
    }

    #[test]
    fn status() {
        let mut b = Vec::new();
        write_status(&mut b, None).unwrap();
        write_status(&mut b, Some("no such file")).unwrap();
        let mut r = &b[..];
        assert_eq!(read_status(&mut r).unwrap(), Ok(()));
        assert_eq!(read_status(&mut r).unwrap(), Err("no such file".into()));
    }

    #[test]
    fn tokens() {
        let t = parse_token(&format!("{}\n", "0f".repeat(32))).unwrap();
        assert_eq!(t, [0x0f; 32]);
        assert!(parse_token("abc").is_err());
        assert!(parse_token(&"zz".repeat(32)).is_err());
    }
}
