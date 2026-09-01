//! Shared endpoint/token/config-file resolution for commands that talk to the
//! Sower API.

use anyhow::{Context, Result, anyhow};
use clap::Args;
use std::path::{Path, PathBuf};

use crate::api;

mod config;

#[derive(Debug, Args)]
pub struct ConnectionArgs {
    /// Sower server endpoint (e.g. https://sower.example.com)
    #[arg(long, short = 'e', env = "SOWER_ENDPOINT", global = true)]
    pub endpoint: Option<String>,

    /// Static access token
    #[arg(long, env = "SOWER_ACCESS_TOKEN", global = true)]
    pub access_token: Option<String>,

    /// File containing the access token (ignored if --access-token is set)
    #[arg(long, env = "SOWER_ACCESS_TOKEN_FILE", global = true)]
    pub access_token_file: Option<PathBuf>,

    /// JSON config file (repeatable). Defaults: root=/etc/sower/client.json,
    /// non-root=$XDG_CONFIG_HOME/sower/client.json. Honored keys: endpoint,
    /// access_token, access_token_file. Later files override earlier ones; CLI
    /// flags override all config files.
    #[arg(
        long = "config-file",
        short = 'c',
        env = "SOWER_CONFIG_FILE",
        global = true
    )]
    pub config_file: Vec<PathBuf>,
}

impl ConnectionArgs {
    /// Merge the config files under the CLI flags, then build an API client.
    pub fn client(&self) -> Result<api::Client> {
        let file_cfg = config::load(&self.config_file)?;
        let endpoint = self.endpoint.clone().or(file_cfg.endpoint);
        let access_token = self.access_token.clone().or(file_cfg.access_token);
        let access_token_file = self
            .access_token_file
            .clone()
            .or(file_cfg.access_token_file);

        build(
            endpoint.as_deref(),
            access_token.as_deref(),
            access_token_file.as_deref(),
        )
    }
}

fn build(
    endpoint: Option<&str>,
    access_token: Option<&str>,
    access_token_file: Option<&Path>,
) -> Result<api::Client> {
    let endpoint = endpoint.ok_or_else(|| anyhow!("missing --endpoint (or SOWER_ENDPOINT)"))?;
    let token = resolve_token(access_token, access_token_file)?;

    let mut headers = reqwest::header::HeaderMap::new();
    if let Some(t) = token {
        let mut v = reqwest::header::HeaderValue::from_str(&format!("Bearer {t}"))
            .context("invalid access token")?;
        v.set_sensitive(true);
        headers.insert(reqwest::header::AUTHORIZATION, v);
    } else {
        tracing::warn!("no access token provided; requests will be unauthenticated");
    }

    let http = reqwest::Client::builder()
        .default_headers(headers)
        .build()
        .context("build reqwest client")?;

    Ok(api::Client::new_with_client(endpoint, http))
}

fn resolve_token(inline: Option<&str>, path: Option<&Path>) -> Result<Option<String>> {
    if let Some(t) = inline {
        return Ok(Some(t.to_owned()));
    }
    if let Some(p) = path {
        let raw = std::fs::read_to_string(p)
            .with_context(|| format!("read access token file: {}", p.display()))?;
        return Ok(Some(raw.trim().to_owned()));
    }
    Ok(None)
}
