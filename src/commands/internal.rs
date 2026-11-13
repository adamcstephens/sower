use anyhow::{Context, Result, bail};
use clap::{Args, Subcommand};
use std::path::PathBuf;

#[derive(Debug, Args)]
pub struct InternalArgs {
    #[command(subcommand)]
    command: InternalCommand,
}

#[derive(Debug, Subcommand)]
enum InternalCommand {
    SyncDirectory { path: PathBuf },
}

pub fn run(args: InternalArgs) -> Result<()> {
    match args.command {
        InternalCommand::SyncDirectory { path } => {
            if !path.is_absolute() {
                bail!("directory path must be absolute");
            }
            let directory = std::fs::File::open(&path)
                .with_context(|| format!("open directory {}", path.display()))?;
            if !directory
                .metadata()
                .context("read directory metadata")?
                .is_dir()
            {
                bail!("not a directory: {}", path.display());
            }
            directory
                .sync_all()
                .with_context(|| format!("fsync directory {}", path.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[derive(Parser)]
    struct TestCli {
        #[command(flatten)]
        args: InternalArgs,
    }

    #[test]
    fn syncs_a_real_directory_and_rejects_files_missing_and_relative_paths() {
        let path = std::env::temp_dir().join(format!("sower-fsync-test-{}", std::process::id()));
        std::fs::create_dir(&path).unwrap();
        let args = TestCli::try_parse_from([
            std::ffi::OsStr::new("internal"),
            std::ffi::OsStr::new("sync-directory"),
            path.as_os_str(),
        ])
        .unwrap();
        run(args.args).unwrap();
        let file = path.join("file");
        std::fs::write(&file, b"data").unwrap();
        let error = run(InternalArgs {
            command: InternalCommand::SyncDirectory { path: file.clone() },
        })
        .unwrap_err();
        assert!(error.to_string().contains("not a directory"));
        std::fs::remove_file(file).unwrap();
        std::fs::remove_dir(&path).unwrap();
        let error = run(InternalArgs {
            command: InternalCommand::SyncDirectory { path },
        })
        .unwrap_err();
        assert!(error.to_string().contains("open directory"));
        let error = run(InternalArgs {
            command: InternalCommand::SyncDirectory {
                path: PathBuf::from("relative"),
            },
        })
        .unwrap_err();
        assert!(error.to_string().contains("must be absolute"));
    }
}
