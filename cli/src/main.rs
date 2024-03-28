use crate::sower::*;

use clap::Parser;
use clap::Subcommand;
use serde::Deserialize;
use std::fs;

mod sower;

#[derive(Parser)]
#[command(version, about, long_about = None, arg_required_else_help = true)]
struct Cli {
    #[command(subcommand)]
    action: Actions,

    #[arg(long, short, global = true)]
    config: Option<String>,

    #[arg(long, short, global = true)]
    name: Option<String>,

    #[arg(
    value_enum,
        long = "type",
        short = 't',
        default_value_t = SeedType::Nixos,
        global = true,
        value_name = "TYPE"
    )]
    seed_type: SeedType,

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
    name: Option<String>,
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

    pub fn seed_type(self, seed_type: SeedType) -> Self {
        Self {
            seed_type: Some(seed_type),
            ..self
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
    let cli = Cli::parse();

    let config: Config = match cli.config {
        Some(path) => {
            let config_string = fs::read_to_string(path)?;
            toml::from_str(&config_string).expect("failed to parse config file")
        }
        None => Config {
            name: None,
            seed_type: None,
            url: None,
        },
    };

    let config = config.name(cli.name).seed_type(cli.seed_type).url(cli.url);

    let tree = Tree::new(&config).await?;
    let seed = &tree.seed;

    dbg!(&tree);

    match &cli.action {
        Actions::Seed { action } => match action {
            SeedCommands::Activate { mode, .. } => {
                seed.activate(mode.clone()).expect("failed to activate");
            }

            SeedCommands::Download {} => {
                seed.realize().expect("failed to realize");
            }
        },

        Actions::Tree { action } => match action {
            TreeCommands::Upgrade { mode, reboot, yes } => {
                seed.realize()
                    .expect("failed to realize")
                    .activate(mode.clone())
                    .expect("failed to activate");

                if reboot.clone() {
                    Tree::reboot(yes.clone());
                }
            }
            TreeCommands::Reboot { yes } => Tree::reboot(yes.clone()),
        },
    }

    Ok(())
}
