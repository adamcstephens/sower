use anyhow::{Context, Result};
use clap::Args as ClapArgs;

use super::Ctx;
use super::ops;

#[derive(Debug, ClapArgs)]
pub struct Args {
    /// Realize into the /sysroot store (used during initrd staging).
    #[arg(long)]
    initrd: bool,
}

pub async fn run(ctx: &Ctx, args: Args) -> Result<()> {
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

    ops::realize(&seed.artifact, &caches, args.initrd, None)?;

    tracing::info!(
        name = %seed.name,
        seed_type = %seed.seed_type,
        artifact = %seed.artifact,
        "Downloaded seed",
    );

    Ok(())
}
