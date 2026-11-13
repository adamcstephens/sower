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
    /// Report the garden version, active deployments, and linked pending seeds.
    Status,
    /// Discard this garden's identity and enroll a new one. The recovery path
    /// for a garden the server no longer knows.
    Reregister,
    /// Inspect and manage named package and devshell profiles.
    Profile(ProfileArgs),
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

#[derive(Debug, Args)]
struct ProfileArgs {
    #[command(subcommand)]
    command: ProfileCommand,
}

#[derive(Debug, Subcommand)]
enum ProfileCommand {
    /// List durable locally owned profiles, including pending removal.
    List,
    /// Inspect selected/staged paths, generations, pins and retention.
    Show { name: String },
    /// Stage a seed through the subscription deployment policy.
    Stage {
        name: String,
        #[arg(long)]
        subscription_sid: String,
        #[arg(long)]
        seed_sid: Option<String>,
    },
    /// Select a retained generation. External services are not restarted.
    Select {
        name: String,
        #[arg(allow_hyphen_values = true)]
        generation: String,
    },
    /// Roll back to a retained generation without changing external processes.
    Rollback {
        name: String,
        #[arg(allow_hyphen_values = true)]
        generation: String,
    },
    /// Protect an immutable generation until external consumers transition.
    Pin {
        name: String,
        #[arg(allow_hyphen_values = true)]
        generation: String,
    },
    /// Release an explicit generation pin.
    Unpin {
        name: String,
        #[arg(allow_hyphen_values = true)]
        generation: String,
    },
    /// Discard intentionally staged state without changing the selection.
    Discard {
        name: String,
        #[arg(allow_hyphen_values = true)]
        generation: String,
    },
    /// Preview removal; --confirm requests uninstall. Unpin generations first.
    Uninstall {
        name: String,
        /// External services are not stopped and published paths disappear.
        #[arg(long)]
        confirm: bool,
        /// Only preview affected generations; this is the default.
        #[arg(long, conflicts_with = "confirm")]
        preview: bool,
    },
}

fn profile_payload(command: &ProfileCommand) -> protocol::ProfilePayload<'_> {
    let mut payload = protocol::ProfilePayload {
        action: "list",
        profile_name: None,
        generation_id: None,
        seed_sid: None,
        subscription_sid: None,
        preview: None,
    };
    match command {
        ProfileCommand::List => {}
        ProfileCommand::Show { name } => {
            payload.action = "inspect";
            payload.profile_name = Some(name);
        }
        ProfileCommand::Stage {
            name,
            subscription_sid,
            seed_sid,
        } => {
            payload.action = "stage";
            payload.profile_name = Some(name);
            payload.subscription_sid = Some(subscription_sid);
            payload.seed_sid = seed_sid.as_deref();
        }
        ProfileCommand::Select { name, generation }
        | ProfileCommand::Rollback { name, generation }
        | ProfileCommand::Pin { name, generation }
        | ProfileCommand::Unpin { name, generation } => {
            payload.action = match command {
                ProfileCommand::Select { .. } => "select",
                ProfileCommand::Rollback { .. } => "rollback",
                ProfileCommand::Pin { .. } => "pin",
                _ => "unpin",
            };
            payload.profile_name = Some(name);
            payload.generation_id = Some(generation);
        }
        ProfileCommand::Discard { name, generation } => {
            payload.action = "discard";
            payload.profile_name = Some(name);
            payload.generation_id = Some(generation);
        }
        ProfileCommand::Uninstall { name, confirm, .. } => {
            payload.action = "uninstall";
            payload.profile_name = Some(name);
            payload.preview = Some(!confirm);
        }
    }
    payload
}

pub fn run(args: GardenArgs) -> Result<()> {
    let GardenArgs {
        socket,
        config_file,
        command,
    } = args;

    let socket = config::resolve_socket(socket, &config_file)?;
    if matches!(
        command,
        GardenCommand::Profile(ProfileArgs {
            command: ProfileCommand::Uninstall { confirm: true, .. }
        })
    ) {
        eprintln!(
            "Warning: external services are not stopped; published profile paths will disappear. Pinned generations must be unpinned explicitly."
        );
    }
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
        GardenCommand::Profile(profile) => {
            protocol::profile_request(id, profile_payload(&profile.command))
        }
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

#[cfg(test)]
mod profile_tests {
    use super::*;
    use clap::Parser;
    use serde_json::{Value, json};

    #[derive(Parser)]
    struct ProfileCli {
        #[command(flatten)]
        garden: GardenArgs,
    }

    #[test]
    fn generation_operands_accept_generated_leading_hyphen_ids() {
        let generation = "-_z080SRawQZ90rupcWcpg";
        for action in ["select", "rollback", "pin", "unpin", "discard"] {
            let parsed = ProfileCli::try_parse_from([
                "sower-garden",
                "profile",
                action,
                "shell-a",
                generation,
            ])
            .unwrap();
            let value: Value = serde_json::from_str(
                &build_request_line("hyphen-id", &parsed.garden.command).unwrap(),
            )
            .unwrap();
            assert_eq!(value["payload"]["generation_id"], generation);
            assert_eq!(value["payload"]["action"], action);
        }
    }

    fn request(command: ProfileCommand) -> Value {
        serde_json::from_str(
            &build_request_line(
                "profile-test",
                &GardenCommand::Profile(ProfileArgs { command }),
            )
            .unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn list_reads_local_inventory_without_a_subscription() {
        assert_eq!(
            request(ProfileCommand::List),
            json!({"v": 1, "id": "profile-test", "kind": "profile",
                   "payload": {"action": "list"}})
        );
    }

    #[test]
    fn stage_preserves_explicit_destination_and_seed() {
        let value = request(ProfileCommand::Stage {
            name: "tools".into(),
            subscription_sid: "subscription".into(),
            seed_sid: Some("seed".into()),
        });
        assert_eq!(
            value["payload"],
            json!({
                "action": "stage", "profile_name": "tools",
                "subscription_sid": "subscription", "seed_sid": "seed"
            })
        );
    }

    #[test]
    fn generation_operations_keep_profile_local_identity() {
        for (action, command) in [
            (
                "select",
                ProfileCommand::Select {
                    name: "tools".into(),
                    generation: "generation-id".into(),
                },
            ),
            (
                "rollback",
                ProfileCommand::Rollback {
                    name: "tools".into(),
                    generation: "generation-id".into(),
                },
            ),
            (
                "pin",
                ProfileCommand::Pin {
                    name: "tools".into(),
                    generation: "generation-id".into(),
                },
            ),
            (
                "unpin",
                ProfileCommand::Unpin {
                    name: "tools".into(),
                    generation: "generation-id".into(),
                },
            ),
            (
                "discard",
                ProfileCommand::Discard {
                    name: "tools".into(),
                    generation: "generation-id".into(),
                },
            ),
        ] {
            assert_eq!(
                request(command)["payload"],
                json!({
                    "action": action, "profile_name": "tools", "generation_id": "generation-id"
                })
            );
        }
    }

    #[test]
    fn uninstall_requires_separate_confirmation_and_never_releases_pins() {
        for confirm in [false, true] {
            assert_eq!(
                request(ProfileCommand::Uninstall {
                    name: "tools".into(),
                    confirm,
                    preview: false
                })["payload"],
                json!({"action": "uninstall", "profile_name": "tools", "preview": !confirm})
            );
        }
    }
}
