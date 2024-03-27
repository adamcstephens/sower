use crate::sower::*;

use clap::Parser;
use clap::Subcommand;

mod sower;

#[derive(Parser)]
#[command(version, about, long_about = None, arg_required_else_help = true)]
struct Cli {
    #[command(subcommand)]
    action: Actions,

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
    /// download and activate
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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    let url = cli.url.expect("missing Sower URL");
    let seed = Sower::new(url.clone())
        .expect("failed to find latest seed")
        .find_seed(cli.name.clone(), cli.seed_type.clone())
        .await?;

    match &cli.action {
        Actions::Seed { action } => match action {
            SeedCommands::Activate { mode, .. } => {
                seed.activate(&mode).expect("failed to activate");
            }

            SeedCommands::Download {} => {
                seed.realize().expect("failed to realize");
            }
        },

        Actions::Tree { action } => match action {
            TreeCommands::Upgrade { mode, reboot, yes } => {
                seed.realize()
                    .expect("failed to realize")
                    .activate(&mode)
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
