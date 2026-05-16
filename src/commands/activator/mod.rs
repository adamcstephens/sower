use anyhow::{Context, Result, anyhow};
use clap::Args;
use std::io::BufReader;
use std::os::fd::{BorrowedFd, FromRawFd};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

use handler::SharedWriter;

mod activate;
mod handler;
mod log_tee;
mod peercred;
mod protocol;
mod time;

#[derive(Debug, Args)]
pub struct ActivatorArgs {
    /// Comma-separated list of GIDs allowed to connect (socket mode only)
    #[arg(long, default_value = "")]
    allowed_gids: String,

    /// Enable debug logging
    #[arg(long)]
    debug: bool,
}

pub fn run(args: ActivatorArgs) -> Result<()> {
    let slot = log_tee::CallbackSlot::new();
    init_tracing(args.debug, slot.clone());

    let allowed_gids = parse_gids(&args.allowed_gids)?;

    let fd0 = unsafe { BorrowedFd::borrow_raw(0) };
    let stat = rustix::fs::fstat(fd0).context("fstat fd 0")?;
    let is_socket = rustix::fs::FileType::from_raw_mode(stat.st_mode) == rustix::fs::FileType::Socket;

    if is_socket {
        run_socket(&allowed_gids, &slot)
    } else {
        run_pipe(&slot)
    }
}

fn run_socket(allowed_gids: &[u32], slot: &log_tee::CallbackSlot) -> Result<()> {
    if !rustix::process::geteuid().is_root() {
        return Err(anyhow!("activator must be run as root in socket mode"));
    }

    // Stdin is the socket connection from systemd (Accept = true).
    // Take exclusive ownership of fd 0.
    let conn = unsafe { UnixStream::from_raw_fd(0) };

    let writer: SharedWriter = Arc::new(Mutex::new(conn.try_clone().context("clone socket")?));

    let creds = match peercred::get(std::os::fd::AsFd::as_fd(&conn)) {
        Ok(c) => c,
        Err(err) => {
            tracing::error!(?err, "Failed to get peer credentials");
            handler::send_response(
                &writer,
                &protocol::Response::error("", "failed to get peer credentials"),
            );
            return Ok(());
        }
    };
    tracing::debug!(
        pid = creds.pid,
        uid = creds.uid,
        gid = creds.gid,
        "Connection from peer"
    );

    if !peercred::is_authorized(&creds, allowed_gids) {
        tracing::warn!(
            uid = creds.uid,
            gid = creds.gid,
            "Unauthorized connection attempt"
        );
        handler::send_response(&writer, &protocol::Response::error("", "unauthorized"));
        return Ok(());
    }

    let reader = BufReader::new(conn);
    handler::run(reader, writer, slot)
}

fn run_pipe(slot: &log_tee::CallbackSlot) -> Result<()> {
    tracing::debug!("Running in pipe mode (fd 0 is not a socket)");
    let writer: SharedWriter = Arc::new(Mutex::new(std::io::stdout()));
    let reader = BufReader::new(std::io::stdin());
    handler::run(reader, writer, slot)
}

fn init_tracing(debug: bool, slot: log_tee::CallbackSlot) {
    let level = if debug {
        tracing::Level::DEBUG
    } else {
        tracing::Level::INFO
    };
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(level.to_string()));

    let fmt_layer = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stderr)
        .with_target(false);

    tracing_subscriber::registry()
        .with(filter)
        .with(fmt_layer)
        .with(log_tee::CallbackLayer::new(slot))
        .init();
}

fn parse_gids(s: &str) -> Result<Vec<u32>> {
    s.split(',')
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| {
            p.parse::<u32>()
                .with_context(|| format!("invalid GID: {p}"))
        })
        .collect()
}
