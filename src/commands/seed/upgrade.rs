use anyhow::{Context, Result, bail};
use clap::Args as ClapArgs;

use super::Ctx;
use super::ops::{self, SeedType};
use super::reboot;

#[derive(Debug, ClapArgs)]
pub struct Args {
    /// switch-to-configuration mode (nixos only).
    #[arg(long, short = 'm', default_value = "switch")]
    mode: String,

    /// Auto-confirm reboot when one is needed.
    #[arg(long, short = 'y')]
    yes: bool,
}

pub async fn run(ctx: &Ctx, args: Args) -> Result<()> {
    if matches!(ctx.seed_type, SeedType::Nixos) && !rustix::process::geteuid().is_root() {
        bail!("upgrades for nixos must be run by root");
    }

    let seed = ctx
        .client
        .latest_seed(Some(&ctx.name), Some(ctx.seed_type.as_str()), None)
        .await
        .context("fetch latest seed")?
        .into_inner();

    let caches = ctx
        .client
        .list_nix_caches()
        .await
        .context("list nix caches")?
        .into_inner();

    ops::realize(&seed.artifact, &caches, false, None)?;
    ops::activate(ctx.seed_type, &seed.artifact, &args.mode)?;

    tracing::info!(
        name = %ctx.name,
        seed_type = %seed.seed_type,
        artifact = %seed.artifact,
        "Upgraded seed",
    );

    if matches!(ctx.seed_type, SeedType::Nixos) {
        reboot::run(reboot::Args { yes: args.yes })?;
    }

    Ok(())
}
