//! Integration tests: run the real binary over stdio, as an agent would.
//! - `vm_off`: a fake `vm` reports both VMs off; tools/list comes from the seed, calls fail fast.
//! - `proxy_*`: VMLAB_MCP_TEST_UPSTREAM points at tests/fake_cua.py instead of SSH.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

struct Client {
    child: Child,
    stdin: Option<ChildStdin>,
    rx: Receiver<Value>,
    /// Notifications seen while waiting for responses.
    notes: Vec<Value>,
    pending: Vec<Value>,
}

impl Client {
    fn spawn(envs: &[(&str, &Path)], extra: &[(&str, &str)]) -> Client {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_vmlab-mcp"));
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
        cmd.env("RUST_LOG", "info");
        for (k, v) in envs {
            cmd.env(k, v);
        }
        for (k, v) in extra {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let line = line.unwrap();
                let v: Value = serde_json::from_str(&line)
                    .unwrap_or_else(|e| panic!("stdout is not JSON-RPC ({e}): {line}"));
                if tx.send(v).is_err() {
                    break;
                }
            }
        });
        let stdin = child.stdin.take();
        let mut c = Client { child, stdin, rx, notes: vec![], pending: vec![] };
        c.send(json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}}));
        let init = c.wait(0, 10);
        assert_eq!(init["result"]["serverInfo"]["name"], "vmlab");
        assert!(init["result"]["instructions"].as_str().unwrap().contains("machine"));
        c.send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
        c
    }

    fn send(&mut self, v: Value) {
        let s = self.stdin.as_mut().unwrap();
        writeln!(s, "{v}").unwrap();
        s.flush().unwrap();
    }

    fn call(&mut self, id: u64, tool: &str, args: Value) {
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": tool, "arguments": args}}));
    }

    fn wait(&mut self, id: u64, secs: u64) -> Value {
        if let Some(i) = self.pending.iter().position(|m| m["id"] == id) {
            return self.pending.remove(i);
        }
        let deadline = Instant::now() + Duration::from_secs(secs);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.rx.recv_timeout(left) {
                Ok(m) if m["id"] == id && m.get("method").is_none() => return m,
                Ok(m) if m.get("method").is_some() && m.get("id").is_none() => self.notes.push(m),
                Ok(m) => self.pending.push(m),
                Err(RecvTimeoutError::Timeout) => panic!("no response to id {id} in {secs}s"),
                Err(RecvTimeoutError::Disconnected) => panic!("server exited"),
            }
        }
    }

    fn call_wait(&mut self, id: u64, tool: &str, args: Value) -> Value {
        self.call(id, tool, args);
        self.wait(id, 20)
    }

    /// Close stdin and wait for the server to exit.
    fn close(mut self) -> std::process::ExitStatus {
        drop(self.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            if let Some(s) = self.child.try_wait().unwrap() {
                return s;
            }
            assert!(Instant::now() < deadline, "server did not exit after stdin closed");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

fn text(resp: &Value) -> String {
    resp["result"]["content"][0]["text"].as_str().unwrap_or_default().to_string()
}

fn is_error(resp: &Value) -> bool {
    resp["result"]["isError"] == true
}

fn write_exe(path: &Path, body: &str) {
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn vm_off() {
    let dir = tempfile::tempdir().unwrap();
    let vm = dir.path().join("vm");
    write_exe(&vm, "#!/bin/sh\ncase $1 in status) printf 'mac  shutoff  -\\nwin  shutoff  -\\n';; ip) echo 192.168.122.171;; esac\n");
    let cache = dir.path().join("cache");
    let mut c = Client::spawn(&[("VMLAB_VM", &vm), ("VMLAB_CACHE_DIR", &cache)], &[]);

    c.send(json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}));
    let tools = c.wait(1, 10)["result"]["tools"].as_array().unwrap().clone();
    assert!(tools.len() >= 60, "seed union has {} tools", tools.len());
    for t in &tools {
        assert_eq!(t["inputSchema"]["required"][0], "machine", "{}", t["name"]);
        assert_eq!(t["inputSchema"]["properties"]["machine"]["enum"], json!(["win", "mac"]));
    }

    for (id, m) in [(2, "mac"), (3, "win")] {
        let t = Instant::now();
        let r = c.call_wait(id, "list_windows", json!({"machine": m}));
        assert!(is_error(&r), "{r}");
        assert_eq!(text(&r), format!("{m} is not running: run `vm start {m}` first"));
        assert!(t.elapsed() < Duration::from_secs(2), "took {:?}", t.elapsed());
    }
    let r = c.call_wait(4, "list_windows", json!({}));
    assert!(text(&r).contains("missing required argument `machine`"), "{r}");
    let r = c.call_wait(5, "no_such_tool", json!({"machine": "win"}));
    assert_eq!(text(&r), "unknown tool `no_such_tool`");
    // Nothing was cached: no VM was reached.
    assert!(!cache.join("cua-tools-win.json").exists());
    assert!(c.close().success());
}

struct Fake {
    _dir: tempfile::TempDir,
    logs: PathBuf,
    cache: PathBuf,
    cmd: String,
}

fn fake() -> Fake {
    let dir = tempfile::tempdir().unwrap();
    let logs = dir.path().join("logs");
    let cache = dir.path().join("cache");
    std::fs::create_dir_all(&logs).unwrap();
    std::fs::create_dir_all(&cache).unwrap();
    // The fake's tools must be in the catalog for routing. win gets all of them; mac lacks
    // `image`, so `image` is win-only. The cached `echo` description is stale on purpose.
    let tool = |n: &str, d: &str| json!({"name": n, "description": d, "inputSchema": {"type": "object", "properties": {"seconds": {"type": "number"}}}});
    let win: Vec<Value> = ["echo", "sleep", "image", "fail", "die"].iter().map(|n| tool(n, &format!("fake {n}"))).collect();
    let mut mac: Vec<Value> = win.iter().filter(|t| t["name"] != "image").cloned().collect();
    mac[0]["description"] = json!("stale");
    std::fs::write(cache.join("cua-tools-win.json"), serde_json::to_vec(&win).unwrap()).unwrap();
    std::fs::write(cache.join("cua-tools-mac.json"), serde_json::to_vec(&mac).unwrap()).unwrap();
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_cua.py");
    let cmd = format!("exec python3 -I {script} {}", logs.display());
    Fake { _dir: dir, logs, cache, cmd }
}

fn spawn_fake(f: &Fake) -> Client {
    Client::spawn(&[("VMLAB_CACHE_DIR", &f.cache)], &[("VMLAB_MCP_TEST_UPSTREAM", &f.cmd)])
}

fn spawn_fake_with(f: &Fake, extra: &[(&str, &str)]) -> Client {
    let mut all = vec![("VMLAB_MCP_TEST_UPSTREAM", f.cmd.as_str())];
    all.extend_from_slice(extra);
    Client::spawn(&[("VMLAB_CACHE_DIR", &f.cache)], &all)
}

fn log_lines(f: &Fake, m: &str) -> Vec<String> {
    std::fs::read_to_string(f.logs.join(format!("{m}.log")))
        .unwrap_or_default()
        .lines()
        .map(String::from)
        .collect()
}

fn pids(f: &Fake, m: &str) -> Vec<i32> {
    std::fs::read_to_string(f.logs.join(format!("{m}.pid")))
        .unwrap_or_default()
        .lines()
        .map(|l| l.parse().unwrap())
        .collect()
}

fn alive(pid: i32) -> bool {
    // A zombie still has /proc/<pid>; check its state too.
    std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .map(|s| !s.split_whitespace().nth(2).is_some_and(|st| st == "Z"))
        .unwrap_or(false)
}

#[test]
fn proxy_routes_strips_and_passes_through() {
    let f = fake();
    let mut c = spawn_fake(&f);
    c.send(json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}));
    let tools = c.wait(1, 10)["result"]["tools"].clone();
    let image = tools.as_array().unwrap().iter().find(|t| t["name"] == "image").unwrap();
    assert!(image["description"].as_str().unwrap().starts_with("[Windows 11 only"));

    // Routing + stripping: the fake for each machine sees the arguments without `machine`.
    let r = c.call_wait(2, "echo", json!({"machine": "win", "x": 1}));
    let echoed: Value = serde_json::from_str(&text(&r)).unwrap();
    assert_eq!(echoed["machine"], "win");
    assert_eq!(echoed["args"], json!({"x": 1}));
    let r = c.call_wait(3, "echo", json!({"machine": "mac"}));
    let echoed: Value = serde_json::from_str(&text(&r)).unwrap();
    assert_eq!(echoed["machine"], "mac");
    assert_eq!(echoed["args"], json!({}));

    // The connect refreshed the mac cache, which changed the unified list.
    let cached: Value = serde_json::from_slice(&std::fs::read(f.cache.join("cua-tools-mac.json")).unwrap()).unwrap();
    assert_eq!(cached.as_array().unwrap().len(), 5);
    assert_eq!(cached[0]["description"], "fake echo");
    assert!(
        c.notes.iter().any(|n| n["method"] == "notifications/tools/list_changed"),
        "notes: {:?}",
        c.notes
    );
    // ... and mac now has `image` too, so it is no longer win-only.
    c.send(json!({"jsonrpc": "2.0", "id": 4, "method": "tools/list"}));
    let tools = c.wait(4, 10)["result"]["tools"].clone();
    let image = tools.as_array().unwrap().iter().find(|t| t["name"] == "image").unwrap();
    assert_eq!(image["description"], "fake image");

    // Results pass through unchanged, including image content and structuredContent.
    let r = c.call_wait(5, "image", json!({"machine": "win"}));
    assert_eq!(r["result"]["content"], json!([
        {"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"},
        {"type": "text", "text": "w=1 h=1", "annotations": {"audience": ["assistant"], "priority": 0.5}},
    ]));
    assert_eq!(r["result"]["structuredContent"], json!({"w": 1, "h": 1}));
    assert!(r["result"].get("isError").is_none_or(|v| v == false));

    // A JSON-RPC error from Cua comes back as the same JSON-RPC error.
    let r = c.call_wait(6, "fail", json!({"machine": "win"}));
    assert_eq!(r["error"]["code"], -32602);
    assert_eq!(r["error"]["message"], "bad window id");
    assert_eq!(r["error"]["data"], json!({"hint": "x"}));

    // Both upstreams exit when the session ends.
    let all: Vec<i32> = pids(&f, "win").into_iter().chain(pids(&f, "mac")).collect();
    assert_eq!(all.len(), 2);
    assert!(c.close().success());
    std::thread::sleep(Duration::from_millis(300));
    for p in all {
        assert!(!alive(p), "upstream {p} still running");
    }
}

#[test]
fn proxy_concurrent_calls_progress_and_cancel() {
    let f = fake();
    let mut c = spawn_fake(&f);
    // Concurrency: three 1 s calls in flight at once finish in about 1 s, not 3 s.
    c.call_wait(1, "echo", json!({"machine": "win"})); // connect first
    let t = Instant::now();
    for id in 10..13 {
        c.call(id, "sleep", json!({"machine": "win", "seconds": 1}));
    }
    for id in (10..13).rev() {
        assert_eq!(text(&c.wait(id, 10)), "slept");
    }
    assert!(t.elapsed() < Duration::from_millis(1900), "calls ran serially: {:?}", t.elapsed());

    // Progress: the upstream token is mapped back to the caller's token.
    c.send(json!({"jsonrpc": "2.0", "id": 20, "method": "tools/call", "params": {
        "name": "sleep", "arguments": {"machine": "win", "seconds": 0.5}, "_meta": {"progressToken": "tok-1"}}}));
    assert_eq!(text(&c.wait(20, 10)), "slept");
    let prog: Vec<_> = c.notes.iter().filter(|n| n["method"] == "notifications/progress").collect();
    assert!(!prog.is_empty(), "no progress forwarded");
    assert!(prog.iter().all(|n| n["params"]["progressToken"] == "tok-1"), "{prog:?}");

    // Cancellation: cancelling the downstream request cancels the upstream one.
    c.call(30, "sleep", json!({"machine": "win", "seconds": 5}));
    std::thread::sleep(Duration::from_millis(400));
    c.send(json!({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 30, "reason": "test"}}));
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let log = std::fs::read_to_string(f.logs.join("win.log")).unwrap_or_default();
        if log.contains("cancelled") {
            break;
        }
        assert!(Instant::now() < deadline, "upstream never saw the cancellation; log: {log}");
        std::thread::sleep(Duration::from_millis(50));
    }
    // The session still works after a cancellation.
    assert!(text(&c.call_wait(31, "echo", json!({"machine": "win"}))).contains("\"win\""));
    assert!(c.close().success());
}

#[test]
fn proxy_reconnects_after_drop() {
    let f = fake();
    let mut c = spawn_fake(&f);
    let first: Value = serde_json::from_str(&text(&c.call_wait(1, "echo", json!({"machine": "win"})))).unwrap();
    // The upstream dies mid-call (like a VM reboot): a clear tool error, no hang.
    let r = c.call_wait(2, "die", json!({"machine": "win"}));
    assert!(is_error(&r), "{r}");
    assert!(text(&r).contains("lost the connection to Cua Driver on win"), "{r}");
    // The next call reconnects once and works, on a new upstream process.
    let again: Value = serde_json::from_str(&text(&c.call_wait(3, "echo", json!({"machine": "win"})))).unwrap();
    assert_ne!(first["pid"], again["pid"]);
    assert_eq!(pids(&f, "win").len(), 2);
    // mac was never used, so it was never started.
    assert!(pids(&f, "mac").is_empty());
    assert!(c.close().success());
}

#[test]
fn proxy_sigterm_cleans_up() {
    let f = fake();
    let mut c = spawn_fake(&f);
    c.call_wait(1, "echo", json!({"machine": "win"}));
    c.call(2, "sleep", json!({"machine": "win", "seconds": 30}));
    std::thread::sleep(Duration::from_millis(200));
    let up = pids(&f, "win")[0];
    unsafe { libc_kill(c.child.id() as i32, 15) };
    let t = Instant::now();
    let status = loop {
        if let Some(s) = c.child.try_wait().unwrap() {
            break s;
        }
        assert!(t.elapsed() < Duration::from_secs(12), "no exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(status.success());
    std::thread::sleep(Duration::from_millis(300));
    assert!(!alive(up), "upstream {up} survived SIGTERM of the proxy");
}

#[test]
fn proxy_sigkill_does_not_orphan() {
    let f = fake();
    let mut c = spawn_fake(&f);
    c.call_wait(1, "echo", json!({"machine": "win"}));
    let up = pids(&f, "win")[0];
    c.child.kill().unwrap(); // SIGKILL: no cleanup code runs
    c.child.wait().unwrap();
    let t = Instant::now();
    while alive(up) {
        assert!(t.elapsed() < Duration::from_secs(5), "upstream {up} orphaned after SIGKILL");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn proxy_strips_reserved_meta() {
    let f = fake();
    let mut c = spawn_fake(&f);
    c.send(json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
        "name": "echo", "arguments": {"machine": "win"},
        "_meta": {"io.modelcontextprotocol/related-task": {"taskId": "t1"}, "custom": 1}}}));
    let echoed: Value = serde_json::from_str(&text(&c.wait(1, 10))).unwrap();
    assert_eq!(echoed["meta"]["custom"], 1, "{echoed}");
    assert!(echoed["meta"].get("io.modelcontextprotocol/related-task").is_none(), "{echoed}");
    assert!(c.close().success());
}

#[test]
fn proxy_call_timeout_is_a_tool_error() {
    let f = fake();
    let mut c = spawn_fake_with(&f, &[("VMLAB_MCP_CALL_TIMEOUT", "1")]);
    c.call_wait(1, "echo", json!({"machine": "win"}));
    let t = Instant::now();
    let r = c.call_wait(2, "sleep", json!({"machine": "win", "seconds": 10}));
    assert!(t.elapsed() < Duration::from_secs(4), "{:?}", t.elapsed());
    assert!(is_error(&r), "{r}");
    assert!(text(&r).contains("did not answer within 1 s"), "{r}");
    std::thread::sleep(Duration::from_millis(300));
    assert!(log_lines(&f, "win").iter().any(|l| l.starts_with("cancelled")), "{:?}", log_lines(&f, "win"));
    // The session itself is still usable.
    assert!(text(&c.call_wait(3, "echo", json!({"machine": "win"}))).contains("\"win\""));
    assert!(c.close().success());
}

#[test]
fn proxy_bounds_tools_list_on_connect() {
    let f = fake();
    let mut c = spawn_fake_with(&f, &[("FAKE_CUA_LIST", "hang"), ("VMLAB_MCP_CONNECT_TIMEOUT", "1")]);
    let t = Instant::now();
    let r = c.call_wait(1, "echo", json!({"machine": "win"}));
    assert!(t.elapsed() < Duration::from_secs(5), "{:?}", t.elapsed());
    assert!(is_error(&r), "{r}");
    assert!(text(&r).contains("tools/list on win did not answer within 1 s"), "{r}");
    // The half-connected upstream was shut down, and the slot is free for another try.
    let up = pids(&f, "win")[0];
    let t = Instant::now();
    while alive(up) {
        assert!(t.elapsed() < Duration::from_secs(6), "upstream {up} left running");
        std::thread::sleep(Duration::from_millis(50));
    }
    let r = c.call_wait(2, "echo", json!({"machine": "mac"}));
    assert!(is_error(&r), "{r}");
    assert!(c.close().success());
}

#[test]
fn proxy_connect_survives_a_cancelled_caller() {
    let f = fake();
    let mut c = spawn_fake_with(&f, &[("FAKE_CUA_LIST", "1.5")]);
    let t = Instant::now();
    c.call(1, "echo", json!({"machine": "win"}));
    std::thread::sleep(Duration::from_millis(300));
    c.send(json!({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1, "reason": "timeout"}}));
    std::thread::sleep(Duration::from_millis(100));
    // The next call reuses the connect that was already under way.
    let r = c.call_wait(2, "echo", json!({"machine": "win"}));
    assert!(!is_error(&r), "{r}");
    assert!(t.elapsed() < Duration::from_millis(2500), "{:?}", t.elapsed());
    assert_eq!(pids(&f, "win").len(), 1);
    // The cancelled call was never sent to Cua.
    let calls: Vec<_> = log_lines(&f, "win").into_iter().filter(|l| l.starts_with("call ")).collect();
    assert_eq!(calls, ["call echo"]);
    assert!(c.close().success());
}

#[test]
fn proxy_stale_catalog_and_unwritable_cache() {
    // The cache dir cannot be created (its parent is a file), so the catalog is the real seed,
    // which has none of the fake's tools.
    let f = fake();
    let blocker = f.logs.join("file");
    std::fs::write(&blocker, "").unwrap();
    let cache = blocker.join("cache");
    let mut c = Client::spawn(&[("VMLAB_CACHE_DIR", &cache)], &[("VMLAB_MCP_TEST_UPSTREAM", &f.cmd)]);
    c.send(json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}));
    let tools = c.wait(1, 10)["result"]["tools"].clone();
    assert!(tools.as_array().unwrap().iter().all(|t| t["name"] != "echo"));
    // `echo` is unknown to the catalog, but this session has not seen win's live list: it
    // connects, checks again and forwards. The live list is used although it was not cached.
    let r = c.call_wait(2, "echo", json!({"machine": "win"}));
    assert!(!is_error(&r), "{r}");
    assert!(c.notes.iter().any(|n| n["method"] == "notifications/tools/list_changed"));
    c.send(json!({"jsonrpc": "2.0", "id": 3, "method": "tools/list"}));
    let tools = c.wait(3, 10)["result"]["tools"].clone();
    assert!(tools.as_array().unwrap().iter().any(|t| t["name"] == "echo"));
    // Now that the live list is known, an unknown tool is refused without another connect.
    let r = c.call_wait(4, "nope", json!({"machine": "win"}));
    assert_eq!(text(&r), "unknown tool `nope`");
    assert_eq!(pids(&f, "win").len(), 1);
    assert!(c.close().success());
}

unsafe extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}
