//! Downstream side: the MCP server the agent talks to over stdio.

use std::sync::atomic::{AtomicU64, Ordering};
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
use crate::upstream::{Config, Handle, Slot};

const INSTRUCTIONS: &str = "\
Drives the desktops of the vmlab test VMs through Cua Driver. Use these tools for everything \
a VM shows: an app's UI, a tray icon, a menu, a dialog, an installer. They find elements by \
name, click and right-click them, send hotkeys, and read window state and the accessibility \
tree. The `vm gui` command works in bare pixels: keep it for a plain screenshot and for input \
the guest must take for a person's (a keyboard hook or hotkey under test; Cua's keys carry \
Windows' injected mark). Every tool takes a required \
`machine` argument: \"win\" (Windows 11) or \"mac\" (macOS). The VM must already be running: \
start it with `vm start <name>` (one VM at a time; see /vmlab/tools/vmlab/AGENTS.md). Each \
session keeps its own Cua connection per VM, so element refs and Cua sessions persist between \
calls until the VM reboots. Check outcomes yourself in the VM when it matters: `vm run <name>` \
for a script (it runs on the VM's desktop), `vm ssh <name> \"<command>\"` for one plain command.";

pub struct Proxy {
    cfg: Arc<Config>,
    slots: Arc<[Slot; 2]>,
    disk: DiskCache,
    /// The unified list last served, to tell the agent when a connect changed it.
    served: StdMutex<Option<Vec<serde_json::Value>>>,
    /// Per VM, the session generation whose tools/list has been taken into account.
    seen_generation: [AtomicU64; 2],
}

impl Proxy {
    pub fn new(cfg: Arc<Config>, slots: Arc<[Slot; 2]>) -> Proxy {
        let disk = DiskCache::new(cfg.cache_dir.clone());
        Proxy { cfg, slots, disk, served: StdMutex::new(None), seen_generation: Default::default() }
    }

    /// Per VM: the list from this session's connect if there was one, else the cache file
    /// (or the seed).
    fn catalog(&self) -> Catalog {
        let list = |m: Machine| self.slots[m.index()].live_tools().unwrap_or_else(|| self.disk.get(m));
        Catalog { lists: [list(Machine::Win), list(Machine::Mac)] }
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
            Ok(ServerResult::CallToolResult(r)) => Ok(CallToolResponse::Complete(r)),
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
        let unified = self.catalog().unified();
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
        if first.is_ok() || self.slots[machine.index()].live_tools().is_some() {
            return Ok(first);
        }
        if self.connect(machine, ctx).await?.is_err() {
            return Ok(first);
        }
        Ok(catalog::check_tool(&self.catalog(), machine, tool))
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
        let unified = self.catalog().unified();
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
        if let Err(msg) = self.check(machine, &request.name, &ctx).await? {
            return Ok(tool_error(msg));
        }
        request.arguments = Some(args);
        let t = std::time::Instant::now();
        let name = request.name.clone();
        let r = self.forward(machine, request, &ctx).await;
        tracing::info!(%machine, tool = %name, ms = t.elapsed().as_millis() as u64,
            ok = matches!(&r, Ok(CallToolResponse::Complete(c)) if c.is_error != Some(true)), "call");
        r
    }
}
