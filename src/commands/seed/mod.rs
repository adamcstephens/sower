use anyhow::{Context, Result, anyhow};
use clap::{Args, Subcommand};
use std::path::PathBuf;

use crate::api;

mod config;
mod download;
mod info;
mod ops;
mod reboot;
mod submit;
mod upgrade;

pub use ops::SeedType;

#[derive(Debug, Args)]
pub struct SeedArgs {
    /// Sower server endpoint (e.g. https://sower.example.com)
    #[arg(long, short = 'e', env = "SOWER_ENDPOINT", global = true)]
    endpoint: Option<String>,

    /// Static access token
    #[arg(long, env = "SOWER_ACCESS_TOKEN", global = true)]
    access_token: Option<String>,

    /// File containing the access token (ignored if --access-token is set)
    #[arg(long, env = "SOWER_ACCESS_TOKEN_FILE", global = true)]
    access_token_file: Option<PathBuf>,

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
    config_file: Vec<PathBuf>,

    /// Seed name (typically the hostname)
    #[arg(long, short = 'n', global = true)]
    name: Option<String>,

    /// Seed type: nixos | home-manager | nix-darwin | service
    #[arg(long = "type", short = 't', global = true)]
    seed_type: Option<SeedType>,

    #[command(subcommand)]
    command: SeedCommand,
}

#[derive(Debug, Subcommand)]
enum SeedCommand {
    /// Fetch the latest seed and realize it into the Nix store.
    Download(download::Args),
    /// Print metadata about the latest seed.
    Info,
    /// Reboot the local system if the active profile differs from the booted one.
    Reboot(reboot::Args),
    /// Submit a built artifact as a new seed.
    Submit(submit::Args),
    /// Fetch + realize + activate the latest seed.
    Upgrade(upgrade::Args),
}

pub fn run(args: SeedArgs) -> Result<()> {
    let SeedArgs {
        endpoint,
        access_token,
        access_token_file,
        config_file,
        name,
        seed_type,
        command,
    } = args;

    let file_cfg = config::load(&config_file)?;
    let endpoint = endpoint.or(file_cfg.endpoint);
    let access_token = access_token.or(file_cfg.access_token);
    let access_token_file = access_token_file.or(file_cfg.access_token_file);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build tokio runtime")?;

    rt.block_on(async move {
        let build_ctx = || {
            Ctx::build(
                endpoint.as_deref(),
                access_token.as_deref(),
                access_token_file.as_deref(),
                name.as_deref(),
                seed_type,
            )
        };

        match command {
            SeedCommand::Download(sub) => download::run(&build_ctx()?, sub).await,
            SeedCommand::Info => info::run(&build_ctx()?).await,
            SeedCommand::Reboot(sub) => reboot::run(sub),
            SeedCommand::Submit(sub) => submit::run(&build_ctx()?, sub).await,
            SeedCommand::Upgrade(sub) => upgrade::run(&build_ctx()?, sub).await,
        }
    })
}

pub struct Ctx {
    pub client: api::Client,
    pub name: String,
    pub seed_type: SeedType,
}

impl Ctx {
    fn build(
        endpoint: Option<&str>,
        access_token: Option<&str>,
        access_token_file: Option<&std::path::Path>,
        name: Option<&str>,
        seed_type: Option<SeedType>,
    ) -> Result<Self> {
        let endpoint = endpoint.ok_or_else(|| anyhow!("missing --endpoint (or SOWER_ENDPOINT)"))?;
        let name = name.ok_or_else(|| anyhow!("missing --name"))?.to_owned();
        let seed_type = seed_type.ok_or_else(|| anyhow!("missing --type"))?;

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
        let client = api::Client::new_with_client(endpoint, http);

        Ok(Self {
            client,
            name,
            seed_type,
        })
    }
}

fn resolve_token(inline: Option<&str>, path: Option<&std::path::Path>) -> Result<Option<String>> {
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
