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

    let cli = if invoked_as_activator() {
        // Symlinked entry: behave as if `sower activator <args>` was run.
        let args = std::iter::once(std::ffi::OsString::from("sower"))
            .chain(std::iter::once(std::ffi::OsString::from("activator")))
            .chain(std::env::args_os().skip(1));
        Cli::parse_from(args)
    } else {
        Cli::parse()
    };

    if let Err(e) = run(cli.command) {
        ui::error(&e);
        std::process::exit(1);
    }
}

fn invoked_as_activator() -> bool {
    std::env::args_os()
        .next()
        .as_deref()
        .map(std::path::Path::new)
        .and_then(|p| p.file_name())
        .and_then(|s| s.to_str())
        == Some("sower-activator")
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
