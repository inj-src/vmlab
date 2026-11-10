//! Downstream side: the MCP server the agent talks to over stdio.

use std::sync::{Arc, Mutex as StdMutex};

use rmcp::model::{
    CallToolRequest, CallToolRequestParams, CallToolResponse, CallToolResult,
    CancelledNotificationParam, ClientRequest, ContentBlock, Implementation, InitializeResult,
    ListToolsResult, PaginatedRequestParams, RequestId, ServerCapabilities, ServerConfig,
    ServerResult,
};
use rmcp::service::{Peer, PeerRequestOptions, RequestContext, RoleClient, RoleServer, ServiceError};
use rmcp::{ErrorData as McpError, ServerHandler};

use crate::catalog::{self, Catalog, Machine};
use crate::upstream::{Config, Slot};

const INSTRUCTIONS: &str = "\
Drives the desktops of the vmlab test VMs through Cua Driver. Every tool takes a required \
`machine` argument: \"win\" (Windows 11) or \"mac\" (macOS). The VM must already be running: \
start it with `vm start <name>` (one VM at a time; see the vmlab README). Each session keeps \
its own Cua connection per VM, so element refs and Cua sessions persist between calls until \
the VM reboots. Check outcomes yourself over `vm ssh` when it matters.";

pub struct Proxy {
    cfg: Arc<Config>,
    slots: Arc<[Slot; 2]>,
    /// The unified list last served, to tell the agent when a connect changed it.
    served: StdMutex<Option<Vec<serde_json::Value>>>,
}

impl Proxy {
    pub fn new(cfg: Arc<Config>, slots: Arc<[Slot; 2]>) -> Proxy {
        Proxy { cfg, slots, served: StdMutex::new(None) }
    }

    fn catalog(&self) -> Catalog {
        Catalog::load(&self.cfg.cache_dir)
    }

    async fn forward(
        &self,
        machine: Machine,
        params: CallToolRequestParams,
        ctx: &RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let slot = &self.slots[machine.index()];

        // Forward the caller's _meta except its progress token: rmcp issues its own token for
        // the upstream request, and progress is mapped back to the caller's token.
        let downstream_token = ctx.meta.get_progress_token();
        let mut meta = ctx.meta.clone();
        meta.0.remove("progressToken");
        let meta = (!meta.0.is_empty()).then_some(meta);
        let options = || {
            let mut o = PeerRequestOptions::no_options();
            o.meta = meta.clone();
            o
        };
        let mut params = params;
        params.meta = None;

        // At most two attempts, and the second only if the first request never left this
        // process (the session had already closed), so a tool never runs twice.
        let mut attempt = 0;
        let (handle, sent) = loop {
            attempt += 1;
            let handle = tokio::select! {
                h = slot.get(&self.cfg) => h,
                _ = ctx.ct.cancelled() => return Err(cancelled()),
            };
            let handle = match handle {
                Ok(h) => h,
                Err(msg) => return Ok(tool_error(msg)),
            };
            if let Some(tools) = &handle.new_tools {
                self.on_fresh_tools(machine, tools, &ctx.peer).await;
            }
            let request = ClientRequest::CallToolRequest(CallToolRequest::new(params.clone()));
            match handle.peer.send_cancellable_request(request, options()).await {
                Ok(sent) => break (handle, sent),
                Err(e) if attempt == 1 => {
                    tracing::warn!(%machine, "upstream session closed before the call was sent ({e}); reconnecting");
                }
                Err(e) => return Ok(tool_error(lost(machine, &e))),
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
            Err(e) => Ok(tool_error(lost(machine, &e))),
        }
    }

    /// Persist a fresh tools/list and tell the agent if the unified list changed.
    async fn on_fresh_tools(
        &self,
        machine: Machine,
        tools: &[serde_json::Value],
        peer: &Peer<RoleServer>,
    ) {
        let before = self.catalog();
        let tools = &catalog::normalize(tools.to_vec())[..];
        if before.lists[machine.index()] != tools {
            if let Err(e) = catalog::write_cache(&self.cfg.cache_dir, machine, tools) {
                tracing::warn!(%machine, "cannot write tool cache: {e}");
            }
        } else if catalog::read_cache(&self.cfg.cache_dir, machine).is_none() {
            // Same as the seed, but write it so the cache reflects a real connect.
            let _ = catalog::write_cache(&self.cfg.cache_dir, machine, tools);
        }
        let mut after = before;
        after.lists[machine.index()] = tools.to_vec();
        let unified = after.unified();
        let changed = {
            let served = self.served.lock().unwrap();
            served.as_ref().is_some_and(|s| *s != unified)
        };
        if changed {
            tracing::info!(%machine, "tool list changed; notifying the client");
            *self.served.lock().unwrap() = Some(unified);
            let _ = peer.notify_tool_list_changed().await;
        }
    }
}

fn tool_error(msg: String) -> CallToolResponse {
    CallToolResponse::Complete(CallToolResult::error(vec![ContentBlock::text(msg)]))
}

fn cancelled() -> McpError {
    McpError::internal_error("request cancelled", None)
}

fn lost(machine: Machine, e: &ServiceError) -> String {
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
        if let Err(msg) = catalog::check_tool(&self.catalog(), machine, &request.name) {
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
