use crate::*;

pub mod daemon;

use anyhow::{anyhow, Result};
use clap::ValueEnum;
use serde::Deserialize;
use serde::Serialize;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;
use strum::{Display, VariantNames};
use tracing::{debug, info};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Seed {
    pub id: Option<String>,
    pub name: String,
    pub seed_type: SeedType,
    pub out_path: String,
}

impl Seed {
    pub fn realize(&self) -> Result<&Self> {
        match run_command("nix-store", vec!["--realize", &self.out_path.clone()]) {
            true => Ok(self),
            false => Err(anyhow!("{}", &self.out_path)),
        }
    }

    pub fn activate(&self, mode: Option<ActivationMode>) -> Result<&Self, String> {
        // TODO compare new activation to existing profile
        match &self.seed_type {
            SeedType::HomeManager => self.activate_home_manager(),
            SeedType::NixDarwin => self.activate_nix_darwin(),
            SeedType::Nixos => self.activate_nixos(mode),
        }
    }

    fn activate_home_manager(&self) -> Result<&Self, String> {
        match run_command(format!("{}/activate", &self.out_path).as_ref(), vec![]) {
            true => Ok(self),
            false => Err(format!("failed to realize: {}", &self.out_path)),
        }
    }

    fn activate_nix_darwin(&self) -> Result<&Self, String> {
        // nixos profile needs to be manually set to ensure correct switching
        run_command(
            "nix-env",
            vec![
                "--set",
                "--profile",
                "/nix/var/nix/profiles/system",
                &self.out_path.clone(),
            ],
        );

        match run_command(format!("{}/activate", &self.out_path).as_ref(), vec![]) {
            true => Ok(self),
            false => Err(format!("failed to realize: {}", &self.out_path)),
        }
    }

    fn activate_nixos(&self, mode: Option<ActivationMode>) -> Result<&Self, String> {
        let mode = mode.unwrap_or(ActivationMode::DryActivate);

        // nixos profile needs to be manually set to ensure correct switching
        run_command(
            "nix-env",
            vec![
                "--set",
                "--profile",
                "/nix/var/nix/profiles/system",
                &self.out_path.clone(),
            ],
        );

        // activate
        let switch_result = run_command(
            format!("{}/bin/switch-to-configuration", &self.out_path).as_ref(),
            vec![&mode.to_string()],
        );

        match switch_result {
            true => Ok(self),
            false => Err(format!("failed to realize: {}", &self.out_path)),
        }
    }

    fn new_from_path(name: String, seed_type: SeedType, path: &str) -> Result<Self> {
        debug!(path);
        match fs::canonicalize(Path::new(path)) {
            Ok(path) => Ok(Self {
                id: None,
                name,
                seed_type,
                out_path: path.to_string_lossy().to_string(),
            }),
            Err(e) => Err(e.into()),
        }
    }
}

#[derive(
    Clone, Copy, Debug, Deserialize, Display, PartialEq, Serialize, ValueEnum, VariantNames,
)]
#[serde(rename_all = "kebab-case")]
#[strum(serialize_all = "kebab-case")]
pub enum SeedType {
    HomeManager,
    NixDarwin,
    Nixos,
}

impl SeedType {
    fn profile_path(&self) -> String {
        match self {
            SeedType::HomeManager => {
                format!(
                    "{}/.local/state/nix/profiles/home-manager",
                    env::var("HOME").expect("missing $HOME environment variable")
                )
            }
            SeedType::NixDarwin => "/nix/var/nix/profiles/system".to_string(),

            SeedType::Nixos => "/nix/var/nix/profiles/system".to_string(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Display, ValueEnum, VariantNames)]
#[serde(rename_all = "kebab-case")]
#[strum(serialize_all = "kebab-case")]
pub enum ActivationMode {
    Boot,
    DryActivate,
    Switch,
    Test,
    None,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Sower {
    pub url: String,
    pub api_url: String,
    pub channels_url: String,
}

impl Sower {
    pub fn new(config: &Config) -> Result<Sower> {
        let url = config.url.clone().expect("URL is required");
        let api_url = format!("{}/api", url);
        let channels_url = format!("{}/client/websocket", url.replace("http", "ws"));

        Ok(Self {
            url,
            api_url,
            channels_url,
        })
    }

    pub async fn find_seed(&self, name: String, seed_type: SeedType) -> Option<Seed> {
        let client = reqwest::Client::new();

        match client
            .get(format!("{}/seeds/latest", &self.api_url))
            .query(&[("name", name), ("type", seed_type.to_string())])
            .send()
            .await
        {
            Ok(result) => {
                debug!("{:?}", result);
                match result.json::<Seed>().await {
                    Ok(seed) => Some(seed),
                    Err(err) => {
                        dbg!(err);
                        None
                    }
                }
            }
            Err(err) => {
                debug!("Err: {}", err);
                None
            }
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct Tree {
    pub name: String,
    pub seeds: Option<TreeSeeds>,
    pub seed_type: SeedType,
    pub sower: Option<Sower>,
    pub id: Option<String>,
    pub server_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct TreeSeeds {
    pub current: Option<Seed>,
    pub booted: Option<Seed>,
    pub desired: Option<Seed>,
    pub profile: Option<Seed>,
}

impl Tree {
    pub async fn new(config: &Config) -> Result<Tree> {
        let name =
            config
                .name
                .clone()
                .unwrap_or(match config.seed_type.expect("seed type is required") {
                    SeedType::Nixos | SeedType::NixDarwin => nix::unistd::gethostname()
                        .expect("Failed getting hostname")
                        .into_string()
                        .unwrap(),
                    SeedType::HomeManager => env::var("USER").expect("can not detect username"),
                });
        let seed_type = config.seed_type.unwrap();
        let sower = Sower::new(config)?;

        let mut tree = Tree {
            name: name.clone(),
            seed_type,
            sower: Some(sower.clone()),
            seeds: None,
            id: None,
            server_id: None,
        };

        tree.load_seeds().await?;

        Ok(tree)
    }

    pub fn info(&self) {
        dbg!(self);
    }

    pub async fn load_seeds(&mut self) -> Result<()> {
        let booted = match self.seed_type {
            SeedType::Nixos => {
                Seed::new_from_path(self.name.clone(), self.seed_type, "/run/booted-system").ok()
            }
            SeedType::HomeManager => None,
            SeedType::NixDarwin => None,
        };

        let current = match self.seed_type {
            SeedType::HomeManager => None,
            SeedType::NixDarwin => {
                Seed::new_from_path(self.name.clone(), self.seed_type, "/run/current-system").ok()
            }
            SeedType::Nixos => {
                Seed::new_from_path(self.name.clone(), self.seed_type, "/run/current-system").ok()
            }
        };

        let profile = Seed::new_from_path(
            self.name.clone(),
            self.seed_type,
            &self.seed_type.profile_path(),
        )
        .ok();

        let desired = self
            .sower
            .as_ref()
            .unwrap()
            .find_seed(self.name.clone(), self.seed_type)
            .await;

        self.seeds = Some(TreeSeeds {
            booted,
            current,
            profile,
            desired,
        });

        Ok(())
    }

    pub fn reboot(&self, confirm: bool) {
        if self.seed_type != SeedType::Nixos {
            println!("Non-NixOS Trees aren't rebootable");
            return;
        }

        if Self::reboot_needed().expect("failed to check reboot state") {
            println!("Reboot needed.");
        } else {
            println!("No reboot necessary.");
            return;
        }

        if !confirm {
            println!("Check mode enabled, skipping reboot");
            return;
        }

        Self::run_reboot()
    }

    fn reboot_needed() -> Result<bool> {
        let profile_paths = &["", "/initrd", "/kernel", "/kernel-modules"];
        let result = profile_paths.iter().any(|&path| {
            let profile_path = format!("/nix/var/nix/profiles/system{}", path);
            let profile_path = Path::new(&profile_path);
            if !profile_path.try_exists().unwrap_or(false) {
                return false;
            };

            let booted_path = format!("/run/booted-system{}", path);
            let booted_path = Path::new(&booted_path);
            if !booted_path.try_exists().unwrap_or(false) {
                return false;
            };

            let current_path = format!("/run/current-system{}", path);
            let current_path = Path::new(&current_path);
            if !current_path.try_exists().unwrap_or(false) {
                return false;
            };

            let profile = fs::canonicalize(profile_path).expect("unstable to read current link");
            let current = fs::canonicalize(current_path).expect("unable to read current link");
            let booted = fs::canonicalize(booted_path).expect("unable to read booted link");

            if !path.is_empty() {
                if current != booted {
                    info!(
                        "current {:?} != booted {:?}",
                        current.clone().into_os_string(),
                        booted.clone().into_os_string()
                    );
                }
                current != booted
            } else {
                if profile != current {
                    info!(
                        "current {:?} != booted {:?}",
                        current.clone().into_os_string(),
                        profile.clone().into_os_string()
                    );
                }
                profile != current
            }
        });
        Ok(result)
    }

    fn run_reboot() {
        run_command(
            "systemd-run",
            vec![
                "--on-active=5s",
                "--no-block",
                "--unit=sower-client-reboot",
                "systemctl",
                "reboot",
            ],
        );
        println!("Rebooting in ~5 seconds");
        std::process::exit(0)
    }
}

fn run_command(command: &str, args: Vec<&str>) -> bool {
    let status = &mut Command::new(command)
        .args(args)
        .status()
        .expect("failed to execute command");

    status.success()
}
