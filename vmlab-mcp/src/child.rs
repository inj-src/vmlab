//! The upstream child process as an rmcp transport, with a hard cap on one incoming line.
//!
//! rmcp's own `TokioChildProcess` reads the child's stdout through `AsyncRwTransport`, which
//! drops a line over 16 MiB and keeps the connection open. The request that line answered then
//! never gets a response, and the agent's call hangs until the call timeout. Here stdout goes
//! through [`LineLimit`] first: a line over [`MAX_LINE`] becomes a read error, rmcp treats that
//! as the end of the stream, and the session closes, failing the pending requests at once. The
//! shared `overflow` flag lets the caller tell that closure from a dropped VM.

use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use rmcp::RoleClient;
use rmcp::transport::Transport;
use rmcp::transport::async_rw::{AsyncRwTransport, DEFAULT_MAX_LINE_LENGTH};
use tokio::io::{AsyncRead, ReadBuf};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout};

/// Largest accepted upstream message: one JSON-RPC line, without its `\n`. rmcp's limit.
pub const MAX_LINE: usize = DEFAULT_MAX_LINE_LENGTH;

/// How long the child gets to exit after its stdin closes, and again after SIGTERM, before the
/// next step (rmcp's `TokioChildProcess` uses the same 3 s).
const EXIT_WAIT: Duration = Duration::from_secs(3);

/// Passes bytes through and fails once a line grows past `max` bytes (not counting its `\n`).
/// It never buffers: it only counts the bytes since the last newline. The error is sticky.
pub struct LineLimit<R> {
    inner: R,
    max: usize,
    /// Bytes since the last `\n`.
    run: usize,
    /// Set when the limit was crossed; every later read fails.
    overflow: Arc<AtomicBool>,
}

impl<R> LineLimit<R> {
    pub fn new(inner: R, max: usize, overflow: Arc<AtomicBool>) -> Self {
        LineLimit { inner, max, run: 0, overflow }
    }

    fn error(&self) -> io::Error {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("upstream message longer than {} bytes", self.max),
        )
    }
}

impl<R: AsyncRead + Unpin> AsyncRead for LineLimit<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if self.overflow.load(Ordering::Relaxed) {
            return Poll::Ready(Err(self.error()));
        }
        let start = buf.filled().len();
        let this = &mut *self;
        match Pin::new(&mut this.inner).poll_read(cx, buf) {
            Poll::Ready(Ok(())) => {}
            other => return other,
        }
        let mut run = this.run;
        let mut cut = None;
        for (i, b) in buf.filled()[start..].iter().enumerate() {
            if *b == b'\n' {
                run = 0;
            } else {
                run += 1;
                if run > this.max {
                    cut = Some(start + i);
                    break;
                }
            }
        }
        this.run = run;
        let Some(cut) = cut else { return Poll::Ready(Ok(())) };
        this.overflow.store(true, Ordering::Relaxed);
        // Hand over what came before the crossing (it may end earlier, complete messages);
        // the error follows on the next read. With nothing before it, fail now: an empty
        // read would mean EOF.
        buf.set_filled(cut);
        if cut > start { Poll::Ready(Ok(())) } else { Poll::Ready(Err(this.error())) }
    }
}

/// `cua-driver mcp` (over ssh) as an rmcp client transport.
pub struct ChildTransport {
    /// Spawned with `kill_on_drop`, so dropping the transport without `close` still kills it.
    child: Option<Child>,
    rw: AsyncRwTransport<RoleClient, LineLimit<ChildStdout>, ChildStdin>,
    overflow: Arc<AtomicBool>,
}

impl ChildTransport {
    /// Spawn `cmd` with piped stdio. Returns the transport, the child's stderr and the flag
    /// that is set if the child sends a line over [`MAX_LINE`].
    pub fn spawn(
        mut cmd: tokio::process::Command,
    ) -> io::Result<(ChildTransport, Option<ChildStderr>, Arc<AtomicBool>)> {
        cmd.stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let mut child = cmd.spawn()?;
        let stdin = child.stdin.take().expect("stdin is piped");
        let stdout = child.stdout.take().expect("stdout is piped");
        let stderr = child.stderr.take();
        let overflow = Arc::new(AtomicBool::new(false));
        let read = LineLimit::new(stdout, MAX_LINE, overflow.clone());
        // rmcp's own limit counts the `\n` too: one more byte, so `LineLimit` always trips
        // first and rmcp never silently drops a line.
        let rw = AsyncRwTransport::new(read, stdin).with_max_line_length(MAX_LINE + 1);
        Ok((ChildTransport { child: Some(child), rw, overflow: overflow.clone() }, stderr, overflow))
    }

    /// Close stdin and wait for the child; then SIGTERM, then SIGKILL. After an oversized line
    /// the child is stuck writing to a pipe nobody reads, so it gets SIGTERM at once.
    async fn shutdown(&mut self) -> io::Result<()> {
        let Some(child) = self.child.as_mut() else { return Ok(()) };
        self.rw.close().await?;
        let overflow = self.overflow.load(Ordering::Relaxed);
        if !overflow && tokio::time::timeout(EXIT_WAIT, child.wait()).await.is_ok() {
            self.child = None;
            return Ok(());
        }
        if let Some(pid) = child.id() {
            // SAFETY: plain kill(2) on our own, not yet reaped, child.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
            if tokio::time::timeout(EXIT_WAIT, child.wait()).await.is_ok() {
                self.child = None;
                return Ok(());
            }
        }
        let r = child.kill().await;
        self.child = None;
        r
    }
}

impl Transport<RoleClient> for ChildTransport {
    type Error = io::Error;

    fn send(
        &mut self,
        item: rmcp::service::TxJsonRpcMessage<RoleClient>,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send + 'static {
        self.rw.send(item)
    }

    fn receive(
        &mut self,
    ) -> impl Future<Output = Option<rmcp::service::RxJsonRpcMessage<RoleClient>>> + Send {
        self.rw.receive()
    }

    fn close(&mut self) -> impl Future<Output = Result<(), Self::Error>> + Send {
        self.shutdown()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    /// Reads `input` through a `LineLimit` in `chunk`-sized reads; returns what was passed
    /// through and whether it ended in the overflow error.
    async fn run(input: &[u8], max: usize, chunk: usize) -> (Vec<u8>, bool) {
        let flag = Arc::new(AtomicBool::new(false));
        let mut r = LineLimit::new(input, max, flag.clone());
        let (mut out, mut buf) = (Vec::new(), vec![0u8; chunk]);
        loop {
            match r.read(&mut buf).await {
                Ok(0) => return (out, false),
                Ok(n) => out.extend_from_slice(&buf[..n]),
                Err(e) => {
                    assert_eq!(e.kind(), io::ErrorKind::InvalidData);
                    assert!(flag.load(Ordering::Relaxed));
                    // Sticky.
                    assert!(r.read(&mut buf).await.is_err());
                    return (out, true);
                }
            }
        }
    }

    #[tokio::test]
    async fn lines_up_to_the_limit_pass() {
        for chunk in [1, 3, 64] {
            let input = b"abcd\nabcd\n\nab";
            assert_eq!(run(input, 4, chunk).await, (input.to_vec(), false), "chunk {chunk}");
        }
    }

    #[tokio::test]
    async fn a_longer_line_fails_after_the_earlier_lines() {
        for chunk in [1, 3, 64] {
            let (out, failed) = run(b"ab\nabcde\nok\n", 4, chunk).await;
            assert!(failed, "chunk {chunk}");
            // Everything before the crossing byte was passed on, nothing after it.
            assert_eq!(out, b"ab\nabcd", "chunk {chunk}");
        }
        // Crossing on the first byte of a read fails that read (an empty read is EOF).
        assert_eq!(run(b"abcde", 4, 4).await, (b"abcd".to_vec(), true));
    }

    #[test]
    fn limit_is_rmcps() {
        assert_eq!(MAX_LINE, 16 * 1024 * 1024);
    }
}
