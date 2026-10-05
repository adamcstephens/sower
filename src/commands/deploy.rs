//! `sower deploy` — put one configuration onto one host.
//!
//! The primitive is `--seed <sid>`, which is pure control plane: register
//! nothing, build nothing, just ask the server to deploy a seed at a garden.
//! A flake reference or `--path` builds and/or registers a seed first.
//! `--sudo` instead copies and activates over SSH without server orchestration.

use anyhow::{Context, Result, anyhow, bail};
use clap::{Args, ValueEnum};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::api::{Client, types};
use crate::commands::activator::protocol::Request;
use crate::commands::client::ConnectionArgs;
use crate::commands::seed::{SeedType, parse_tags};

#[path = "deploy/sudo.rs"]
mod sudo;

const POLL_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Debug, Args)]
pub struct DeployArgs {
    /// Flake reference to build, e.g. `.#myhost` or `.#nixos/myhost`.
    /// Bare host attributes build a NixOS toplevel; nixos/, home/, and seed/
    /// jobs build wrappers whose seed.json identifies the deployable artifact.
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

    /// Do not substitute store paths from caches on the destination when copying.
    #[arg(long)]
    no_substitute_on_destination: bool,

    /// Skip downloading the garden's latest matching seed before building a flake.
    #[arg(long)]
    no_seed_download: bool,

    /// Activate as root over SSH with interactive sudo instead of using the garden.
    /// Requires --copy-to ssh://[user@]host; no server deployment is created.
    #[arg(
        long,
        requires = "copy_to",
        conflicts_with_all = [
            "seed", "to", "name", "tags", "action", "force",
            "override_policy", "reason", "no_wait"
        ]
    )]
    sudo: bool,

    /// Seed name. Defaults to the flake attribute or the store path's hostname.
    #[arg(long, short = 'n')]
    name: Option<String>,

    /// Seed type: nixos | home-manager | nix-darwin | service.
    /// Defaults to the wrapper manifest's type, or nixos for raw artifacts.
    #[arg(long = "type", short = 't')]
    seed_type: Option<SeedType>,

    /// Tags in `key=value` format. May be repeated.
    #[arg(long = "tag")]
    tags: Vec<String>,

    /// Requested action: stage, activate (default), or restart.
    /// Without --override, the garden's direct policy must permit it.
    /// Restart does not require --override; policy windows and confirmation still apply.
    /// Required explicitly when overriding policy.
    #[arg(long)]
    action: Option<DeployAction>,

    /// Deploy even when an identical closure was already deployed.
    #[arg(long)]
    force: bool,

    /// Break glass: bypass deployment policy on both server and garden.
    /// Requires override permission, --action, --reason, and a connected garden
    /// advertising override support. Older gardens must be upgraded first.
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
    if args.sudo {
        return deploy_sudo(&args);
    }
    let garden = resolve_garden(&args)?;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build tokio runtime")?;

    rt.block_on(async move {
        let client = args.connection.authenticated_client()?;
        warm_seed(&client, &args, &garden).await;
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
    if args.sudo {
        sudo::validate_target(args.copy_to.as_deref().expect("required by clap"))?;
        if args
            .seed_type
            .is_some_and(|kind| !matches!(kind, SeedType::Nixos | SeedType::HomeManager))
        {
            bail!("--sudo supports nixos and home-manager activation");
        }
    }
    Ok(())
}

fn deploy_sudo(args: &DeployArgs) -> Result<()> {
    let endpoint = args.connection.endpoint()?;
    let prepared = prepare_artifact(args)?;
    let request = Request {
        id: "sudo-deploy".to_owned(),
        kind: prepared.seed_type.as_str().to_owned(),
        path: prepared.artifact,
        mode: "switch".to_owned(),
        reason: String::new(),
        seeds: Vec::new(),
    };
    tracing::warn!("Sudo deployment bypasses garden policy and server reporting");
    sudo::run(
        args.copy_to.as_deref().expect("required by clap"),
        &serde_json::to_string(&request)?,
        endpoint.as_deref(),
    )?;
    tracing::info!(
        "Activation succeeded; garden health and pending server deployments are unchanged"
    );
    Ok(())
}

struct PreparedArtifact {
    artifact: String,
    name: Option<String>,
    seed_type: SeedType,
    tags: Vec<types::SeedTag>,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct SeedManifest {
    version: u64,
    name: String,
    seed_type: SeedType,
    artifact: String,
    tags: BTreeMap<String, String>,
}

impl SeedManifest {
    fn parse(json: &str) -> Result<Self> {
        let manifest: Self = serde_json::from_str(json).context("decode seed manifest")?;
        if manifest.version != 1 {
            bail!(
                "unsupported seed manifest version {}; expected 1",
                manifest.version
            );
        }
        if manifest.name.is_empty() {
            bail!("seed manifest name must not be empty");
        }
        let valid_artifact = manifest
            .artifact
            .strip_prefix("/nix/store/")
            .and_then(|path| path.split_once('-'))
            .is_some_and(|(hash, name)| {
                hash.len() == 32
                    && hash
                        .bytes()
                        .all(|byte| b"0123456789abcdfghijklmnpqrsvwxyz".contains(&byte))
                    && !name.is_empty()
                    && !name.contains('/')
            });
        if !valid_artifact {
            bail!("seed manifest artifact must be a top-level Nix store path");
        }
        Ok(manifest)
    }
}

fn prepare_artifact(args: &DeployArgs) -> Result<PreparedArtifact> {
    let (built_path, inferred_name, canonical) = match (&args.path, &args.flake) {
        (Some(path), _) => (
            store_path(path)?,
            None,
            path.join("seed.json").try_exists()?,
        ),
        (None, Some(flake)) => {
            let (installable, name) = flake_installable(flake)?;
            let canonical = flake
                .split_once('#')
                .is_some_and(|(_, attr)| canonical_job(attr).is_some());
            (nix_build(&installable)?, name, canonical)
        }
        (None, None) => unreachable!("validated above"),
    };

    let mut tags = parse_tags(&args.tags)?;
    let (artifact, name, seed_type) = if canonical {
        let manifest_path = Path::new(&built_path).join("seed.json");
        let json = std::fs::read_to_string(&manifest_path)
            .with_context(|| format!("read seed manifest {}", manifest_path.display()))?;
        let manifest = SeedManifest::parse(&json)
            .with_context(|| format!("validate seed manifest {}", manifest_path.display()))?;
        tags.extend(
            manifest
                .tags
                .into_iter()
                .map(|(key, value)| types::SeedTag { key, value }),
        );
        (
            manifest.artifact,
            Some(manifest.name),
            args.seed_type.unwrap_or(manifest.seed_type),
        )
    } else {
        (
            built_path,
            inferred_name,
            args.seed_type.unwrap_or(SeedType::Nixos),
        )
    };

    if args.sudo && !matches!(seed_type, SeedType::Nixos | SeedType::HomeManager) {
        bail!("--sudo supports nixos and home-manager activation");
    }
    crate::commands::seed::precheck(Path::new(&artifact), seed_type)
        .context("pre-check artifact")?;

    if let Some(target) = &args.copy_to {
        nix_copy(&artifact, target, !args.no_substitute_on_destination)?;
    }
    Ok(PreparedArtifact {
        artifact,
        name,
        seed_type,
        tags,
    })
}

async fn warm_seed(client: &Client, args: &DeployArgs, garden: &str) {
    if args.no_seed_download || args.seed.is_some() || args.sudo {
        return;
    }
    let Some(flake) = args.flake.as_deref() else {
        return;
    };
    let name = match flake_installable(flake) {
        Ok((_, inferred)) => args
            .name
            .as_deref()
            .or(inferred.as_deref())
            .map(str::to_owned),
        Err(_) => return,
    };
    let Some(name) = name else {
        tracing::warn!("Cannot infer a seed name before building; skipping seed download");
        return;
    };
    let seed_type = args.seed_type.unwrap_or_else(|| {
        if flake
            .split_once('#')
            .and_then(|(_, attr)| canonical_job(attr))
            .is_some_and(|(namespace, _)| namespace == "home")
        {
            SeedType::HomeManager
        } else {
            SeedType::Nixos
        }
    });
    if args.seed_type.is_none()
        && flake
            .split_once('#')
            .and_then(|(_, attr)| canonical_job(attr))
            .is_some_and(|(namespace, _)| namespace == "seed")
    {
        return;
    }
    if let Err(error) = download_previous_seed(client, garden, &name, seed_type).await {
        tracing::warn!(%error, "Could not download previous seed; continuing with flake build");
    }
}

async fn download_previous_seed(
    client: &Client,
    garden: &str,
    name: &str,
    seed_type: SeedType,
) -> Result<()> {
    let mut url = reqwest::Url::parse(&format!(
        "{}/api/v1/gardens",
        client.baseurl.trim_end_matches('/')
    ))?;
    url.path_segments_mut()
        .map_err(|_| anyhow!("server endpoint cannot be used as a URL path"))?
        .push(garden)
        .push("latest-seed");
    url.query_pairs_mut()
        .append_pair("name", name)
        .append_pair("seed_type", seed_type.as_str());
    let response = client
        .client
        .get(url)
        .send()
        .await
        .context("look up garden's latest seed")?;
    if response.status() == reqwest::StatusCode::NO_CONTENT {
        tracing::info!(garden, name, "No matching seed to download");
        return Ok(());
    }
    let response = response
        .error_for_status()
        .context("look up garden's latest seed")?;
    let seed: types::Seed = response
        .json()
        .await
        .context("decode garden's latest seed")?;
    let caches = client
        .list_nix_caches()
        .await
        .context("list nix caches")?
        .into_inner();
    crate::commands::seed::realize(&seed.artifact, &caches, false, None)
        .with_context(|| format!("realize previous seed {}", seed.artifact))?;
    tracing::info!(name = %seed.name, artifact = %seed.artifact, "Downloaded previous seed");
    Ok(())
}

async fn resolve_seed(client: &Client, args: &DeployArgs) -> Result<String> {
    if let Some(sid) = &args.seed {
        return Ok(sid.clone());
    }

    let prepared = prepare_artifact(args)?;
    let artifact = prepared.artifact;
    let name = args
        .name
        .clone()
        .or(prepared.name)
        .or_else(|| infer_name(&artifact))
        .ok_or_else(|| anyhow!("cannot infer a seed name from {artifact}; pass --name"))?;

    let body = types::Seed {
        artifact,
        name,
        seed_type: prepared.seed_type.into_api(),
        sid: None,
        tags: prepared.tags,
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

/// Bare hosts and canonical job names imply a garden. Qualified raw attributes
/// name a Nix output rather than a host, so they infer nothing.
fn resolve_garden(args: &DeployArgs) -> Result<String> {
    if let Some(to) = &args.to {
        return Ok(to.clone());
    }

    args.flake
        .as_deref()
        .and_then(|reference| reference.split_once('#'))
        .map(|(_, attr)| attr)
        .and_then(|attr| {
            canonical_job(attr).map(|(_, name)| name).or_else(|| {
                let mut components = attribute_components(attr);
                let name = components.next()?;
                (!name.is_empty() && components.next().is_none()).then(|| unquote_component(name))
            })
        })
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

    let mut url = reqwest::Url::parse(&client.baseurl)?;
    let _ = url.set_username("");
    let _ = url.set_password(None);
    url.set_query(None);
    url.set_fragment(None);
    url.set_path(&format!(
        "{}/deployments/{}",
        url.path().trim_end_matches('/'),
        deployment.sid
    ));
    eprintln!("Deployment: {url}");

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
                other => {
                    failure_logs(client, &info).await;
                    bail!("deployment {sid} finished with result {other}")
                }
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
    }
}

async fn failure_logs(client: &Client, last_known: &types::DeploymentInfo) {
    let latest = match client.get_deployment(&last_known.sid).await {
        Ok(response) => response.into_inner(),
        Err(_) => {
            eprintln!("Could not fetch deployment logs; using last known logs.");
            print_log_tails(last_known);
            return;
        }
    };
    print_log_tails(&latest);
}

fn print_log_tails(info: &types::DeploymentInfo) {
    let has_failed_seed = info
        .seeds
        .iter()
        .any(|seed| seed.result.as_deref() == Some("failure"));
    let mut printed = false;
    for seed in &info.seeds {
        if has_failed_seed && seed.result.as_deref() != Some("failure") {
            continue;
        }
        if let Some(log) = seed.log.as_deref().filter(|log| !log.is_empty()) {
            eprintln!("Logs for {} ({}):", seed.name, seed.seed_sid);
            let tail_bytes: usize = log.split_inclusive('\n').rev().take(50).map(str::len).sum();
            for line in log[log.len() - tail_bytes..].lines() {
                eprintln!("{line}");
            }
            printed = true;
        }
    }
    if !printed {
        eprintln!("No deployment logs available.");
    }
}

/// Dots inside quoted Nix attribute components belong to the component's name.
fn attribute_components(attr: &str) -> impl Iterator<Item = &str> {
    let mut quoted = false;
    let mut escaped = false;
    attr.split(move |character| {
        if escaped {
            escaped = false;
            return false;
        }
        match character {
            '\\' if quoted => escaped = true,
            '"' => quoted = !quoted,
            '.' if !quoted => return true,
            _ => {}
        }
        false
    })
}

fn unquote_component(component: &str) -> &str {
    component
        .strip_prefix('"')
        .and_then(|component| component.strip_suffix('"'))
        .unwrap_or(component)
}

/// Canonical jobs may be selected directly or beneath a qualified flake output.
fn canonical_job(attr: &str) -> Option<(&str, &str)> {
    let (prefix, name) = attr.split_once('/')?;
    let component = attribute_components(prefix).last()?;
    let (namespace, name) = if let Some(namespace) = component.strip_prefix('"') {
        let name = name.strip_suffix('"')?;
        if name.contains('"') {
            return None;
        }
        (namespace, name)
    } else {
        (component, name)
    };
    (!name.is_empty() && matches!(namespace, "nixos" | "home" | "seed"))
        .then_some((namespace, name))
}

/// Split a flake reference into the installable to build and the seed name it
/// implies. Canonical jobs and qualified outputs are passed through untouched;
/// a bare host attribute is expanded the way nixos-rebuild and colmena do.
fn flake_installable(reference: &str) -> Result<(String, Option<String>)> {
    let (flake, attr) = reference.split_once('#').ok_or_else(|| {
        anyhow!("{reference:?} has no attribute; expected something like `.#myhost`")
    })?;
    if attr.is_empty() {
        bail!("{reference:?} has an empty attribute");
    }

    if let Some((_, name)) = canonical_job(attr) {
        return Ok((reference.to_owned(), Some(name.to_owned())));
    }

    let mut components = attribute_components(attr);
    let first = components.next().expect("nonempty attribute");
    if let Some(second) = components.next() {
        let name = (first == "nixosConfigurations").then(|| unquote_component(second).to_owned());
        return Ok((reference.to_owned(), name));
    }

    Ok((
        format!("{flake}#nixosConfigurations.{attr}.config.system.build.toplevel"),
        Some(unquote_component(attr).to_owned()),
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
    let build_args = ["build", "--no-link", "--print-out-paths"];
    let (program, out) = match Command::new("nom")
        .args(build_args)
        .arg(installable)
        .stderr(Stdio::inherit())
        .output()
    {
        Ok(out) => ("nom", out),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::PermissionDenied
            ) =>
        {
            let out = Command::new("nix")
                .args(build_args)
                .arg("--print-build-logs")
                .arg(installable)
                .stderr(Stdio::inherit())
                .output()
                .context("spawn nix build")?;
            ("nix", out)
        }
        Err(error) => return Err(error).context("spawn nom build"),
    };

    if !out.status.success() {
        bail!("{program} build failed with status {}", out.status);
    }

    let stdout = String::from_utf8(out.stdout)
        .with_context(|| format!("{program} build output is not UTF-8"))?;
    stdout
        .lines()
        .last()
        .map(str::to_owned)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("{program} build printed no store path for {installable}"))
}

fn nix_copy(artifact: &str, target: &str, substitute_on_destination: bool) -> Result<()> {
    tracing::info!(target, "Copying closure");
    let mut cmd = Command::new("nix");
    cmd.args(["copy", "--to", target]);
    if substitute_on_destination {
        cmd.arg("--substitute-on-destination");
    }
    cmd.arg(artifact);
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
    fn sudo_deployment_uses_an_explicit_ssh_store_target() {
        assert!(parse(&[".#worker3", "--copy-to", "ssh://worker3", "--sudo"]).is_ok());
        assert!(parse(&[".#worker3", "--sudo"]).is_err());
        assert!(parse(&[".#worker3", "--copy-to", "s3://bucket", "--sudo"]).is_err());
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
    fn canonical_jobs_select_wrappers_and_infer_gardens() {
        for reference in [
            ".#nixos/host",
            ".#home/host",
            ".#seed/host",
            ".#packages.x86_64-linux.nixos/host",
            ".#\"nixos/host\"",
            ".#\"home/host\"",
            ".#\"seed/host\"",
            ".#packages.x86_64-linux.\"nixos/host\"",
            ".#packages.x86_64-linux.\"home/host\"",
            ".#packages.x86_64-linux.\"seed/host\"",
        ] {
            let (installable, name) = flake_installable(reference).unwrap();
            assert_eq!(installable, reference);
            assert_eq!(name.as_deref(), Some("host"));
            let args = parse(&[reference]).unwrap();
            assert_eq!(resolve_garden(&args).unwrap(), "host");
        }
    }

    #[test]
    fn quoted_canonical_jobs_preserve_dotted_names_without_quotes() {
        for namespace in ["nixos", "home", "seed"] {
            for qualifier in ["", "packages.x86_64-linux.", "packages.\"system.name\"."] {
                let reference = format!(".#{qualifier}\"{namespace}/host.example\"");
                let (installable, name) = flake_installable(&reference).unwrap();
                assert_eq!(installable, reference);
                assert_eq!(name.as_deref(), Some("host.example"));
                let args = parse(&[&reference]).unwrap();
                assert_eq!(resolve_garden(&args).unwrap(), "host.example");

                let args = parse(&[&reference, "--to", "explicit-garden"]).unwrap();
                assert_eq!(resolve_garden(&args).unwrap(), "explicit-garden");
            }
        }
    }

    #[test]
    fn quoted_nixos_configuration_names_leave_raw_installables_unchanged() {
        let reference = ".#nixosConfigurations.\"host.example\".config.system.build.toplevel";
        let (installable, name) = flake_installable(reference).unwrap();
        assert_eq!(installable, reference);
        assert_eq!(name.as_deref(), Some("host.example"));
        assert!(resolve_garden(&parse(&[reference]).unwrap()).is_err());
    }

    #[test]
    fn manifests_require_every_schema_field_with_its_json_type() {
        let payload = serde_json::json!({
            "version": 1,
            "name": "host",
            "seed_type": "nixos",
            "artifact": "/nix/store/00000000000000000000000000000000-target",
            "tags": {"owner": "alice"}
        });
        for field in ["version", "name", "seed_type", "artifact", "tags"] {
            let mut missing = payload.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(
                SeedManifest::parse(&missing.to_string()).is_err(),
                "{field}"
            );
            for invalid in [serde_json::Value::Null, serde_json::json!([])] {
                let mut wrong_type = payload.clone();
                wrong_type[field] = invalid;
                assert!(
                    SeedManifest::parse(&wrong_type.to_string()).is_err(),
                    "{field}"
                );
            }
        }
        for (field, invalid) in [
            ("version", serde_json::json!("1")),
            ("version", serde_json::json!(2)),
            ("name", serde_json::json!("")),
            ("seed_type", serde_json::json!("unsupported")),
            ("tags", serde_json::json!({"owner": 7})),
            ("unexpected", serde_json::json!(true)),
        ] {
            let mut invalid_payload = payload.clone();
            invalid_payload[field] = invalid;
            assert!(
                SeedManifest::parse(&invalid_payload.to_string()).is_err(),
                "{field}"
            );
        }
    }

    #[test]
    fn manifest_artifacts_must_be_top_level_nix_store_paths() {
        for artifact in [
            "/tmp/target",
            "/nix/store/0000000000000000000000000000000-target",
            "/nix/store/00000000000000000000000000000000-",
            "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-target",
            "/nix/store/00000000000000000000000000000000-target/bin",
        ] {
            let payload = serde_json::json!({
                "version": 1, "name": "host", "seed_type": "nixos",
                "artifact": artifact, "tags": {}
            });
            assert!(
                SeedManifest::parse(&payload.to_string()).is_err(),
                "{artifact}"
            );
        }
    }

    #[test]
    fn manifests_accept_supported_seed_types_and_string_tags() {
        for seed_type in ["nixos", "home-manager", "nix-darwin", "service"] {
            let payload = serde_json::json!({
                "version": 1, "name": "host", "seed_type": seed_type,
                "artifact": "/nix/store/00000000000000000000000000000000-target",
                "tags": {"owner": "alice"}
            });
            let manifest = SeedManifest::parse(&payload.to_string()).unwrap();
            assert_eq!(manifest.seed_type.as_str(), seed_type);
            assert_eq!(
                manifest.tags.get("owner").map(String::as_str),
                Some("alice")
            );
        }
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
}
