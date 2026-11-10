//! vmlab-mcp: a stdio MCP server that exposes Cua Driver's tools for the vmlab Windows and
//! macOS VMs as one tool list, routed by a `machine` argument. See README.md.
//!
//! stdout carries only MCP messages; all logging goes to stderr (`RUST_LOG`, default `info`).

mod catalog;
mod server;
mod upstream;

use std::sync::Arc;

use rmcp::ServiceExt;
use tokio::signal::unix::{SignalKind, signal};

use crate::catalog::Machine;
use crate::upstream::{Config, Slot};

// Current-thread runtime: every child is spawned from the main thread, which PR_SET_PDEATHSIG
// relies on (see upstream::die_with_parent). A proxy needs no more than one core.
#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
    if std::env::args().nth(1).is_some_and(|a| a == "--version" || a == "-V") {
        println!("vmlab-mcp {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,rmcp=warn".into()),
        )
        .init();

    let cfg = Arc::new(Config::from_env());
    tracing::info!(vm = %cfg.vm.display(), cache = %cfg.cache_dir.display(), mux = cfg.mux, "starting");
    let slots = Arc::new([Slot::new(Machine::Win), Slot::new(Machine::Mac)]);
    let proxy = server::Proxy::new(cfg, slots.clone());

    let running = proxy.serve(rmcp::transport::stdio()).await?;
    let mut term = signal(SignalKind::terminate())?;
    let mut int = signal(SignalKind::interrupt())?;
    let mut hup = signal(SignalKind::hangup())?;
    let ct = running.cancellation_token();
    tokio::select! {
        r = running.waiting() => tracing::info!("client disconnected: {r:?}"),
        _ = term.recv() => { tracing::info!("SIGTERM"); ct.cancel(); }
        _ = int.recv() => { tracing::info!("SIGINT"); ct.cancel(); }
        _ = hup.recv() => { tracing::info!("SIGHUP"); ct.cancel(); }
    }
    // Close both upstream sessions (ssh stdin EOF -> remote cua-driver exits), bounded in time.
    let close = async {
        tokio::join!(slots[0].shutdown(), slots[1].shutdown());
    };
    if tokio::time::timeout(std::time::Duration::from_secs(10), close).await.is_err() {
        tracing::warn!("upstream shutdown timed out");
    }
    // tokio's stdin reader may still be parked in a blocking read; don't wait for it.
    std::process::exit(0);
}
