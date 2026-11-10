//! Upstream side: one lazily started, persistent `cua-driver mcp` session per VM, reached over
//! `ssh -T`. Each agent session gets its own Cua process (Cua state such as element refs is per
//! connection); the SSH TCP connection itself is shared between sessions with ControlMaster.

use std::collections::HashMap;
use std::net::IpAddr;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use rmcp::model::{
    ClientCapabilities, ClientConfig, Implementation, ProgressNotificationParam, ProgressToken,
};
use rmcp::service::{NotificationContext, Peer, RoleClient, RoleServer, RunningService};
use rmcp::transport::TokioChildProcess;
use rmcp::{ClientHandler, ServiceExt};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::Mutex;

use crate::catalog::{self, Machine};

/// Upper bound on SSH connect + the remote readiness wait (≤ 90 s, bounded remotely too) + the
/// MCP handshake + tools/list.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(120);
/// Backstop for one tool call, so a wedged Cua cannot hang the agent forever. Generous: the
/// slowest normal calls (screenshots, long waits) take seconds.
const CALL_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// `vm status` / `vm ip` should answer in well under a second.
const VM_CMD_TIMEOUT: Duration = Duration::from_secs(15);

pub const GUEST_USER: &str = "dev";

#[derive(Debug, Clone)]
pub struct Config {
    /// The `vm` CLI (`VMLAB_VM`, default ~/.local/bin/vm).
    pub vm: PathBuf,
    /// SSH private key for the guests.
    pub ssh_key: PathBuf,
    /// vmlab state dir (~/.cache/vmlab): known_hosts and the ControlMaster sockets.
    pub state_dir: PathBuf,
    /// Where the per-VM tool lists are cached (`VMLAB_CACHE_DIR`, default: state_dir).
    pub cache_dir: PathBuf,
    /// Share SSH connections with ControlMaster (`VMLAB_SSH_MUX=0` turns it off).
    pub mux: bool,
    /// Test hook (`VMLAB_MCP_TEST_UPSTREAM`): a command run as `sh -c "<cmd> <machine>"` instead
    /// of SSH; skips the VM checks. Used by the integration tests with a fake MCP server.
    pub test_upstream: Option<String>,
    /// Bound on one connect (`VMLAB_MCP_CONNECT_TIMEOUT`, seconds; default 120).
    pub connect_timeout: Duration,
    /// Bound on one tool call (`VMLAB_MCP_CALL_TIMEOUT`, seconds; default 900).
    pub call_timeout: Duration,
}

fn env_secs(name: &str, default: Duration) -> Duration {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|v| *v > 0.0)
        .map(Duration::from_secs_f64)
        .unwrap_or(default)
}

impl Config {
    pub fn from_env() -> Config {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/".into());
        let state_dir = std::env::var_os("XDG_CACHE_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".cache"))
            .join("vmlab");
        let vm = std::env::var_os("VMLAB_VM").map(PathBuf::from).unwrap_or_else(|| {
            let local = home.join(".local/bin/vm");
            if local.exists() { local } else { "vm".into() }
        });
        Config {
            vm,
            ssh_key: home.join(".ssh/vmlab_ed25519"),
            cache_dir: std::env::var_os("VMLAB_CACHE_DIR")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| state_dir.clone()),
            state_dir,
            mux: std::env::var("VMLAB_SSH_MUX").map(|v| v != "0").unwrap_or(true),
            test_upstream: std::env::var("VMLAB_MCP_TEST_UPSTREAM").ok().filter(|v| !v.is_empty()),
            connect_timeout: env_secs("VMLAB_MCP_CONNECT_TIMEOUT", CONNECT_TIMEOUT),
            call_timeout: env_secs("VMLAB_MCP_CALL_TIMEOUT", CALL_TIMEOUT),
        }
    }

    pub fn mux_dir(&self) -> PathBuf {
        self.state_dir.join("ssh")
    }
}

/// Printed to stderr by the remote command when the Cua daemon never came up.
pub const NOT_READY_MARKER: &str = "vmlab-mcp: cua-driver daemon not running";

/// The one remote command per session: wait for the Cua daemon in the desktop session, then
/// become `cua-driver mcp`. One command instead of a separate readiness probe saves a remote
/// shell start (~0.5 s for pwsh on win).
/// - The wait is bounded by wall-clock time (90 s, under the local connect timeout): the daemon
///   is kicked after 12 s on win (the logon task) and kickstarted after 60 s on mac (the
///   LaunchAgent), as `vm gui` did.
/// - stdin carries the MCP stream, which the client starts writing at once, so the probes get
///   an empty stdin and their stdout is discarded: only `cua-driver mcp` may touch the stream.
pub fn remote_command(machine: Machine) -> String {
    match machine {
        Machine::Win => format!(
            r#"$c="$env:LOCALAPPDATA\Programs\Cua\cua-driver\bin\cua-driver.exe"; $sw=[Diagnostics.Stopwatch]::StartNew(); $ok=$false; $kicked=$false; while ($true) {{ if ([IO.Directory]::GetFiles("\\.\pipe\") -match "cua-driver") {{ $ok=$true; break }}; if ($sw.Elapsed.TotalSeconds -ge 90) {{ break }}; if (-not $kicked -and $sw.Elapsed.TotalSeconds -ge 12) {{ $kicked=$true; $null | & $c autostart kick | Out-Null }}; Start-Sleep 2 }}; if (-not $ok) {{ [Console]::Error.WriteLine("{NOT_READY_MARKER}"); exit 3 }}; & $c mcp --socket \\.\pipe\cua-driver; exit $LASTEXITCODE"#
        ),
        Machine::Mac => format!(
            r#"ok=0; k=0; SECONDS=0; while :; do ~/.local/bin/cua-driver status </dev/null >/dev/null 2>&1 && {{ ok=1; break; }}; [ $SECONDS -ge 90 ] && break; [ $k = 0 ] && [ $SECONDS -ge 60 ] && {{ k=1; launchctl kickstart -k gui/$(id -u)/com.trycua.cua-driver </dev/null >/dev/null 2>&1; }}; sleep 2; done; [ $ok = 1 ] || {{ echo "{NOT_READY_MARKER}" >&2; exit 3; }}; exec ~/.local/bin/cua-driver mcp"#
        ),
    }
}

/// ssh expands `%` tokens in these paths and splits UserKnownHostsFile on whitespace, so refuse
/// such paths instead of letting ssh use a different file.
fn check_ssh_paths(cfg: &Config) -> Result<(), String> {
    let bad = |p: &std::path::Path| {
        let s = p.to_string_lossy();
        s.contains('%') || s.chars().any(|c| c.is_whitespace() || c == '"' || c == '\'')
    };
    for p in [&cfg.ssh_key, &cfg.state_dir] {
        if bad(p) {
            return Err(format!(
                "unsupported path {}: ssh cannot use paths with spaces, quotes or `%` here",
                p.display()
            ));
        }
    }
    Ok(())
}

/// ssh arguments up to and including the destination. Fixed options only; the one variable part
/// is the destination, built from a parsed IP address, so nothing from outside can inject an
/// option. `-F none` ignores ~/.ssh/config so a user Host block cannot change behaviour.
pub fn ssh_args(cfg: &Config, ip: IpAddr) -> Vec<String> {
    let mut a: Vec<String> = vec!["-F".into(), "none".into(), "-T".into(), "-a".into(), "-x".into()];
    a.push("-i".into());
    a.push(cfg.ssh_key.display().to_string());
    let mut opt = |s: String| {
        a.push("-o".into());
        a.push(s);
    };
    opt("IdentitiesOnly=yes".into());
    opt(format!("UserKnownHostsFile={}", cfg.state_dir.join("known_hosts").display()));
    // Same policy as `vm`: the guests' keys are recorded on first contact (libvirt NAT only).
    opt("StrictHostKeyChecking=accept-new".into());
    opt("BatchMode=yes".into());
    opt("ConnectTimeout=5".into());
    opt("LogLevel=ERROR".into());
    // Notice a dead VM (reboot, stop) within ~15 s instead of TCP's minutes.
    opt("ServerAliveInterval=5".into());
    opt("ServerAliveCountMax=3".into());
    opt("ClearAllForwardings=yes".into());
    if cfg.mux {
        opt("ControlMaster=auto".into());
        // %C is a hash of the connection, so the path stays short (sun_path is 108 bytes).
        opt(format!("ControlPath={}/%C", cfg.mux_dir().display()));
        opt("ControlPersist=10m".into());
    } else {
        opt("ControlMaster=no".into());
        opt("ControlPath=none".into());
    }
    a.push("--".into());
    a.push(format!("{GUEST_USER}@{ip}"));
    a
}

/// Make the child die with us even if we are SIGKILLed (stdin EOF also ends it normally).
/// We run on a current-thread runtime, so the spawning thread is the main thread and lives as
/// long as the process; PR_SET_PDEATHSIG fires when that thread exits.
/// If we die between fork and the prctl, the signal never comes; the getppid check closes that
/// window (the child was reparented, so it exits at once).
fn die_with_parent(cmd: &mut tokio::process::Command) {
    let parent = std::process::id() as libc::pid_t;
    // SAFETY: prctl, getppid and _exit are async-signal-safe; nothing else runs between fork
    // and exec.
    unsafe {
        cmd.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::getppid() != parent {
                libc::_exit(1);
            }
            Ok(())
        });
    }
}

async fn run_vm(cfg: &Config, args: &[&str]) -> Result<(bool, String), String> {
    let mut cmd = tokio::process::Command::new(&cfg.vm);
    cmd.args(args).stdin(Stdio::null()).kill_on_drop(true);
    let out = tokio::time::timeout(VM_CMD_TIMEOUT, cmd.output())
        .await
        .map_err(|_| format!("`vm {}` timed out", args.join(" ")))?
        .map_err(|e| format!("cannot run {}: {e}", cfg.vm.display()))?;
    Ok((out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned()))
}

/// Parse `vm status` output (`name state ip owner...`) for one VM's state.
pub fn parse_status(out: &str, machine: Machine) -> Option<String> {
    out.lines().find_map(|l| {
        let mut f = l.split_whitespace();
        (f.next() == Some(machine.name())).then(|| f.next().unwrap_or("unknown").to_string())
    })
}

pub fn not_running_message(machine: Machine) -> String {
    format!("{machine} is not running: run `vm start {machine}` first")
}

/// The VM's address, or an agent-facing error if it is not running. Checks the libvirt state
/// first: `vm ip` alone can print a stale DHCP lease for a stopped VM.
async fn vm_address(cfg: &Config, machine: Machine) -> Result<IpAddr, String> {
    let (_, status) = run_vm(cfg, &["status"]).await?;
    match parse_status(&status, machine).as_deref() {
        Some("running") => {}
        Some(_) => return Err(not_running_message(machine)),
        None => return Err(format!("`vm status` does not list {machine}")),
    }
    let (ok, out) = run_vm(cfg, &["ip", machine.name()]).await?;
    let ip = out.trim();
    match (ok, ip.parse::<IpAddr>()) {
        (true, Ok(ip)) => Ok(ip),
        _ => Err(format!(
            "{machine} is running but has no IP address yet (still booting?): wait for `vm start {machine}` to finish"
        )),
    }
}

/// Routes upstream progress notifications back to the downstream request that caused them.
pub type ProgressRoutes = Arc<StdMutex<HashMap<ProgressToken, (Peer<RoleServer>, ProgressToken)>>>;

/// Client-side handler for one upstream session.
pub struct UpstreamHandler {
    machine: Machine,
    progress: ProgressRoutes,
}

impl ClientHandler for UpstreamHandler {
    fn get_info(&self) -> ClientConfig {
        ClientConfig::new(
            ClientCapabilities::default(),
            Implementation::new("vmlab-mcp", env!("CARGO_PKG_VERSION")),
        )
    }

    async fn on_progress(
        &self,
        params: ProgressNotificationParam,
        _ctx: NotificationContext<RoleClient>,
    ) {
        let route = self.progress.lock().unwrap().get(&params.progress_token).cloned();
        if let Some((peer, token)) = route {
            let mut p = params;
            p.progress_token = token;
            if let Err(e) = peer.notify_progress(p).await {
                tracing::debug!(machine = %self.machine, "dropping progress notification: {e}");
            }
        }
    }
}

pub type Service = RunningService<RoleClient, UpstreamHandler>;

/// A live upstream session.
pub struct Conn {
    pub service: Service,
    pub progress: ProgressRoutes,
    /// Bumped on every (re)connect, so a caller can tell a fresh session from the old one.
    pub generation: u64,
}

impl Conn {
    pub fn is_alive(&self) -> bool {
        !self.service.is_closed() && !self.service.peer().is_transport_closed()
    }
}

/// Start `cua-driver mcp` on the VM and do the MCP handshake. Returns the session and its
/// tools/list (as raw JSON, for the cache).
pub async fn connect(
    cfg: &Config,
    machine: Machine,
    generation: u64,
) -> Result<(Conn, Vec<serde_json::Value>), String> {
    let t0 = Instant::now();
    let mut cmd = if let Some(test) = &cfg.test_upstream {
        let mut c = tokio::process::Command::new("sh");
        c.arg("-c").arg(format!("{test} {machine}"));
        c
    } else {
        check_ssh_paths(cfg)?;
        let ip = vm_address(cfg, machine).await?;
        if cfg.mux {
            ensure_private_dir(&cfg.mux_dir())
                .map_err(|e| format!("cannot create {}: {e}", cfg.mux_dir().display()))?;
        }
        tracing::info!(%machine, %ip, "connecting");
        let mut c = tokio::process::Command::new("ssh");
        c.args(ssh_args(cfg, ip)).arg(remote_command(machine));
        c
    };
    die_with_parent(&mut cmd);
    let (transport, stderr) = TokioChildProcess::builder(cmd)
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot start the {machine} upstream: {e}"))?;
    // Forward the child's stderr to our log (never to stdout, which carries protocol messages).
    let last_err = Arc::new(StdMutex::new(String::new()));
    if let Some(stderr) = stderr {
        let last_err = last_err.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::warn!(%machine, "upstream stderr: {line}");
                *last_err.lock().unwrap() = line;
            }
        });
    }
    let progress: ProgressRoutes = Arc::default();
    let handler = UpstreamHandler { machine, progress: progress.clone() };
    // One deadline for the readiness wait, the handshake and tools/list (the slot is locked
    // throughout, so every step must be bounded).
    let deadline = tokio::time::Instant::now() + cfg.connect_timeout;
    let service = match tokio::time::timeout_at(deadline, handler.serve(transport)).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => {
            // Let the stderr forwarder drain the last lines before we look at them.
            tokio::time::sleep(Duration::from_millis(100)).await;
            let detail = last_err.lock().unwrap().clone();
            if detail.contains(NOT_READY_MARKER) {
                return Err(format!(
                    "Cua Driver daemon is not running in the {machine} desktop session (is the user logged in? try: vm view {machine})"
                ));
            }
            if detail.starts_with("ssh:") || detail.contains("Permission denied") || detail.contains("Host key") {
                return Err(format!(
                    "cannot reach {machine} over SSH ({detail}). If it was just started, wait for `vm start {machine}` to finish"
                ));
            }
            return Err(format!(
                "MCP handshake with Cua Driver on {machine} failed: {e}{}",
                if detail.is_empty() { String::new() } else { format!(" ({detail})") }
            ));
        }
        Err(_) => {
            return Err(format!(
                "MCP handshake with Cua Driver on {machine} timed out after {} s",
                cfg.connect_timeout.as_secs()
            ));
        }
    };
    let tools = match tokio::time::timeout_at(deadline, service.peer().list_all_tools()).await {
        Ok(Ok(t)) => t,
        Ok(Err(e)) => {
            let _ = service.cancel().await;
            return Err(format!("tools/list on {machine} failed: {e}"));
        }
        Err(_) => {
            let _ = service.cancel().await;
            return Err(format!(
                "tools/list on {machine} did not answer within {} s of connecting",
                cfg.connect_timeout.as_secs()
            ));
        }
    };
    let tools: Vec<serde_json::Value> = tools
        .iter()
        .map(|t| serde_json::to_value(t).expect("Tool serializes"))
        .collect();
    tracing::info!(
        %machine,
        generation,
        tools = tools.len(),
        ms = t0.elapsed().as_millis() as u64,
        "connected"
    );
    Ok((Conn { service, progress, generation }, tools))
}

fn ensure_private_dir(dir: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let meta = std::fs::metadata(dir)?;
    if meta.permissions().mode() & 0o077 != 0 {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// One VM's upstream session slot. The lock is held only while (re)connecting or taking a peer
/// handle, never for the duration of a tool call, so calls run concurrently.
pub struct Slot {
    pub machine: Machine,
    inner: Arc<SlotInner>,
}

struct SlotInner {
    /// The session and the generation counter (bumped on every connect attempt).
    state: Mutex<(Option<Conn>, u64)>,
    /// The tools/list of the last successful connect, normalized. It overrides the cache file,
    /// so a failed cache write never leaves routing on stale data.
    live_tools: StdMutex<Option<Arc<Vec<serde_json::Value>>>>,
}

/// What a caller gets back from `Slot::get`.
pub struct Handle {
    pub peer: Peer<RoleClient>,
    pub progress: ProgressRoutes,
    /// The session's generation; a new one means its tools/list was just refreshed.
    pub generation: u64,
}

impl Conn {
    fn handle(&self) -> Handle {
        Handle {
            peer: self.service.peer().clone(),
            progress: self.progress.clone(),
            generation: self.generation,
        }
    }
}

impl Slot {
    pub fn new(machine: Machine) -> Slot {
        Slot {
            machine,
            inner: Arc::new(SlotInner { state: Mutex::new((None, 0)), live_tools: StdMutex::new(None) }),
        }
    }

    /// The tools/list from this session's last connect, if any.
    pub fn live_tools(&self) -> Option<Arc<Vec<serde_json::Value>>> {
        self.inner.live_tools.lock().unwrap().clone()
    }

    /// The live session, connecting (or reconnecting once, if the old one dropped) as needed.
    /// The connect runs in its own task: if the caller gives up (client timeout or cancel),
    /// the connect still finishes and the next call uses it, instead of the remote side being
    /// abandoned half way through its readiness wait.
    pub async fn get(&self, cfg: &Arc<Config>) -> Result<Handle, String> {
        {
            let st = self.inner.state.lock().await;
            if let Some(conn) = st.0.as_ref().filter(|c| c.is_alive()) {
                return Ok(conn.handle());
            }
        }
        let (inner, cfg, machine) = (self.inner.clone(), cfg.clone(), self.machine);
        tokio::spawn(async move { inner.get_or_connect(&cfg, machine).await })
            .await
            .map_err(|e| format!("connecting to {machine} failed: {e}"))?
    }

    /// Close the session: closes ssh's stdin, waits for it, then SIGTERM/SIGKILL (rmcp's
    /// graceful shutdown of the child process).
    pub async fn shutdown(&self) {
        let conn = self.inner.state.lock().await.0.take();
        if let Some(conn) = conn {
            let _ = conn.service.cancel().await;
            tracing::info!(machine = %self.machine, "upstream closed");
        }
    }
}

impl SlotInner {
    async fn get_or_connect(&self, cfg: &Config, machine: Machine) -> Result<Handle, String> {
        let mut st = self.state.lock().await;
        if let Some(conn) = &st.0 {
            if conn.is_alive() {
                return Ok(conn.handle());
            }
            tracing::warn!(%machine, generation = conn.generation, "upstream session dropped; reconnecting");
            if let Some(old) = st.0.take() {
                let _ = old.service.cancel().await;
            }
        }
        st.1 += 1;
        let (conn, tools) = connect(cfg, machine, st.1).await?;
        let tools = catalog::normalize(tools);
        // Keep the cache file current for other and later sessions. It is not needed for this
        // one, which uses `live_tools`.
        let on_disk = catalog::read_cache(&cfg.cache_dir, machine).map(catalog::normalize);
        if on_disk.as_ref() != Some(&tools) {
            if let Err(e) = catalog::write_cache(&cfg.cache_dir, machine, &tools) {
                tracing::warn!(%machine, "cannot write tool cache: {e}");
            }
        }
        *self.live_tools.lock().unwrap() = Some(Arc::new(tools));
        let handle = conn.handle();
        st.0 = Some(conn);
        Ok(handle)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(mux: bool) -> Config {
        Config {
            vm: "/bin/false".into(),
            ssh_key: "/k/id".into(),
            state_dir: "/s".into(),
            cache_dir: "/c".into(),
            mux,
            test_upstream: None,
            connect_timeout: CONNECT_TIMEOUT,
            call_timeout: CALL_TIMEOUT,
        }
    }

    #[test]
    fn ssh_args_mux() {
        let a = ssh_args(&cfg(true), "192.168.122.5".parse().unwrap());
        let s = a.join(" ");
        assert!(s.starts_with("-F none -T -a -x -i /k/id "), "{s}");
        assert!(s.contains("-o ControlMaster=auto -o ControlPath=/s/ssh/%C -o ControlPersist=10m"));
        assert!(s.contains("-o UserKnownHostsFile=/s/known_hosts"));
        assert!(s.contains("-o BatchMode=yes"));
        assert_eq!(&a[a.len() - 2..], ["--", "dev@192.168.122.5"]);
    }

    #[test]
    fn ssh_args_no_mux() {
        let s = ssh_args(&cfg(false), "10.0.0.1".parse().unwrap()).join(" ");
        assert!(s.contains("-o ControlMaster=no -o ControlPath=none"));
        assert!(!s.contains("ControlPersist"));
    }

    #[test]
    fn ssh_paths_are_checked() {
        assert!(check_ssh_paths(&cfg(true)).is_ok());
        let mut c = cfg(true);
        c.state_dir = "/home/a b/.cache/vmlab".into();
        assert!(check_ssh_paths(&c).unwrap_err().contains("unsupported path /home/a b/"));
        let mut c = cfg(true);
        c.ssh_key = "/k/50%".into();
        assert!(check_ssh_paths(&c).is_err());
    }

    #[test]
    fn remote_probes_cannot_read_the_mcp_stream() {
        let mac = remote_command(Machine::Mac);
        assert!(mac.contains("cua-driver status </dev/null >/dev/null"), "{mac}");
        assert!(mac.contains("com.trycua.cua-driver </dev/null >/dev/null"), "{mac}");
        assert!(mac.contains("[ $SECONDS -ge 90 ] && break"), "{mac}");
        let win = remote_command(Machine::Win);
        assert!(win.contains("$null | & $c autostart kick | Out-Null"), "{win}");
        assert!(win.contains("TotalSeconds -ge 90"), "{win}");
        assert!(win.contains(r"& $c mcp --socket \\.\pipe\cua-driver"), "{win}");
    }

    #[test]
    fn status_parsing() {
        let out = "mac  shutoff  -               \nwin  running  192.168.122.171 started by x 2026\n";
        assert_eq!(parse_status(out, Machine::Mac).as_deref(), Some("shutoff"));
        assert_eq!(parse_status(out, Machine::Win).as_deref(), Some("running"));
        assert_eq!(parse_status("", Machine::Win), None);
    }

    #[test]
    fn not_running_text() {
        assert_eq!(not_running_message(Machine::Mac), "mac is not running: run `vm start mac` first");
    }

    #[tokio::test]
    async fn vm_off_is_reported_without_ssh() {
        // A fake `vm` that reports both VMs shut off.
        let dir = tempfile::tempdir().unwrap();
        let vm = dir.path().join("vm");
        std::fs::write(&vm, "#!/bin/sh\n[ \"$1\" = status ] && printf 'mac  shutoff  -\\nwin  shutoff  -\\n'\n[ \"$1\" = ip ] && echo 192.168.122.9\nexit 0\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&vm, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut c = cfg(true);
        c.vm = vm;
        let t = Instant::now();
        let err = connect(&c, Machine::Mac, 1).await.err().unwrap();
        assert_eq!(err, "mac is not running: run `vm start mac` first");
        assert!(t.elapsed() < Duration::from_secs(2));
    }
}
