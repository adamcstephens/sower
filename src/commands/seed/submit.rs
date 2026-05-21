use anyhow::{Context, Result, anyhow};
use clap::Args as ClapArgs;
use std::path::PathBuf;

use super::Ctx;
use super::ops;
use crate::api::types;

#[derive(Debug, ClapArgs)]
pub struct Args {
    /// Path to the built artifact in the Nix store.
    #[arg(long = "path", short = 'p')]
    artifact: PathBuf,

    /// Tags in `key=value` format. May be repeated.
    #[arg(long = "tag")]
    tags: Vec<String>,
}

pub async fn run(ctx: &Ctx, args: Args) -> Result<()> {
    ops::precheck(&args.artifact, ctx.seed_type).context("pre-check seed for submission")?;

    let tags = parse_tags(&args.tags)?;

    let artifact = args
        .artifact
        .to_str()
        .ok_or_else(|| anyhow!("artifact path is not valid UTF-8: {:?}", args.artifact))?
        .to_owned();

    let body = types::Seed {
        artifact,
        name: ctx.name.clone(),
        seed_type: ctx.seed_type.into_api(),
        sid: None,
        tags,
    };

    let seed = ctx
        .client
        .new_seed(None, &body)
        .await
        .context("create seed")?
        .into_inner();

    tracing::info!(
        name = %seed.name,
        seed_type = %seed.seed_type,
        artifact = %seed.artifact,
        "Submitted seed",
    );

    Ok(())
}

fn parse_tags(raw: &[String]) -> Result<Vec<types::SeedTag>> {
    raw.iter()
        .map(|s| {
            s.split_once('=')
                .map(|(k, v)| types::SeedTag {
                    key: k.to_owned(),
                    value: v.to_owned(),
                })
                .ok_or_else(|| anyhow!("invalid tag format {s:?} (expected key=value)"))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_tags_empty() {
        let got = parse_tags(&[]).unwrap();
        assert!(got.is_empty());
    }

    #[test]
    fn parse_tags_key_value() {
        let raw = vec!["env=prod".to_owned(), "role=db".to_owned()];
        let got = parse_tags(&raw).unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].key, "env");
        assert_eq!(got[0].value, "prod");
        assert_eq!(got[1].key, "role");
        assert_eq!(got[1].value, "db");
    }

    #[test]
    fn parse_tags_value_may_contain_equals() {
        let raw = vec!["url=https://example.com/a=b".to_owned()];
        let got = parse_tags(&raw).unwrap();
        assert_eq!(got[0].key, "url");
        assert_eq!(got[0].value, "https://example.com/a=b");
    }

    #[test]
    fn parse_tags_empty_value_ok() {
        let raw = vec!["k=".to_owned()];
        let got = parse_tags(&raw).unwrap();
        assert_eq!(got[0].key, "k");
        assert_eq!(got[0].value, "");
    }

    #[test]
    fn parse_tags_missing_equals_errors() {
        let raw = vec!["bare".to_owned()];
        let err = parse_tags(&raw).unwrap_err();
        assert!(
            err.to_string().contains("invalid tag format"),
            "unexpected error: {err}"
        );
    }
}
