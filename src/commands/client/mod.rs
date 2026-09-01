//! Shared endpoint/token/config-file resolution for commands that talk to the
//! Sower API.

use anyhow::{Context, Result, anyhow, bail};
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
        self.build_client(false)
    }

    /// Like [`client`](Self::client), but refuses to build a client with no
    /// token. Commands that only ever hit authenticated endpoints use this so
    /// they fail before doing expensive work rather than on the first 401.
    pub fn authenticated_client(&self) -> Result<api::Client> {
        self.build_client(true)
    }

    fn build_client(&self, require_token: bool) -> Result<api::Client> {
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
            require_token,
        )
    }
}

fn build(
    endpoint: Option<&str>,
    access_token: Option<&str>,
    access_token_file: Option<&Path>,
    require_token: bool,
) -> Result<api::Client> {
    let endpoint = endpoint.ok_or_else(|| anyhow!("missing --endpoint (or SOWER_ENDPOINT)"))?;
    let token = resolve_token(access_token, access_token_file)?;

    let mut headers = reqwest::header::HeaderMap::new();
    if let Some(v) = auth_header(token.as_deref(), require_token)? {
        headers.insert(reqwest::header::AUTHORIZATION, v);
    }

    let http = reqwest::Client::builder()
        .default_headers(headers)
        .build()
        .context("build reqwest client")?;

    Ok(api::Client::new_with_client(endpoint, http))
}

fn auth_header(
    token: Option<&str>,
    require_token: bool,
) -> Result<Option<reqwest::header::HeaderValue>> {
    let Some(t) = token else {
        if require_token {
            bail!(
                "missing --access-token (or SOWER_ACCESS_TOKEN, --access-token-file, or a config file)"
            );
        }
        tracing::warn!("no access token provided; requests will be unauthenticated");
        return Ok(None);
    };

    let mut v = reqwest::header::HeaderValue::from_str(&format!("Bearer {t}"))
        .context("invalid access token")?;
    v.set_sensitive(true);
    Ok(Some(v))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_token_is_allowed_by_default() {
        assert!(auth_header(None, false).unwrap().is_none());
    }

    #[test]
    fn requiring_a_token_fails_without_one() {
        let err = auth_header(None, true).unwrap_err();
        assert!(err.to_string().contains("missing --access-token"), "{err}");
    }

    #[test]
    fn a_token_becomes_a_sensitive_bearer_header() {
        let v = auth_header(Some("tok"), true).unwrap().unwrap();
        assert_eq!(v.to_str().unwrap(), "Bearer tok");
        assert!(v.is_sensitive());
    }
}
