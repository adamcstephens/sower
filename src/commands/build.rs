use anyhow::Result;
use clap::{Args, ValueEnum};
use std::ffi::OsString;
use std::os::unix::process::CommandExt;

/// Arguments mirror the Optimus `build` definition in
/// `apps/sower_cli/lib/sower_cli.ex`; both sides are checked against
/// `apps/sower_cli/priv/build_interface.json`. Numeric/enum options carry no
/// defaults here so the Elixir CLI stays the single source of truth for them.
#[derive(Debug, Args)]
pub struct BuildArgs {
    /// Path to Nix file or Flake reference (e.g., '.', '.#attr', 'github:owner/repo')
    target: String,

    /// By default cli builds are 'authoritative' and will rename seeds that match artifacts.
    #[arg(long)]
    non_authoritative: bool,

    /// Only evaluate, don't build.
    #[arg(long)]
    eval_only: bool,

    /// Push built paths to cache.
    #[arg(long, short = 'p')]
    push: bool,

    /// Full pipeline: build, push, and register with server.
    #[arg(long, short = 's')]
    seed: bool,

    /// Enable evaluation caching. This is disabled by default, unlike standard commands.
    #[arg(long)]
    use_eval_cache: bool,

    /// Exit immediately if any step fails (default: continue with successful items).
    #[arg(long, short = 'f')]
    fail_fast: bool,

    /// Attribute to evaluate for non-flakes, default is all attributes.
    #[arg(long, short = 'A')]
    attr: bool,

    /// Cache destination (e.g. 'attic://server:cache', 'ssh://host'). May be repeated.
    #[arg(long, short = 'c', value_name = "URL")]
    cache: Vec<String>,

    /// Number of parallel eval workers.
    #[arg(long, value_name = "N")]
    eval_jobs: Option<u32>,

    /// Number of parallel build workers.
    #[arg(long, short = 'j', value_name = "N")]
    build_jobs: Option<u32>,

    /// Metadata tag in `key=value` format. May be repeated.
    #[arg(long, short = 't', value_name = "KEY=VALUE")]
    tag: Vec<String>,

    /// Evaluation type.
    #[arg(long, value_name = "TYPE", value_enum)]
    eval_type: Option<EvalType>,

    /// Memory limit per evaluation in MB.
    #[arg(long, short = 'm', value_name = "MB")]
    memory_limit: Option<u32>,

    /// Enable debug logging.
    #[arg(long, short = 'd')]
    debug: bool,

    /// Sower server endpoint (e.g. https://sower.example.com)
    #[arg(long, short = 'e', env = "SOWER_ENDPOINT", value_name = "URL")]
    endpoint: Option<String>,

    /// File containing the server access token.
    #[arg(long, env = "SOWER_ACCESS_TOKEN_FILE", value_name = "PATH")]
    access_token_file: Option<String>,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum EvalType {
    Auto,
    Flake,
    Path,
}

pub fn run(args: BuildArgs) -> Result<()> {
    let bin = std::env::var_os("SOWER_BUILD_CLI").unwrap_or_else(|| "sower-build".into());
    let err = std::process::Command::new(&bin).args(args.to_argv()).exec();
    Err(anyhow::Error::new(err).context(format!("exec {}", bin.to_string_lossy())))
}

impl BuildArgs {
    fn to_argv(&self) -> Vec<OsString> {
        let mut argv: Vec<OsString> = vec!["build".into()];

        let flags = [
            ("--debug", self.debug),
            ("--non-authoritative", self.non_authoritative),
            ("--eval-only", self.eval_only),
            ("--push", self.push),
            ("--seed", self.seed),
            ("--use-eval-cache", self.use_eval_cache),
            ("--fail-fast", self.fail_fast),
            ("--attr", self.attr),
        ];
        for (name, set) in flags {
            if set {
                argv.push(name.into());
            }
        }

        for cache in &self.cache {
            argv.push("--cache".into());
            argv.push(cache.into());
        }
        if let Some(n) = self.eval_jobs {
            argv.push("--eval-jobs".into());
            argv.push(n.to_string().into());
        }
        if let Some(n) = self.build_jobs {
            argv.push("--build-jobs".into());
            argv.push(n.to_string().into());
        }
        for tag in &self.tag {
            argv.push("--tag".into());
            argv.push(tag.into());
        }
        if let Some(eval_type) = self.eval_type {
            argv.push("--eval-type".into());
            argv.push(
                eval_type
                    .to_possible_value()
                    .expect("no skipped variants")
                    .get_name()
                    .to_owned()
                    .into(),
            );
        }
        if let Some(n) = self.memory_limit {
            argv.push("--memory-limit".into());
            argv.push(n.to_string().into());
        }
        if let Some(endpoint) = &self.endpoint {
            argv.push("--endpoint".into());
            argv.push(endpoint.into());
        }
        if let Some(path) = &self.access_token_file {
            argv.push("--access-token-file".into());
            argv.push(path.into());
        }

        argv.push(self.target.clone().into());
        argv
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;
    use clap::Parser;

    #[derive(Parser)]
    struct Harness {
        #[command(flatten)]
        args: BuildArgs,
    }

    fn to_argv(cli: &[&str]) -> Vec<String> {
        Harness::try_parse_from(std::iter::once("build").chain(cli.iter().copied()))
            .expect("parse")
            .args
            .to_argv()
            .into_iter()
            .map(|s| s.into_string().expect("utf-8"))
            .collect()
    }

    #[test]
    fn minimal_invocation_forwards_only_target() {
        assert_eq!(to_argv(&["."]), ["build", "."]);
    }

    #[test]
    fn short_flags_are_reemitted_in_long_form() {
        assert_eq!(
            to_argv(&["-d", "-p", "-j", "8", "-t", "a=b", "-t", "c=d", ".#attr"]),
            [
                "build",
                "--debug",
                "--push",
                "--build-jobs",
                "8",
                "--tag",
                "a=b",
                "--tag",
                "c=d",
                ".#attr",
            ]
        );
    }

    #[test]
    fn value_options_forward_verbatim() {
        assert_eq!(
            to_argv(&[
                "--cache",
                "attic://server:cache",
                "--eval-type",
                "flake",
                "--memory-limit",
                "8000",
                "--eval-jobs",
                "2",
                "--endpoint",
                "http://localhost:4000",
                "--access-token-file",
                "/run/token",
                ".",
            ]),
            [
                "build",
                "--cache",
                "attic://server:cache",
                "--eval-jobs",
                "2",
                "--eval-type",
                "flake",
                "--memory-limit",
                "8000",
                "--endpoint",
                "http://localhost:4000",
                "--access-token-file",
                "/run/token",
                ".",
            ]
        );
    }

    #[test]
    fn interface_matches_elixir_cli_fixture() {
        let fixture: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/apps/sower_cli/priv/build_interface.json"
            ))
            .expect("read build_interface.json"),
        )
        .expect("parse build_interface.json");

        let expected = |key: &str| -> Vec<String> {
            fixture[key]
                .as_array()
                .expect("array")
                .iter()
                .map(|v| v.as_str().expect("string").to_owned())
                .collect()
        };

        let cmd = Harness::command();
        let mut flags = Vec::new();
        let mut options = Vec::new();
        for arg in cmd.get_arguments() {
            if arg.get_id() == "help" || arg.get_long().is_none() {
                continue;
            }
            let long = arg.get_long().expect("long name").to_owned();
            if matches!(arg.get_action(), clap::ArgAction::SetTrue) {
                flags.push(long);
            } else {
                options.push(long);
            }
        }
        flags.sort();
        options.sort();

        assert_eq!(flags, expected("flags"));
        assert_eq!(options, expected("options"));
    }
}
