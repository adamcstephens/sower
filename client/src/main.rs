use crate::sower::*;

use clap::Parser;
use clap::Subcommand;
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};
use tracing::{debug, info};
use xdg;

mod sower;
use sower::daemon::Daemon;

#[derive(Parser)]
#[command(version, about, long_about = None, arg_required_else_help = true)]
struct Cli {
    #[command(subcommand)]
    action: Actions,

    #[arg(long, short, global = true)]
    config: Option<PathBuf>,

    #[arg(long, short, global = true)]
    name: Option<String>,

    #[arg(
        value_enum,
        long = "type",
        short = 't',
        global = true,
        value_name = "TYPE"
    )]
    seed_type: Option<SeedType>,

    #[arg(short, long, global = true, value_name = "SOWER_URL")]
    url: Option<String>,
}

#[derive(Subcommand)]
#[command(subcommand_value_name = "ACTION", subcommand_help_heading = "Actions")]
enum Actions {
    /// a seed is an installable served by the sower
    Seed {
        #[command(subcommand)]
        action: SeedCommands,
    },

    /// a tree grows from seeds
    Tree {
        #[command(subcommand)]
        action: TreeCommands,
    },

    Daemon {},
}

#[derive(Debug, Subcommand)]
#[command(
    subcommand_value_name = "ACTION",
    subcommand_help_heading = "Seed commands"
)]
enum SeedCommands {
    /// activate
    Activate {
        #[arg(long, short, value_name = "how to activate nixos")]
        mode: Option<ActivationMode>,
    },

    /// download target
    Download {},
}

#[derive(Debug, Subcommand)]
#[command(
    subcommand_value_name = "ACTION",
    subcommand_help_heading = "Tree commands"
)]
enum TreeCommands {
    Info {},

    Reboot {
        #[arg(long, short, default_value_t = false)]
        yes: bool,
    },

    Upgrade {
        #[arg(long, short, value_name = "how to activate nixos")]
        mode: Option<ActivationMode>,

        #[arg(long, short, default_value_t = false)]
        reboot: bool,

        #[arg(long, short, default_value_t = false)]
        yes: bool,
    },
}

#[derive(Debug, Deserialize)]
pub struct Config {
    reboot: Option<bool>,
    mode: Option<ActivationMode>,
    name: Option<String>,
    #[serde(rename(deserialize = "type"))]
    seed_type: Option<SeedType>,
    url: Option<String>,
}

impl Config {
    pub fn name(self, name: Option<String>) -> Self {
        if let Some(_) = &name {
            Self { name, ..self }
        } else {
            self
        }
    }

    pub fn reboot(self, reboot: Option<bool>) -> Self {
        if let Some(_) = &reboot {
            Self { reboot, ..self }
        } else {
            self
        }
    }

    pub fn seed_type(self, seed_type: Option<SeedType>) -> Self {
        if let Some(_) = &seed_type {
            Self { seed_type, ..self }
        } else {
            self
        }
    }

    pub fn url(self, url: Option<String>) -> Self {
        if let Some(_) = &url {
            Self { url, ..self }
        } else {
            self
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let cli = Cli::parse();

    let config_file = match cli.config {
        Some(path) => path,
        None => match std::env::var("USER") {
            Ok(user) => match user.as_ref() {
                "root" => PathBuf::from("/etc/sower/config.toml"),
                _ => xdg::BaseDirectories::with_prefix("sower")
                    .expect("cannot locate XDG directories")
                    .get_config_file("config.toml"),
            },
            Err(_) => PathBuf::from("/etc/sower/config.toml"),
        },
    };

    dbg!(&config_file);

    let config = match Path::try_exists(&config_file) {
        Ok(true) => {
            let config_string = fs::read_to_string(config_file)?;
            toml::from_str(&config_string).expect("failed to parse config file")
        }
        _ => Config {
            reboot: None,
            mode: None,
            name: None,
            seed_type: None,
            url: None,
        },
    };

    // cli overrides config
    let config = config.name(cli.name).seed_type(cli.seed_type).url(cli.url);

    let tree = Tree::new(&config).await?;

    match &cli.action {
        Actions::Daemon {} => {
            let mut daemon = Daemon::new(&config).await;
            daemon.run().await.unwrap()
        }

        Actions::Seed { action } => {
            let seed = tree.latest_seed().await;

            match action {
                SeedCommands::Activate { mode, .. } => {
                    let mode = mode.clone().or(config.mode);
                    seed.unwrap().activate(mode).expect("failed to activate");
                }

                SeedCommands::Download {} => {
                    seed.unwrap().realize().expect("failed to realize");
                }
            }
        }

        Actions::Tree { action } => {
            let tree = tree.load_latest().await;

            match action {
                TreeCommands::Info {} => info!("{:?}", tree),

                TreeCommands::Reboot { yes } => {
                    tree.info();
                    tree.reboot(yes.clone())
                }

                TreeCommands::Upgrade { mode, reboot, yes } => {
                    debug!("{:?}", tree);

                    let mode = mode.clone().or(config.mode);
                    let desired = tree.seeds.clone().unwrap().desired.unwrap();
                    info!("Activating seed {:?}", &desired);
                    desired
                        .realize()
                        .expect("failed to realize")
                        .activate(mode)
                        .expect("failed to activate");

                    let tree = tree.load_seeds();
                    debug!("{:?}", tree);

                    if config.reboot.unwrap_or(false) || reboot.clone() {
                        tree.reboot(yes.clone());
                    }
                }
            }
        }
    }

    Ok(())
}
