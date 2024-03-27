use clap::ValueEnum;
use serde::Deserialize;
use std::env;
use std::fs;
use std::process::Command;
use strum::{Display, VariantNames};

#[derive(Debug, Deserialize)]
pub struct Seed {
    pub id: u64,
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

    pub fn activate(&self, mode: &Option<ActivationMode>) -> Result<&Self, String> {
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

    fn activate_nixos(&self, mode: &Option<ActivationMode>) -> Result<&Self, String> {
        let mode = mode.clone().unwrap_or(ActivationMode::DryActivate);

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

#[derive(Clone, Debug, Display, VariantNames, Deserialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
#[strum(serialize_all = "kebab-case")]
pub enum SeedType {
    HomeManager,
    NixDarwin,
    Nixos,
}

#[derive(Clone, Debug, Deserialize, Display, ValueEnum, VariantNames)]
#[strum(serialize_all = "kebab-case")]
pub enum ActivationMode {
    Boot,
    DryActivate,
    Switch,
    Test,
    None,
}

#[derive(Debug)]
pub struct Sower {
    pub url: String,
}

impl Sower {
    pub fn new(url: String) -> Result<Sower, Box<dyn std::error::Error>> {
        let seed_url = format!("{}/api/seeds/latest", url);

        Ok(Self { url: seed_url })
    }

    pub async fn find_seed(
        &self,
        name: Option<String>,
        seed_type: SeedType,
    ) -> Result<Seed, Box<dyn std::error::Error>> {
        let name = name.clone().unwrap_or(match seed_type.clone() {
            SeedType::Nixos | SeedType::NixDarwin => nix::unistd::gethostname()
                .expect("Failed getting hostname")
                .into_string()
                .unwrap(),
            SeedType::HomeManager => env::var("USER").expect("can not detect username"),
        });

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
pub struct Tree {}

impl Tree {
    pub fn reboot(confirm: bool) {
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

    pub fn reboot_needed() -> std::io::Result<bool> {
        let profile_paths = &["initrd", "kernel", "kernel-modules"];
        let result = profile_paths.iter().any(|&path| {
            let current_path = format!("/nix/var/nix/profiles/system/{}", path);
            let booted_path = format!("/run/booted-system/{}", path);
            let current = fs::read_link(current_path).expect("unstable to read current link");
            let booted = fs::read_link(booted_path).expect("unable to read booted link");

            current != booted
        });
        Ok(result)
    }

    pub fn run_reboot() {
        run_command(
            "systemd-run".to_string(),
            vec![
                "--on-active=5s".to_string(),
                "--no-block".to_string(),
                "--unit=sower-tree-reboot".to_string(),
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
