use anyhow::Result;
use clap::{CommandFactory, Parser, Subcommand};
use clap_complete::Shell;

mod commands;
mod ui;

#[derive(Parser)]
#[command(name = "sower", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Handle a single activation request from a systemd-activated socket on stdin.
    Activator(commands::activator::ActivatorArgs),

    /// Generate shell completion scripts.
    Completions {
        /// Shell to generate completions for
        shell: Shell,
    },
}

fn main() {
    clap_complete::CompleteEnv::with_factory(Cli::command).complete();

    let cli = Cli::parse();

    if let Err(e) = run(cli.command) {
        ui::error(&e);
        std::process::exit(1);
    }
}

fn run(command: Command) -> Result<()> {
    match command {
        Command::Activator(args) => commands::activator::run(args),
        Command::Completions { shell } => {
            let mut cmd = Cli::command();
            clap_complete::generate(shell, &mut cmd, "sower", &mut std::io::stdout());
            Ok(())
        }
    }
}
