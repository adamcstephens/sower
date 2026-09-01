//! `sower garden` — drive the garden admin socket from the CLI.
//!
//! Mirrors the activator handler/protocol style but inverted: the garden BEAM
//! binds the socket and this command is the client. It connects over a
//! `UnixStream`, sends one `{v, id, kind, payload}` request envelope, streams
//! the reply frames, and exits with the terminal `complete` frame's exit code.

use anyhow::{Result, bail};
use clap::{Args, Subcommand};
use std::path::PathBuf;

use crate::commands::seed::SeedType;

mod client;
mod config;
mod protocol;

#[derive(Debug, Args)]
pub struct GardenArgs {
    /// Path to the garden admin socket. Overrides the config file and default.
    #[arg(long, env = "SOWER_ADMIN_SOCKET", global = true)]
    socket: Option<PathBuf>,

    /// JSON config file (repeatable). Defaults: root=/etc/sower/client.json,
    /// non-root=$XDG_CONFIG_HOME/sower/client.json. Honored key: admin_socket.
    /// Later files override earlier ones; --socket overrides all.
    #[arg(
        long = "config-file",
        short = 'c',
        env = "SOWER_CONFIG_FILE",
        global = true
    )]
    config_file: Vec<PathBuf>,

    #[command(subcommand)]
    command: GardenCommand,
}

#[derive(Debug, Subcommand)]
enum GardenCommand {
    /// Nudge the local garden to deploy what the server already has for it,
    /// scoped by seed type or subscription sid.
    Trigger(TriggerArgs),
    /// Request a reload (the same path as a SIGHUP).
    Reload,
    /// Report the running garden version and any inflight deployments.
    Status,
    /// Discard this garden's identity and enroll a new one. The recovery path
    /// for a garden the server no longer knows.
    Reregister,
}

#[derive(Debug, Args)]
struct TriggerArgs {
    /// Scope the deployment to a seed type.
    #[arg(long = "type")]
    seed_type: Option<SeedType>,

    /// Scope the deployment to a single subscription sid.
    #[arg(long)]
    sid: Option<String>,

    /// Force deployment even if identical to a previous success.
    #[arg(long)]
    force: bool,
}

pub fn run(args: GardenArgs) -> Result<()> {
    let GardenArgs {
        socket,
        config_file,
        command,
    } = args;

    let socket = config::resolve_socket(socket, &config_file)?;
    let line = build_request_line(&request_id(), &command)?;

    let exit_code = client::run_request(&socket, &line)?;
    if exit_code != 0 {
        std::process::exit(exit_code);
    }
    Ok(())
}

fn build_request_line(id: &str, command: &GardenCommand) -> Result<String> {
    match command {
        GardenCommand::Trigger(trigger) => {
            if trigger.seed_type.is_none() && trigger.sid.is_none() {
                bail!("trigger requires --type or --sid");
            }
            protocol::deploy_request(
                id,
                trigger.seed_type.map(SeedType::as_str),
                trigger.sid.as_deref(),
                trigger.force,
            )
        }
        GardenCommand::Reload => protocol::reload_request(id),
        GardenCommand::Status => protocol::status_request(id),
        GardenCommand::Reregister => protocol::reregister_request(id),
    }
}

fn request_id() -> String {
    std::process::id().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn json(line: &str) -> Value {
        serde_json::from_str(line).unwrap()
    }

    #[test]
    fn reregister_builds_reregister_kind() {
        let v = json(&build_request_line("1", &GardenCommand::Reregister).unwrap());
        assert_eq!(v["kind"], "reregister");
        assert!(v.get("payload").is_none());
    }

    #[test]
    fn trigger_without_type_or_sid_is_rejected() {
        let cmd = GardenCommand::Trigger(TriggerArgs {
            seed_type: None,
            sid: None,
            force: false,
        });
        assert!(build_request_line("1", &cmd).is_err());
    }

    #[test]
    fn trigger_by_type_builds_deploy_kind() {
        let cmd = GardenCommand::Trigger(TriggerArgs {
            seed_type: Some(SeedType::Nixos),
            sid: None,
            force: false,
        });
        let v = json(&build_request_line("1", &cmd).unwrap());
        assert_eq!(v["kind"], "deploy");
        assert_eq!(v["payload"]["seed_type"], "nixos");
    }

    #[test]
    fn trigger_by_sid_builds_deploy_kind() {
        let cmd = GardenCommand::Trigger(TriggerArgs {
            seed_type: None,
            sid: Some("abc".to_string()),
            force: true,
        });
        let v = json(&build_request_line("1", &cmd).unwrap());
        assert_eq!(v["kind"], "deploy");
        assert_eq!(v["payload"]["sid"], "abc");
        assert_eq!(v["payload"]["force"], true);
    }

    #[test]
    fn reload_builds_reload_kind() {
        let v = json(&build_request_line("1", &GardenCommand::Reload).unwrap());
        assert_eq!(v["kind"], "reload");
        assert!(v.get("payload").is_none());
    }

    #[test]
    fn status_builds_status_kind() {
        let v = json(&build_request_line("1", &GardenCommand::Status).unwrap());
        assert_eq!(v["kind"], "status");
        assert!(v.get("payload").is_none());
    }
}
