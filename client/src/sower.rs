use crate::*;

use clap::ValueEnum;
use serde::Deserialize;
use std::env;
use std::fs;
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
        match run_command(
            "nix-store".to_string(),
            vec!["--realize".to_string(), self.out_path.clone()],
        ) {
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
        match run_command(format!("{}/activate", &self.out_path), vec![]) {
            true => Ok(self),
            false => Err(format!("failed to realize: {}", &self.out_path)),
        }
    }

    fn activate_nixos(&self, mode: Option<ActivationMode>) -> Result<&Self, String> {
        let mode = mode.unwrap_or(ActivationMode::DryActivate);

        // nixos profile needs to be manually set to ensure correct switching
        run_command(
            "nix-env".to_string(),
            vec![
                "--set".to_string(),
                "--profile".to_string(),
                "/nix/var/nix/profiles/system".to_string(),
                self.out_path.clone(),
            ],
        );

        // activate
        let switch_result = run_command(
            format!("{}/bin/switch-to-configuration", &self.out_path),
            vec![mode.to_string()],
        );

        match switch_result {
            true => Ok(self),
            false => Err(format!("failed to realize: {}", &self.out_path)),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Display, PartialEq, ValueEnum, VariantNames)]
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

#[derive(Clone, Debug)]
pub struct Sower {
    pub url: String,
}

impl Sower {
    pub fn new(config: &Config) -> Result<Sower, Box<dyn std::error::Error>> {
        let seed_url = format!(
            "{}/api/seeds/latest",
            config.url.clone().expect("URL is required")
        );

        Ok(Self { url: seed_url })
    }

    pub async fn find_seed(
        &self,
        name: String,
        seed_type: SeedType,
    ) -> Result<Seed, Box<dyn std::error::Error>> {
        let client = reqwest::Client::new();
        Ok(client
            .get(&self.url)
            .query(&[("name", name), ("type", seed_type.to_string())])
            .send()
            .await?
            .json::<Seed>()
            .await?)
    }
}

#[derive(Debug)]
pub struct Tree {
    pub name: String,
    pub seed: Seed,
    pub seed_type: SeedType,
    pub sower: Sower,
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
            sower: sower.clone(),
            seed: sower.find_seed(name, seed_type).await?,
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
        // TODO handle missing paths
        let profile_paths = &["initrd", "kernel", "kernel-modules"];
        let result = profile_paths.iter().any(|&path| {
            let current_path = format!("/nix/var/nix/profiles/system/{}", path); // fails if
                                                                                 // missing
            let booted_path = format!("/run/booted-system/{}", path);
            let current = fs::read_link(current_path).expect("unstable to read current link");
            let booted = fs::read_link(booted_path).expect("unable to read booted link");

            current != booted
        });
        Ok(result)
    }

    fn run_reboot() {
        run_command(
            "systemd-run".to_string(),
            vec![
                "--on-active=5s".to_string(),
                "--no-block".to_string(),
                "--unit=sower-client-reboot".to_string(),
                "systemctl".to_string(),
                "reboot".to_string(),
            ],
        );
        println!("Rebooting in ~5 seconds");
        std::process::exit(0)
    }
}

fn run_command(command: String, args: Vec<String>) -> bool {
    let status = &mut Command::new(command)
        .args(args)
        .status()
        .expect("failed to execute command");

    status.success()
}
