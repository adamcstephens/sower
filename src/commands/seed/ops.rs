use anyhow::{Context, Result, anyhow, bail};
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str::FromStr;

use crate::api::types;

#[derive(Clone, Copy, Debug)]
pub enum SeedType {
    Nixos,
    HomeManager,
    NixDarwin,
    Service,
}

impl SeedType {
    pub fn as_str(self) -> &'static str {
        match self {
            SeedType::Nixos => "nixos",
            SeedType::HomeManager => "home-manager",
            SeedType::NixDarwin => "nix-darwin",
            SeedType::Service => "service",
        }
    }

    pub fn into_api(self) -> types::SeedSeedType {
        match self {
            SeedType::Nixos => types::SeedSeedType::Nixos,
            SeedType::HomeManager => types::SeedSeedType::HomeManager,
            SeedType::NixDarwin => types::SeedSeedType::NixDarwin,
            SeedType::Service => types::SeedSeedType::Service,
        }
    }
}

impl fmt::Display for SeedType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for SeedType {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        match s {
            "nixos" => Ok(SeedType::Nixos),
            "home-manager" => Ok(SeedType::HomeManager),
            "nix-darwin" => Ok(SeedType::NixDarwin),
            "service" => Ok(SeedType::Service),
            other => Err(anyhow!(
                "unsupported seed type {other:?} (expected nixos | home-manager | nix-darwin | service)"
            )),
        }
    }
}

/// Verify a seed artifact has the structure expected for its type.
/// Mirrors `preCheckSeed` in cmd/cli/seed.go.
pub fn precheck(artifact: &Path, seed_type: SeedType) -> Result<()> {
    let marker: PathBuf = match seed_type {
        SeedType::HomeManager => artifact.join("hm-version"),
        SeedType::Nixos => artifact.join("nixos-version"),
        SeedType::Service => artifact.join(".sower/systemd"),
        SeedType::NixDarwin => bail!("nix-darwin submission is not supported"),
    };
    std::fs::metadata(&marker)
        .with_context(|| format!("missing artifact marker {}", marker.display()))?;
    Ok(())
}

/// Build `store_path` locally via `nix build`, optionally substituting from `caches`.
/// Mirrors `realize` in cmd/cli/seed.go.
pub fn realize(
    store_path: &str,
    caches: &[types::NixCache],
    initrd: bool,
    profile: Option<&str>,
) -> Result<()> {
    if store_path.is_empty() {
        bail!("cannot realize empty store path");
    }

    if Path::new(store_path).exists() {
        tracing::debug!(path = store_path, "Already realized");
        return Ok(());
    }

    let mut cmd = Command::new("nix");
    cmd.args(["build", store_path]);

    if initrd {
        cmd.args(["--store", "/sysroot"]);
    }

    let (substituters, public_keys) = caches_to_flags(caches);
    if !substituters.is_empty() {
        cmd.args(["--extra-substituters", &substituters.join(",")]);
    }
    if !public_keys.is_empty() {
        cmd.args(["--extra-trusted-public-keys", &public_keys.join(",")]);
    }

    if let Some(p) = profile {
        cmd.args(["--profile", p]);
    }

    run_inherited(cmd)
}

fn caches_to_flags(caches: &[types::NixCache]) -> (Vec<String>, Vec<String>) {
    let mut subs = Vec::new();
    let mut keys = Vec::new();
    for cache in caches {
        subs.push(cache.url.clone());
        keys.push(cache.public_key.clone());
    }
    (subs, keys)
}

/// Activate the realized store path for the given seed type.
/// Mirrors `activate` in cmd/cli/seed.go.
pub fn activate(seed_type: SeedType, store_path: &str, mode: &str) -> Result<()> {
    match seed_type {
        SeedType::HomeManager => {
            let cmd = Command::new(format!("{store_path}/activate"));
            run_inherited(cmd).context("activate home-manager generation")
        }
        SeedType::Nixos => {
            set_profile("/nix/var/nix/profiles/system", store_path)?;
            let mut cmd = Command::new(format!("{store_path}/bin/switch-to-configuration"));
            cmd.arg(mode);
            run_inherited(cmd).context("switch-to-configuration")
        }
        SeedType::NixDarwin | SeedType::Service => {
            bail!("activate for {seed_type} is not supported by this CLI")
        }
    }
}

fn set_profile(profile: &str, store_path: &str) -> Result<()> {
    let mut cmd = Command::new("nix-env");
    cmd.args(["--set", "--profile", profile, store_path]);
    run_inherited(cmd).context("set nix profile")
}

pub fn run_inherited(mut cmd: Command) -> Result<()> {
    tracing::debug!(cmd = ?cmd, "Running command");
    let status = cmd.status().context("spawn command")?;
    if !status.success() {
        bail!("command failed with status {status}");
    }
    Ok(())
}
