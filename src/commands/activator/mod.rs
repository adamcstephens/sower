use anyhow::{Context, Result, anyhow};
use clap::Args;
use std::os::fd::FromRawFd;
use std::os::unix::net::UnixStream;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

mod activate;
mod handler;
mod log_tee;
mod peercred;
mod protocol;
mod time;

#[derive(Debug, Args)]
pub struct ActivatorArgs {
    /// Comma-separated list of GIDs allowed to connect
    #[arg(long, default_value = "")]
    allowed_gids: String,

    /// Enable debug logging
    #[arg(long)]
    debug: bool,
}

pub fn run(args: ActivatorArgs) -> Result<()> {
    let slot = log_tee::CallbackSlot::new();
    init_tracing(args.debug, slot.clone());

    if !rustix::process::geteuid().is_root() {
        return Err(anyhow!("activator must be run as root"));
    }

    let allowed_gids = parse_gids(&args.allowed_gids)?;

    // Stdin is the socket connection from systemd (Accept = true).
    // Take exclusive ownership of fd 0.
    let conn = unsafe { UnixStream::from_raw_fd(0) };

    handler::run(conn, &allowed_gids, &slot)
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
