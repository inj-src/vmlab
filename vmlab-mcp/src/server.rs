//! Downstream side: the MCP server the agent talks to over stdio.

use std::sync::atomic::{AtomicU64, Ordering};
use std::collections::HashSet;
use std::sync::{Arc, Mutex as StdMutex};

use rmcp::model::{
    CallToolRequest, CallToolRequestParams, CallToolResponse, CallToolResult,
    CancelledNotificationParam, ClientRequest, ContentBlock, Implementation, InitializeResult,
    ListToolsResult, PaginatedRequestParams, RequestId, ServerCapabilities, ServerConfig,
    ServerResult,
};
use rmcp::service::{Peer, PeerRequestOptions, RequestContext, RoleClient, RoleServer, ServiceError};
use rmcp::{ErrorData as McpError, ServerHandler};

use crate::catalog::{self, Catalog, DiskCache, Machine};
use crate::shot;
use crate::upstream::{Config, Handle, Slot};

const INSTRUCTIONS: &str = "\
Drives the desktops of the vmlab test VMs through Cua Driver. Use these tools for everything \
a VM shows: an app's UI, a tray icon, a menu, a dialog, an installer. They find elements by \
name, click and right-click them, send hotkeys, and read window state and the accessibility \
tree. `screenshot` takes the screen on the host in milliseconds, however busy the guest: use it \
to look, and get_window_state with include_screenshot false to read a window. The `vm gui` \
command works in bare pixels: keep it for input the guest must take for a person's (a keyboard hook or hotkey under test; Cua's keys carry \
Windows' injected mark). Every tool takes a required \
`machine` argument: \"win\" (Windows 11) or \"mac\" (macOS). The VM must already be running: \
start it with `vm start <name>`. Load the `vmlab` skill first: the lab's rules and commands, and \
in its gui.md the steps that fail quietly unless driven a set way. Each \
session keeps its own Cua connection per VM, so element refs and Cua sessions persist between \
calls until the VM reboots. Check outcomes yourself in the VM when it matters: `ssh win \
\"<command>\"` (Git Bash; `ssh win-pwsh` for PowerShell) or `ssh mac \"<command>\"` (zsh); a \
script on stdin; both run on the VM's desktop. \
In an Electron window, type with delivery_mode \"foreground\" and read a field back \
before trusting a tool's success.";

pub struct Proxy {
    cfg: Arc<Config>,
    slots: Arc<[Slot; 2]>,
    disk: DiskCache,
    /// The unified list last served, to tell the agent when a connect changed it.
    served: StdMutex<Option<Vec<serde_json::Value>>>,
    /// Per VM, the session generation whose tools/list has been taken into account.
    seen_generation: [AtomicU64; 2],
    /// The Cua sessions (VM, label; "" for none) whose last get_desktop_state image was
    /// reduced: Cua scales later scope "desktop" x,y in them by that image's factor.
    reduced_desktop: StdMutex<HashSet<(Machine, String)>>,
}

impl Proxy {
    pub fn new(cfg: Arc<Config>, slots: Arc<[Slot; 2]>) -> Proxy {
        let disk = DiskCache::new(cfg.cache_dir.clone());
        Proxy {
            cfg,
            slots,
            disk,
            served: StdMutex::new(None),
            seen_generation: Default::default(),
            reduced_desktop: StdMutex::new(HashSet::new()),
        }
    }

    /// Per VM: the list from this session's connect if there was one, else the cache file
    /// (or the seed).
    fn catalog(&self) -> Catalog {
        let list = |m: Machine| self.slots[m.index()].live_tools().unwrap_or_else(|| self.disk.get(m));
        Catalog { lists: [list(Machine::Win), list(Machine::Mac)] }
    }

    /// The list served: Cua's tools (unified) and vmlab-mcp's own `screenshot`, placed after
    /// get_desktop_state.
    fn tool_list(&self) -> Vec<serde_json::Value> {
        with_native(self.catalog().unified())
    }

    async fn connect(
        &self,
        machine: Machine,
        ctx: &RequestContext<RoleServer>,
    ) -> Result<Result<Handle, String>, McpError> {
        let handle = tokio::select! {
            h = self.slots[machine.index()].get(&self.cfg) => h,
            _ = ctx.ct.cancelled() => return Err(cancelled()),
        };
        if let Ok(h) = &handle {
            self.after_connect(machine, h.generation, &ctx.peer);
        }
        Ok(handle)
    }

    async fn forward(
        &self,
        machine: Machine,
        params: CallToolRequestParams,
        ctx: &RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        // Forward the caller's _meta except its progress token (rmcp issues its own token for
        // the upstream request, and progress is mapped back to the caller's token) and the
        // other keys MCP reserves for the transport between these two peers.
        let downstream_token = ctx.meta.get_progress_token();
        let mut meta = ctx.meta.clone();
        meta.0.retain(|k, _| k != "progressToken" && !k.starts_with("io.modelcontextprotocol/"));
        let meta = (!meta.0.is_empty()).then_some(meta);
        let options = || {
            let mut o = PeerRequestOptions::no_options();
            o.meta = meta.clone();
            o.timeout = Some(self.cfg.call_timeout);
            o
        };
        let mut params = params;
        params.meta = None;

        // At most two attempts, and the second only if the first request never left this
        // process (the session had already closed), so a tool never runs twice.
        let mut attempt = 0;
        let (handle, sent) = loop {
            attempt += 1;
            let handle = match self.connect(machine, ctx).await? {
                Ok(h) => h,
                Err(msg) => return Ok(tool_error(msg)),
            };
            // The connect may have taken a while; don't start the action if the caller gave up.
            if ctx.ct.is_cancelled() {
                return Err(cancelled());
            }
            let request = ClientRequest::CallToolRequest(CallToolRequest::new(params.clone()));
            match handle.peer.send_cancellable_request(request, options()).await {
                Ok(sent) => break (handle, sent),
                Err(e) if attempt == 1 => {
                    tracing::warn!(%machine, "upstream session closed before the call was sent ({e}); reconnecting");
                }
                Err(e) => return Ok(tool_error(lost(machine, &handle, &e))),
            }
        };
        let peer = handle.peer.clone();
        let upstream_token = sent.progress_token.clone();
        let _route = downstream_token.map(|token| {
            handle
                .progress
                .lock()
                .unwrap()
                .insert(upstream_token.clone(), (ctx.peer.clone(), token));
            RouteGuard { routes: handle.progress.clone(), token: upstream_token.clone() }
        });
        // If this future is dropped or the caller cancels, tell Cua to cancel too.
        let mut guard = CancelGuard { peer: Some(peer), id: sent.id.clone() };

        let result = tokio::select! {
            r = sent.await_response() => r,
            _ = ctx.ct.cancelled() => return Err(cancelled()),
        };
        // From here Cua needs no cancel: the call completed, or rmcp already sent one (timeout).
        guard.disarm();
        match result {
            Ok(ServerResult::CallToolResult(mut r)) => {
                add_hint(machine, &mut r);
                Ok(CallToolResponse::Complete(r))
            }
            Ok(ServerResult::InputRequiredResult(r)) => Ok(CallToolResponse::InputRequired(r)),
            Ok(ServerResult::CreateTaskResult(r)) => Ok(CallToolResponse::Task(r)),
            Ok(other) => Err(McpError::internal_error(
                format!("unexpected response from Cua Driver on {machine}: {other:?}"),
                None,
            )),
            // A JSON-RPC error from Cua goes back to the agent unchanged.
            Err(ServiceError::McpError(e)) => Err(e),
            Err(ServiceError::Timeout { timeout }) => Ok(tool_error(format!(
                "Cua Driver on {machine} did not answer within {} s; the call was cancelled. \
                 Check the VM's state before retrying (the action may have partly happened)",
                timeout.as_secs()
            ))),
            Err(e) => Ok(tool_error(lost(machine, &handle, &e))),
        }
    }

    /// After a (re)connect, tell the agent if the fresh tools/list changed the unified list.
    /// The slot has already stored the list and refreshed the cache file.
    fn after_connect(&self, machine: Machine, generation: u64, peer: &Peer<RoleServer>) {
        if self.seen_generation[machine.index()].swap(generation, Ordering::SeqCst) == generation {
            return;
        }
        // A new Cua process: its sessions start with no desktop capture.
        self.reduced_desktop.lock().unwrap().retain(|(m, _)| *m != machine);
        let unified = self.tool_list();
        let mut served = self.served.lock().unwrap();
        if served.as_ref().is_some_and(|s| *s != unified) {
            tracing::info!(%machine, "tool list changed; notifying the client");
            *served = Some(unified);
            let peer = peer.clone();
            tokio::spawn(async move {
                let _ = peer.notify_tool_list_changed().await;
            });
        }
    }

    /// Check the tool against the catalog. If it fails and this session has not seen the VM's
    /// live list yet, the cache may be stale (Cua was updated on the VM): connect, then check
    /// the live list. If the connect fails, the first answer stands.
    async fn check(
        &self,
        machine: Machine,
        tool: &str,
        ctx: &RequestContext<RoleServer>,
    ) -> Result<Result<(), String>, McpError> {
        let first = catalog::check_tool(&self.catalog(), machine, tool);
        // An opt-in tool this session does not show is refused whatever the VM has.
        let opt_in = catalog::extra_group_hidden(tool).is_some();
        if first.is_ok() || opt_in || self.slots[machine.index()].live_tools().is_some() {
            return Ok(first);
        }
        if self.connect(machine, ctx).await?.is_err() {
            return Ok(first);
        }
        Ok(catalog::check_tool(&self.catalog(), machine, tool))
    }
}

impl Proxy {
    /// `screenshot`, served here from QEMU's display rather than forwarded to Cua.
    async fn screenshot(
        &self,
        machine: Machine,
        args: serde_json::Map<String, serde_json::Value>,
        ctx: &RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let a = match shot::parse_args(&args) {
            Ok(a) => a,
            Err(msg) => return Ok(tool_error(msg)),
        };
        let t = std::time::Instant::now();
        let r = tokio::select! {
            r = shot::take(machine, &a, std::time::Duration::from_secs(10)) => r,
            _ = ctx.ct.cancelled() => return Err(cancelled()),
        };
        let mut shot = match r {
            Ok(s) => s,
            Err(msg) => return Ok(tool_error(msg)),
        };
        // Cua would scale this image's screen pixels by an earlier reduced capture's factor
        // (macOS's Cua reduces every capture without a max_image_dimension to 1365 pixels):
        // a full-size get_desktop_state (written in the guest, not sent) clears it. Slow on a
        // busy guest, so only when that session has one.
        let key = (machine, a.session.clone().unwrap_or_default());
        if self.reduced_desktop.lock().unwrap().contains(&key) {
            let mut reset = serde_json::Map::new();
            let out = match machine {
                Machine::Win => r"C:\Windows\Temp\vmlab-mcp-desktop.png",
                Machine::Mac => "/tmp/vmlab-mcp-desktop.png",
            };
            reset.insert("screenshot_out_file".into(), out.into());
            // An explicit limit above any screen: macOS's Cua shrinks to 1365 pixels without one.
            reset.insert("max_image_dimension".into(), 16384.into());
            if let Some(s) = &a.session {
                reset.insert("session".into(), s.clone().into());
            }
            let p = CallToolRequestParams::new("get_desktop_state").with_arguments(reset);
            match self.forward(machine, p, ctx).await? {
                CallToolResponse::Complete(c) if c.is_error != Some(true) => {
                    self.reduced_desktop.lock().unwrap().remove(&key);
                    shot.text.push_str(
                        " (This Cua session's scaling from an earlier reduced get_desktop_state \
                         image was reset: x,y read off that image no longer map.)",
                    );
                }
                _ => shot.text.push_str(
                    " Warning: an earlier get_desktop_state image in this Cua session was \
                     reduced, and Cua still scales scope \"desktop\" x,y by its factor; call \
                     get_desktop_state without max_image_dimension before clicking by these pixels.",
                ),
            }
        }
        tracing::info!(%machine, tool = shot::NAME, ms = t.elapsed().as_millis() as u64, ok = true, "call");
        let image = base64_encode(&shot.bytes);
        Ok(CallToolResponse::Complete(CallToolResult::success(vec![
            ContentBlock::image(image, shot.mime),
            ContentBlock::text(shot.text),
        ])))
    }
}

/// Cua's session for a call: its `session` label, "" for the default one.
fn session_key(args: &serde_json::Map<String, serde_json::Value>) -> String {
    args.get("session").and_then(|v| v.as_str()).unwrap_or_default().to_string()
}

/// Whether a get_desktop_state result's image is smaller than the screen (Cua then reports
/// `screenshot_original_width`, in its structured content or its JSON text block).
fn desktop_reduced(r: &CallToolResult) -> bool {
    let reduced = |v: &serde_json::Value| {
        let (orig, got) = (v["screenshot_original_width"].as_u64(), v["screenshot_width"].as_u64());
        matches!((orig, got), (Some(o), Some(g)) if g < o)
    };
    if r.structured_content.as_ref().is_some_and(reduced) {
        return true;
    }
    r.content.iter().filter_map(|b| b.as_text()).any(|t| {
        serde_json::from_str::<serde_json::Value>(&t.text).is_ok_and(|v| reduced(&v))
    })
}

/// Cua's list with `screenshot` added after get_desktop_state (or at the end), replacing any
/// tool of that name Cua may add one day.
fn with_native(mut tools: Vec<serde_json::Value>) -> Vec<serde_json::Value> {
    tools.retain(|t| t["name"] != shot::NAME);
    let at = tools.iter().position(|t| t["name"] == "get_desktop_state").map_or(tools.len(), |i| i + 1);
    tools.insert(at, shot::tool());
    tools
}

fn base64_encode(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

/// One line of advice for the Cua errors that cost agents the most turns, appended to the text
/// block that has the error. The structured fields stay as Cua sent them.
fn hint(machine: Machine, text: &str) -> Option<&'static str> {
    // "Windows did not activate ... no mouse input was sent", or "... was not foreground after
    // the click" (the click was sent, and may have closed or changed the window).
    if machine == Machine::Win && text.contains("foreground_unavailable") {
        return Some(if text.contains("after the click") {
            "Hint: the click was sent; read the window again (get_window_state, or ssh) before \
             retrying. To bring a window to the front: ssh win-pwsh 'C:\\vmlab\\focus.ps1 <part of its \
             title, process name or pid>'."
        } else {
            "Hint: bring the window to the front with ssh win-pwsh 'C:\\vmlab\\focus.ps1 <part of its \
             title, process name or pid>' (exit code 1 if it did not come forward), then retry."
        });
    }
    if text.contains("No screenshot of window") || text.contains("No screenshot frame") {
        return Some(
            "Hint: before a coordinate action, call get_window_state on this window with \
             include_screenshot true (and the same `session`), and take x,y from that image; for \
             screen pixels use scope \"desktop\" and get_desktop_state.",
        );
    }
    if machine == Machine::Mac && text.contains("AXPress) returned -25206") {
        return Some(
            "Hint: on macOS click a text field by x,y with delivery_mode \"foreground\", not by \
             element_token, then type_text in a second call.",
        );
    }
    None
}

fn add_hint(machine: Machine, result: &mut CallToolResult) {
    if result.is_error != Some(true) {
        return;
    }
    for block in &mut result.content {
        if let ContentBlock::Text(t) = block {
            if let Some(h) = hint(machine, &t.text) {
                t.text.push('\n');
                t.text.push_str(h);
                return;
            }
        }
    }
}

fn tool_error(msg: String) -> CallToolResponse {
    CallToolResponse::Complete(CallToolResult::error(vec![ContentBlock::text(msg)]))
}

fn cancelled() -> McpError {
    McpError::internal_error("request cancelled", None)
}

fn lost(machine: Machine, handle: &Handle, e: &ServiceError) -> String {
    if handle.overflowed() {
        return crate::upstream::oversized_message(machine);
    }
    format!(
        "lost the connection to Cua Driver on {machine} during the call ({e}); the VM may have \
         stopped or rebooted. The next call reconnects; element refs and Cua sessions from \
         before are gone"
    )
}

/// Removes a progress route when the call ends.
struct RouteGuard {
    routes: crate::upstream::ProgressRoutes,
    token: rmcp::model::ProgressToken,
}

impl Drop for RouteGuard {
    fn drop(&mut self) {
        self.routes.lock().unwrap().remove(&self.token);
    }
}

/// Sends `notifications/cancelled` upstream unless the call completed.
struct CancelGuard {
    peer: Option<Peer<RoleClient>>,
    id: RequestId,
}

impl CancelGuard {
    fn disarm(&mut self) {
        self.peer = None;
    }
}

impl Drop for CancelGuard {
    fn drop(&mut self) {
        let Some(peer) = self.peer.take() else { return };
        let id = self.id.clone();
        tracing::info!(%id, "cancelling upstream call");
        tokio::spawn(async move {
            let p = CancelledNotificationParam::new(Some(id), Some("cancelled by the client".into()));
            let _ = peer.notify_cancelled(p).await;
        });
    }
}

impl ServerHandler for Proxy {
    fn get_info(&self) -> ServerConfig {
        let caps = ServerCapabilities::builder().enable_tools().enable_tool_list_changed().build();
        let mut info = InitializeResult::new(caps);
        info.server_info = Implementation::new("vmlab", env!("CARGO_PKG_VERSION"));
        info.instructions = Some(INSTRUCTIONS.into());
        info
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _ctx: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        let unified = self.tool_list();
        *self.served.lock().unwrap() = Some(unified.clone());
        serde_json::from_value(serde_json::json!({ "tools": unified }))
            .map_err(|e| McpError::internal_error(format!("bad tool list: {e}"), None))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let mut request = request;
        let (machine, args) = match catalog::route(request.arguments.take()) {
            Ok(r) => r,
            Err(msg) => return Ok(tool_error(msg)),
        };
        if request.name == shot::NAME {
            return self.screenshot(machine, args, &ctx).await;
        }
        if let Err(msg) = self.check(machine, &request.name, &ctx).await? {
            return Ok(tool_error(msg));
        }
        let desktop_session = (request.name == "get_desktop_state").then(|| session_key(&args));
        request.arguments = Some(args);
        let t = std::time::Instant::now();
        let name = request.name.clone();
        let r = self.forward(machine, request, &ctx).await;
        if let (Some(key), Ok(CallToolResponse::Complete(c))) = (desktop_session, &r) {
            if c.is_error != Some(true) {
                let mut set = self.reduced_desktop.lock().unwrap();
                if desktop_reduced(c) {
                    set.insert((machine, key));
                } else {
                    set.remove(&(machine, key));
                }
            }
        }
        tracing::info!(%machine, tool = %name, ms = t.elapsed().as_millis() as u64,
            ok = matches!(&r, Ok(CallToolResponse::Complete(c)) if c.is_error != Some(true)), "call");
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err(text: &str) -> CallToolResult {
        let mut r = CallToolResult::error(vec![ContentBlock::text(text)]);
        r.structured_content = Some(serde_json::json!({"code": "tool_invocation_failed"}));
        r
    }

    fn text(r: &CallToolResult) -> &str {
        r.content[0].as_text().unwrap().text.as_str()
    }

    #[test]
    fn base64_matches_rfc4648() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn reduced_desktop_captures_are_seen() {
        let r = |j: &str| CallToolResult::success(vec![ContentBlock::text(j)]);
        assert!(desktop_reduced(&r(r#"{"screenshot_width":400,"screenshot_original_width":1920}"#)));
        assert!(!desktop_reduced(&r(r#"{"screenshot_width":1920,"screen_width":1920}"#)));
        let mut s = CallToolResult::success(vec![]);
        s.structured_content = Some(serde_json::json!({"screenshot_width": 800, "screenshot_original_width": 1600}));
        assert!(desktop_reduced(&s));
    }

    #[test]
    fn screenshot_follows_get_desktop_state() {
        let t = |n: &str| serde_json::json!({"name": n});
        let l = with_native(vec![t("click"), t("get_desktop_state"), t("screenshot"), t("zoom")]);
        let names: Vec<_> = l.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["click", "get_desktop_state", "screenshot", "zoom"]);
        assert_eq!(l[2]["inputSchema"]["required"][0], "machine");
        assert_eq!(with_native(vec![]).len(), 1);
    }

    #[test]
    fn hints_on_costly_errors() {
        let sent = "foreground_unavailable: exact target HWND 0x100d2 or a verified same-process \
                    post-action window was not foreground after the click (actual foreground HWND 0x102d4)";
        let mut r = err(sent);
        add_hint(Machine::Win, &mut r);
        let t = text(&r);
        assert!(t.starts_with(sent) && t.contains("\nHint: the click was sent"), "{t}");
        assert!(t.contains(r"ssh win-pwsh 'C:\vmlab\focus.ps1 <part of its title"), "{t}");
        assert_eq!(t.lines().count(), 2);
        assert_eq!(r.structured_content, Some(serde_json::json!({"code": "tool_invocation_failed"})));

        let mut r = err("foreground_unavailable: Windows did not activate exact target HWND 0x2014c (actual foreground HWND 0x10248); no mouse input was sent");
        add_hint(Machine::Win, &mut r);
        assert!(text(&r).contains("\nHint: bring the window to the front with ssh win-pwsh"), "{}", text(&r));
        // focus.ps1 is Windows'.
        let mut r = err("foreground_unavailable: no");
        add_hint(Machine::Mac, &mut r);
        assert_eq!(text(&r), "foreground_unavailable: no");

        for m in [Machine::Win, Machine::Mac] {
            let mut r = err("No screenshot of window 131970 in this session: it has not been read yet.");
            add_hint(m, &mut r);
            assert!(text(&r).contains("\nHint: before a coordinate action, call get_window_state"));
            let mut r = err("No screenshot frame for window 131970: its latest read had no screenshot");
            add_hint(m, &mut r);
            assert!(text(&r).contains("include_screenshot true"));
        }

        let mut r = err("AX action failed: AXUIElementPerformAction(AXPress) returned -25206");
        add_hint(Machine::Mac, &mut r);
        assert!(text(&r).ends_with("not by element_token, then type_text in a second call."), "{}", text(&r));

        // Only on errors, and other errors are left alone.
        let mut ok = CallToolResult::success(vec![ContentBlock::text("No screenshot of window 1")]);
        add_hint(Machine::Win, &mut ok);
        assert_eq!(text(&ok), "No screenshot of window 1");
        let mut r = err("background_unavailable");
        add_hint(Machine::Win, &mut r);
        assert_eq!(text(&r), "background_unavailable");
    }
}
