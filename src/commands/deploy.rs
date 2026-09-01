//! `sower deploy` — put one configuration onto one host.
//!
//! The primitive is `--seed <sid>`, which is pure control plane: register
//! nothing, build nothing, just ask the server to deploy a seed at a garden.
//! A flake reference or `--path` are conveniences that build and/or register a
//! seed first. The CLI never evaluates policy and never decides an outcome —
//! the server gates and the garden reports.

use anyhow::{Context, Result, anyhow, bail};
use clap::{Args, ValueEnum};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::api::{Client, types};
use crate::commands::client::ConnectionArgs;
use crate::commands::seed::{SeedType, parse_tags};

const POLL_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Debug, Args)]
pub struct DeployArgs {
    /// Flake reference to build, e.g. `.#myhost`. A bare attribute expands to
    /// `nixosConfigurations.<attr>.config.system.build.toplevel`.
    flake: Option<String>,

    #[command(flatten)]
    connection: ConnectionArgs,

    /// Garden to deploy to: sid (grdn_…) or name. Defaults to a single-segment
    /// flake attribute, so `.#myhost` deploys to the garden named `myhost`.
    #[arg(long = "to")]
    to: Option<String>,

    /// Deploy an already-registered seed. No nix is run.
    #[arg(long, conflicts_with_all = ["flake", "path", "copy_to", "tags"])]
    seed: Option<String>,

    /// Deploy an already-built store path instead of building one.
    #[arg(long = "path", short = 'p', conflicts_with = "flake")]
    path: Option<PathBuf>,

    /// Copy the closure to a nix store URI before deploying,
    /// e.g. `ssh://root@host` or `s3://bucket`.
    #[arg(long = "copy-to")]
    copy_to: Option<String>,

    /// Seed name. Defaults to the flake attribute or the store path's hostname.
    #[arg(long, short = 'n')]
    name: Option<String>,

    /// Seed type: nixos | home-manager | nix-darwin | service
    #[arg(long = "type", short = 't', default_value = "nixos")]
    seed_type: SeedType,

    /// Tags in `key=value` format. May be repeated.
    #[arg(long = "tag")]
    tags: Vec<String>,

    /// Requested action. Required when overriding policy.
    #[arg(long)]
    action: Option<DeployAction>,

    /// Deploy even when an identical closure was already deployed.
    #[arg(long)]
    force: bool,

    /// Break glass: bypass the garden's policy. Requires --action and --reason.
    #[arg(long = "override")]
    override_policy: bool,

    /// Why policy is being bypassed. Recorded in the audit trail.
    #[arg(long)]
    reason: Option<String>,

    /// Print the deployment sid and exit instead of waiting for a result.
    #[arg(long = "no-wait")]
    no_wait: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum DeployAction {
    Stage,
    Activate,
    Restart,
}

impl DeployAction {
    fn into_api(self) -> types::DirectDeploymentAction {
        match self {
            DeployAction::Stage => types::DirectDeploymentAction::Stage,
            DeployAction::Activate => types::DirectDeploymentAction::Activate,
            DeployAction::Restart => types::DirectDeploymentAction::Restart,
        }
    }
}

pub fn run(args: DeployArgs) -> Result<()> {
    validate(&args)?;
    let garden = resolve_garden(&args)?;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build tokio runtime")?;

    rt.block_on(async move {
        let client = args.connection.authenticated_client()?;
        let seed_sid = resolve_seed(&client, &args).await?;
        deploy(&client, &args, &garden, &seed_sid).await
    })
}

fn validate(args: &DeployArgs) -> Result<()> {
    if args.seed.is_none() && args.path.is_none() && args.flake.is_none() {
        bail!("nothing to deploy: pass a flake reference, --path or --seed");
    }
    if args.override_policy && (args.reason.is_none() || args.action.is_none()) {
        bail!("--override requires both --action and --reason");
    }
    Ok(())
}

async fn resolve_seed(client: &Client, args: &DeployArgs) -> Result<String> {
    if let Some(sid) = &args.seed {
        return Ok(sid.clone());
    }

    let (artifact, inferred_name) = match (&args.path, &args.flake) {
        (Some(path), _) => (store_path(path)?, None),
        (None, Some(flake)) => {
            let (installable, name) = flake_installable(flake)?;
            (nix_build(&installable)?, name)
        }
        (None, None) => unreachable!("validated above"),
    };

    crate::commands::seed::precheck(Path::new(&artifact), args.seed_type)
        .context("pre-check artifact")?;

    if let Some(target) = &args.copy_to {
        nix_copy(&artifact, target)?;
    }

    let name = args
        .name
        .clone()
        .or(inferred_name)
        .or_else(|| infer_name(&artifact))
        .ok_or_else(|| anyhow!("cannot infer a seed name from {artifact}; pass --name"))?;

    let body = types::Seed {
        artifact,
        name,
        seed_type: args.seed_type.into_api(),
        sid: None,
        tags: parse_tags(&args.tags)?,
    };

    let seed = client
        .new_seed(None, &body)
        .await
        .context("create seed")?
        .into_inner();

    let sid = seed
        .sid
        .ok_or_else(|| anyhow!("server returned a seed without a sid"))?;
    tracing::info!(name = %seed.name, sid = %sid, "Registered seed");
    Ok(sid)
}

/// The garden a bare `.#myhost` implies. Anything more qualified than a single
/// attribute names a nix output, not a host, so it infers nothing.
fn resolve_garden(args: &DeployArgs) -> Result<String> {
    if let Some(to) = &args.to {
        return Ok(to.clone());
    }

    args.flake
        .as_deref()
        .and_then(|reference| reference.split_once('#'))
        .map(|(_, attr)| attr)
        .filter(|attr| !attr.is_empty() && !attr.contains('.'))
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("missing --to: no garden to deploy to"))
}

async fn deploy(client: &Client, args: &DeployArgs, garden: &str, seed_sid: &str) -> Result<()> {
    let body = types::DirectDeployment {
        action: args.action.map(DeployAction::into_api),
        force: args.force,
        garden: garden.to_owned(),
        override_: args.override_policy,
        reason: args.reason.clone(),
        seed: seed_sid.to_owned(),
    };

    let deployment = client
        .new_deployment(&body)
        .await
        .context("create deployment")?
        .into_inner();

    if deployment.skipped {
        tracing::info!(sid = %deployment.sid, "Matched an existing deployment; nothing dispatched");
    }

    if args.no_wait {
        println!("{}", deployment.sid);
        return Ok(());
    }

    wait(client, deployment).await
}

async fn wait(client: &Client, initial: types::DeploymentInfo) -> Result<()> {
    let sid = initial.sid.clone();
    let mut seen: HashMap<String, String> = HashMap::new();
    let mut info = initial;

    loop {
        report(&info, &mut seen);

        if let Some(result) = terminal_result(&info) {
            return match result.as_str() {
                "success" => Ok(()),
                other => bail!("deployment {sid} finished with result {other}"),
            };
        }

        tokio::time::sleep(POLL_INTERVAL).await;
        info = client
            .get_deployment(&sid)
            .await
            .context("poll deployment")?
            .into_inner();
    }
}

/// A deployment is done once it leaves the dispatchable states. `stale` and
/// `canceled` carry no result of their own, so they read as failures.
fn terminal_result(info: &types::DeploymentInfo) -> Option<String> {
    match info.state.as_str() {
        "created" | "dispatched" | "acknowledged" => None,
        "completed" => Some(info.result.clone().unwrap_or_else(|| "failure".to_owned())),
        other => Some(other.to_owned()),
    }
}

fn report(info: &types::DeploymentInfo, seen: &mut HashMap<String, String>) {
    for seed in &info.seeds {
        let state = seed.state.clone().unwrap_or_else(|| "pending".to_owned());
        if seen.get(&seed.seed_sid) == Some(&state) {
            continue;
        }
        seen.insert(seed.seed_sid.clone(), state.clone());
        tracing::info!(seed = %seed.name, state = %state, result = ?seed.result, "Deployment");
        if seed.result.as_deref() == Some("failure")
            && let Some(log) = &seed.log
        {
            eprintln!("{log}");
        }
    }
}

/// Split a flake reference into the installable to build and the seed name it
/// implies. A bare attribute is expanded the way nixos-rebuild and colmena do;
/// an attribute containing a `.` is passed through untouched.
fn flake_installable(reference: &str) -> Result<(String, Option<String>)> {
    let (flake, attr) = reference.split_once('#').ok_or_else(|| {
        anyhow!("{reference:?} has no attribute; expected something like `.#myhost`")
    })?;
    if attr.is_empty() {
        bail!("{reference:?} has an empty attribute");
    }

    if attr.contains('.') {
        let name = attr
            .strip_prefix("nixosConfigurations.")
            .and_then(|rest| rest.split('.').next())
            .map(str::to_owned);
        return Ok((reference.to_owned(), name));
    }

    Ok((
        format!("{flake}#nixosConfigurations.{attr}.config.system.build.toplevel"),
        Some(attr.to_owned()),
    ))
}

/// `/nix/store/<hash>-nixos-system-<host>-<version>` names the host it was
/// built for; that is the seed name when nothing better is available.
fn infer_name(artifact: &str) -> Option<String> {
    let base = Path::new(artifact).file_name()?.to_str()?;
    let rest = base.split_once("-nixos-system-")?.1;
    let host = rest.rsplit_once('-')?.0;
    (!host.is_empty()).then(|| host.to_owned())
}

fn store_path(path: &Path) -> Result<String> {
    path.to_str()
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("path is not valid UTF-8: {}", path.display()))
}

fn nix_build(installable: &str) -> Result<String> {
    tracing::info!(installable, "Building");
    let out = Command::new("nix")
        .args(["build", "--no-link", "--print-out-paths", installable])
        .output()
        .context("spawn nix build")?;

    if !out.status.success() {
        std::io::Write::write_all(&mut std::io::stderr(), &out.stderr).ok();
        bail!("nix build failed with status {}", out.status);
    }

    let stdout = String::from_utf8(out.stdout).context("nix build output is not UTF-8")?;
    stdout
        .lines()
        .last()
        .map(str::to_owned)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("nix build printed no store path for {installable}"))
}

fn nix_copy(artifact: &str, target: &str) -> Result<()> {
    tracing::info!(target, "Copying closure");
    let mut cmd = Command::new("nix");
    cmd.args(["copy", "--to", target, artifact]);
    crate::commands::seed::run_inherited(cmd).context("nix copy")
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[derive(Parser)]
    struct TestCli {
        #[command(flatten)]
        args: DeployArgs,
    }

    fn parse(argv: &[&str]) -> Result<DeployArgs> {
        let cli = TestCli::try_parse_from(std::iter::once("deploy").chain(argv.iter().copied()))
            .map_err(|e| anyhow!(e.to_string()))?;
        validate(&cli.args)?;
        Ok(cli.args)
    }

    #[test]
    fn a_bare_flake_attr_names_the_garden() {
        let args = parse(&[".#myhost"]).unwrap();
        assert_eq!(resolve_garden(&args).unwrap(), "myhost");
    }

    #[test]
    fn to_overrides_the_flake_attr() {
        let args = parse(&[".#myhost", "--to", "grdn_1"]).unwrap();
        assert_eq!(resolve_garden(&args).unwrap(), "grdn_1");
    }

    #[test]
    fn a_dotted_flake_attr_infers_no_garden() {
        let args = parse(&[".#nixosConfigurations.myhost.config.system.build.toplevel"]).unwrap();
        let err = resolve_garden(&args).unwrap_err();
        assert!(err.to_string().contains("missing --to"), "{err}");
    }

    #[test]
    fn path_and_seed_sources_require_to() {
        let args = parse(&["--path", "/nix/store/x"]).unwrap();
        assert!(resolve_garden(&args).is_err());

        let args = parse(&["--seed", "seed_1"]).unwrap();
        assert!(resolve_garden(&args).is_err());
    }

    #[test]
    fn a_source_is_required() {
        let err = parse(&["--to", "myhost"]).unwrap_err();
        assert!(err.to_string().contains("nothing to deploy"), "{err}");
    }

    #[test]
    fn seed_sid_alone_is_enough() {
        let args = parse(&["--to", "myhost", "--seed", "seed_1"]).unwrap();
        assert_eq!(args.seed.as_deref(), Some("seed_1"));
    }

    #[test]
    fn seed_sid_conflicts_with_building() {
        assert!(parse(&["--to", "myhost", "--seed", "seed_1", ".#myhost"]).is_err());
        assert!(
            parse(&[
                "--to",
                "myhost",
                "--seed",
                "seed_1",
                "--path",
                "/nix/store/x"
            ])
            .is_err()
        );
        assert!(parse(&["--to", "myhost", "--seed", "seed_1", "--copy-to", "ssh://h"]).is_err());
    }

    #[test]
    fn flake_and_path_conflict() {
        assert!(parse(&["--to", "myhost", ".#myhost", "--path", "/nix/store/x"]).is_err());
    }

    #[test]
    fn override_requires_action_and_reason() {
        let base = ["--to", "myhost", "--seed", "seed_1", "--override"];
        let err = parse(&base).unwrap_err();
        assert!(err.to_string().contains("requires both"), "{err}");

        let mut with_reason = base.to_vec();
        with_reason.extend(["--reason", "incident 4412"]);
        assert!(parse(&with_reason).is_err());

        let mut both = with_reason.clone();
        both.extend(["--action", "activate"]);
        let args = parse(&both).unwrap();
        assert!(args.override_policy);
        assert_eq!(args.action, Some(DeployAction::Activate));
    }

    #[test]
    fn seed_type_defaults_to_nixos() {
        let args = parse(&["--to", "myhost", ".#myhost"]).unwrap();
        assert_eq!(args.seed_type.as_str(), "nixos");
    }

    fn info(state: &str, result: Option<&str>) -> types::DeploymentInfo {
        types::DeploymentInfo {
            deployed_at: None,
            garden_sid: "grdn_1".to_owned(),
            result: result.map(str::to_owned),
            seeds: vec![],
            sid: "dply_1".to_owned(),
            skipped: false,
            state: state.to_owned(),
        }
    }

    #[test]
    fn bare_attr_expands_to_toplevel() {
        let (installable, name) = flake_installable(".#myhost").unwrap();
        assert_eq!(
            installable,
            ".#nixosConfigurations.myhost.config.system.build.toplevel"
        );
        assert_eq!(name.as_deref(), Some("myhost"));
    }

    #[test]
    fn bare_attr_expands_for_remote_flakes() {
        let (installable, name) = flake_installable("github:org/repo#myhost").unwrap();
        assert_eq!(
            installable,
            "github:org/repo#nixosConfigurations.myhost.config.system.build.toplevel"
        );
        assert_eq!(name.as_deref(), Some("myhost"));
    }

    #[test]
    fn dotted_attr_passes_through() {
        let (installable, name) =
            flake_installable(".#nixosConfigurations.myhost.config.system.build.toplevel").unwrap();
        assert_eq!(
            installable,
            ".#nixosConfigurations.myhost.config.system.build.toplevel"
        );
        assert_eq!(name.as_deref(), Some("myhost"));
    }

    #[test]
    fn dotted_attr_outside_nixos_configurations_has_no_name() {
        let (installable, name) = flake_installable(".#packages.x86_64-linux.thing").unwrap();
        assert_eq!(installable, ".#packages.x86_64-linux.thing");
        assert_eq!(name, None);
    }

    #[test]
    fn missing_attr_errors() {
        let err = flake_installable(".").unwrap_err();
        assert!(err.to_string().contains("no attribute"), "{err}");
    }

    #[test]
    fn empty_attr_errors() {
        let err = flake_installable(".#").unwrap_err();
        assert!(err.to_string().contains("empty attribute"), "{err}");
    }

    #[test]
    fn infers_name_from_nixos_system_store_path() {
        let got = infer_name("/nix/store/abc123-nixos-system-myhost-25.05.20250101");
        assert_eq!(got.as_deref(), Some("myhost"));
    }

    #[test]
    fn infers_nothing_from_other_store_paths() {
        assert_eq!(infer_name("/nix/store/abc123-hello-2.12"), None);
    }

    #[test]
    fn in_flight_states_are_not_terminal() {
        for state in ["created", "dispatched", "acknowledged"] {
            assert_eq!(terminal_result(&info(state, None)), None, "{state}");
        }
    }

    #[test]
    fn completed_reports_its_result() {
        assert_eq!(
            terminal_result(&info("completed", Some("success"))),
            Some("success".to_owned())
        );
        assert_eq!(
            terminal_result(&info("completed", Some("partial"))),
            Some("partial".to_owned())
        );
    }

    #[test]
    fn completed_without_a_result_is_a_failure() {
        assert_eq!(
            terminal_result(&info("completed", None)),
            Some("failure".to_owned())
        );
    }

    #[test]
    fn stale_and_canceled_are_terminal() {
        assert_eq!(
            terminal_result(&info("stale", None)),
            Some("stale".to_owned())
        );
        assert_eq!(
            terminal_result(&info("canceled", None)),
            Some("canceled".to_owned())
        );
    }

    #[test]
    fn report_only_prints_changed_states() {
        let mut seen = HashMap::new();
        let mut d = info("dispatched", None);
        d.seeds.push(types::DeploymentSeedInfo {
            log: None,
            name: "myhost".to_owned(),
            result: None,
            seed_sid: "seed_1".to_owned(),
            seed_type: "nixos".to_owned(),
            state: Some("dispatched".to_owned()),
        });

        report(&d, &mut seen);
        assert_eq!(seen.get("seed_1").map(String::as_str), Some("dispatched"));

        d.seeds[0].state = Some("completed".to_owned());
        report(&d, &mut seen);
        assert_eq!(seen.get("seed_1").map(String::as_str), Some("completed"));
    }
}
