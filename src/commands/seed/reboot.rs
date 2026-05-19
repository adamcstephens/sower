use anyhow::{Context, Result};
use clap::Args as ClapArgs;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::ops::run_inherited;

#[derive(Debug, ClapArgs)]
pub struct Args {
    /// Schedule the reboot when one is needed.
    #[arg(long, short = 'y')]
    pub yes: bool,
}

pub fn run(args: Args) -> Result<()> {
    if !needs_reboot()? {
        tracing::debug!("No reboot needed");
        return Ok(());
    }

    if !args.yes {
        tracing::warn!("Reboot needed, but skipping without --yes");
        return Ok(());
    }

    tracing::info!("Scheduling reboot in ~5 seconds");
    let mut cmd = Command::new("systemd-run");
    cmd.args([
        "--on-active=5s",
        "--no-block",
        "--unit=sower-client-reboot",
        "systemctl",
        "reboot",
    ]);
    run_inherited(cmd).context("schedule reboot")
}

fn needs_reboot() -> Result<bool> {
    let profile = canonicalize("/nix/var/nix/profiles/system")?;
    let current = canonicalize("/run/current-system")?;
    let booted = canonicalize("/run/booted-system")?;

    if current != profile {
        tracing::debug!(
            current = %current.display(),
            profile = %profile.display(),
            "Profile differs from current",
        );
        return Ok(true);
    }

    for sub in ["/initrd", "/kernel", "/kernel-modules"] {
        let c = append(&current, sub);
        let b = append(&booted, sub);
        if c != b {
            tracing::debug!(
                sub,
                current = %c.display(),
                booted = %b.display(),
                "Booted component differs",
            );
            return Ok(true);
        }
    }
    Ok(false)
}

fn canonicalize(p: &str) -> Result<PathBuf> {
    std::fs::canonicalize(p).with_context(|| format!("eval symlink {p}"))
}

fn append(base: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}{suffix}", base.display()))
}
