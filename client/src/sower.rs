use crate::*;
use serde::Serialize;

pub mod daemon;

use clap::ValueEnum;
use serde::Deserialize;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;
use strum::{Display, VariantNames};

#[derive(Debug, Deserialize)]
pub struct Seed {
    pub id: String,
    pub name: String,
    #[serde(rename(deserialize = "type"))]
    pub seed_type: SeedType,
    pub out_path: String,
}

impl Seed {
    pub fn realize(&self) -> Result<&Self, String> {
        match run_command("nix-store", vec!["--realize", &self.out_path.clone()]) {
            true => Ok(self),
            false => Err(format!("failed to realize: {}", &self.out_path)),
        }
    }

    pub fn activate(&self, mode: Option<ActivationMode>) -> Result<&Self, String> {
        // TODO compare new activation to existing profile
        match &self.seed_type {
            SeedType::HomeManager => self.activate_generic(),
            SeedType::NixDarwin => self.activate_generic(),
            SeedType::Nixos => self.activate_nixos(mode),
        }
    }

    fn activate_generic(&self) -> Result<&Self, String> {
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
    pub fn new(config: &Config) -> Result<Sower, Box<dyn std::error::Error>> {
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
                if let Ok(seed) = result.json::<Seed>().await {
                    Some(seed)
                } else {
                    None
                }
            }
            Err(_) => None,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct Tree {
    pub name: String,
    pub seed: Option<Seed>,
    pub seed_type: SeedType,
    pub sower: Option<Sower>,
    pub id: Option<String>,
}

impl Tree {
    pub async fn new(config: &Config) -> Result<Tree, Box<dyn std::error::Error>> {
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
        let sower = Sower::new(&config)?;

        Ok(Tree {
            name: name.clone(),
            seed_type,
            sower: Some(sower.clone()),
            seed: sower.find_seed(name, seed_type).await,
            id: None,
        })
    }

    pub fn info(&self) -> () {
        dbg!(self);
        ()
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

    fn reboot_needed() -> std::io::Result<bool> {
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

            if path != "" {
                current != booted
            } else {
                // if running system was updated using switch, don't reboot
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
