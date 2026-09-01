use anyhow::{Context, Result, anyhow};
use clap::{Args, Subcommand};

use crate::api;
use crate::commands::client::ConnectionArgs;

mod download;
mod info;
mod ops;
mod reboot;
mod submit;
mod upgrade;

pub use ops::{SeedType, precheck, run_inherited};
pub use submit::parse_tags;

#[derive(Debug, Args)]
pub struct SeedArgs {
    #[command(flatten)]
    connection: ConnectionArgs,

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
        connection,
        name,
        seed_type,
        command,
    } = args;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build tokio runtime")?;

    rt.block_on(async move {
        let build_ctx = || Ctx::build(&connection, name.as_deref(), seed_type);

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
        connection: &ConnectionArgs,
        name: Option<&str>,
        seed_type: Option<SeedType>,
    ) -> Result<Self> {
        let name = name.ok_or_else(|| anyhow!("missing --name"))?.to_owned();
        let seed_type = seed_type.ok_or_else(|| anyhow!("missing --type"))?;
        let client = connection.client()?;

        Ok(Self {
            client,
            name,
            seed_type,
        })
    }
}
