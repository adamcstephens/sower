use anyhow::{Context, Result};

use super::Ctx;

pub async fn run(ctx: &Ctx) -> Result<()> {
    let seed = ctx
        .client
        .latest_seed(Some(&ctx.name), Some(ctx.seed_type.as_str()), None)
        .await
        .context("fetch latest seed")?
        .into_inner();

    tracing::info!(
        name = %seed.name,
        seed_type = %seed.seed_type,
        artifact = %seed.artifact,
        "Found seed",
    );

    Ok(())
}
