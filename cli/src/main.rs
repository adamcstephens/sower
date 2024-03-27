use crate::sower::*;
use std::env;

use clap::Parser;
use clap::Subcommand;

mod sower;

#[derive(Parser)]
#[command(version, about, long_about = None, arg_required_else_help = true)]
struct Cli {
    #[command(subcommand)]
    action: Actions,

    #[arg(short, long, global = true, value_name = "sower URL")]
    url: Option<String>,
}

#[derive(Subcommand)]
#[command(subcommand_value_name = "ACTION", subcommand_help_heading = "Actions")]
enum Actions {
    /// build targets
    Build {
        #[arg(short, long, value_name = "seed name")]
        name: Option<String>,
    },

    /// upload built targets
    Upload { name: Option<String> },

    /// download and activate
    Activate {
        #[arg(
            value_enum,
            long = "type",
            short = 't',
            default_value_t = SeedType::Nixos,
        )]
        seed_type: SeedType,

        #[arg(long, short, value_name = "seed name")]
        name: Option<String>,

        #[arg(long, short, value_name = "how to activate nixos")]
        mode: Option<ActivationMode>,
    },

    /// download target
    Download {
        #[arg(
            value_enum,
            long = "type",
            short = 't',
            default_value_t = SeedType::Nixos,
        )]
        seed_type: SeedType,

        #[arg(long, short, value_name = "seed name")]
        name: Option<String>,
    },

    Reboot {
        #[arg(long, short, default_value_t = false)]
        yes: bool,
    },
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    match &cli.action {
        Actions::Activate {
            name,
            seed_type,
            mode,
            ..
        } => {
            let sower = Sower::new(cli.url.expect("missing url"));
            let name = name.clone().unwrap_or(match &seed_type {
                SeedType::Nixos => nix::unistd::gethostname()
                    .expect("Failed getting hostname")
                    .into_string()
                    .unwrap(),
                SeedType::HomeManager => env::var("USER").expect("can not detect username"),
                _ => panic!("Unsupported seed type"),
            });

            let seed = sower
                .expect("failed to fetch seed")
                .find_seed(name, seed_type.clone())
                .await?;

            let activation = seed
                .realize()
                .expect("failed to realize")
                .activate(&mode)
                .expect("failed to activate");

            println!("{:#?}", activation);
        }

        Actions::Download {
            name, seed_type, ..
        } => {
            let sower = Sower::new(cli.url.expect("missing url"));
            let name = name.clone().unwrap_or(match seed_type.clone() {
                SeedType::Nixos => nix::unistd::gethostname()
                    .expect("Failed getting hostname")
                    .into_string()
                    .unwrap(),
                SeedType::HomeManager => env::var("USER").expect("can not detect username"),
                _ => panic!("Unsupported seed type"),
            });

            let seed = sower
                .expect("failed to fetch seed")
                .find_seed(name, seed_type.clone())
                .await?;

            let seed = seed.realize().expect("failed to realize");

            println!("{:#?}", seed);
            ()
        }

        Actions::Reboot { yes } => Tree::reboot(yes.clone()),
        _ => panic!("unsupported action"),
    }

    Ok(())
}
