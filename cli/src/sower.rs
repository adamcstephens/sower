use clap::ValueEnum;
use serde::Deserialize;
use std::io::{self, Write};
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
        let output = Command::new("nix-store")
            .args(["--realize", &self.out_path])
            .output()
            .unwrap_or_else(|_| panic!("failed to realize {:?}", &self.out_path));

        io::stdout().write_all(&output.stdout).unwrap();
        io::stderr().write_all(&output.stderr).unwrap();

        match output.status.success() {
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
        let result = &mut Command::new(format!("{}/activate", &self.out_path));

        let output = result.output().expect("failed to get output");

        let _exit_code = result.status().expect("failed to set system profile");

        io::stdout().write_all(&output.stdout).unwrap();
        io::stderr().write_all(&output.stderr).unwrap();

        match output.status.success() {
            true => Ok(self),
            false => Err(format!("failed to realize: {}", &self.out_path)),
        }
    }

    fn activate_nixos(&self, mode: &Option<ActivationMode>) -> Result<&Self, String> {
        let mode = mode.clone().unwrap_or(ActivationMode::DryActivate);

        // nixos profile needs to be manually set to ensure correct switching
        let command = &mut Command::new("nix-env");
        let result = command.args([
            "--set",
            "--profile",
            "/nix/var/nix/profiles/system",
            &self.out_path,
        ]);

        let output = result.output().expect("failed to get output");

        let _exit_code = result.status().expect("failed to set system profile");

        io::stdout().write_all(&output.stdout).unwrap();
        io::stderr().write_all(&output.stderr).unwrap();

        // activate

        let command = &mut Command::new(format!("{}/bin/switch-to-configuration", &self.out_path));
        let result = command.args([mode.to_string()]);

        let output = result.output().expect("failed to get output");

        let _exit_code = result.status().expect("failed to set system profile");

        io::stdout().write_all(&output.stdout).unwrap();
        io::stderr().write_all(&output.stderr).unwrap();

        match output.status.success() {
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
