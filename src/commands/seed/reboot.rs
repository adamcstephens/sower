use anyhow::{Context, Result};
use clap::Args as ClapArgs;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::ops::run_inherited;

#[derive(Debug, ClapArgs)]
pub struct Args {
    /// Schedule the reboot when one is needed.
    #[arg(long, short = 'y')]
    pub yes: bool,
}

pub fn run(args: Args) -> Result<()> {
    if !needs_reboot()? {
        tracing::debug!("No reboot needed");
        return Ok(());
    }

    if !args.yes {
        tracing::warn!("Reboot needed, but skipping without --yes");
        return Ok(());
    }

    tracing::info!("Scheduling reboot in ~5 seconds");
    let mut cmd = Command::new("systemd-run");
    cmd.args([
        "--on-active=5s",
        "--no-block",
        "--unit=sower-client-reboot",
        "systemctl",
        "reboot",
    ]);
    run_inherited(cmd).context("schedule reboot")
}

fn needs_reboot() -> Result<bool> {
    needs_reboot_at(
        Path::new("/nix/var/nix/profiles/system"),
        Path::new("/run/current-system"),
        Path::new("/run/booted-system"),
    )
}

fn needs_reboot_at(profile: &Path, current: &Path, booted: &Path) -> Result<bool> {
    let profile = canonicalize(profile)?;
    let current = canonicalize(current)?;
    let booted = canonicalize(booted)?;

    if current != profile {
        tracing::debug!(
            current = %current.display(),
            profile = %profile.display(),
            "Profile differs from current",
        );
        return Ok(true);
    }

    for sub in ["/initrd", "/kernel", "/kernel-modules"] {
        let c = append(&current, sub);
        let b = append(&booted, sub);
        if c != b {
            tracing::debug!(
                sub,
                current = %c.display(),
                booted = %b.display(),
                "Booted component differs",
            );
            return Ok(true);
        }
    }
    Ok(false)
}

fn canonicalize(p: &Path) -> Result<PathBuf> {
    std::fs::canonicalize(p).with_context(|| format!("eval symlink {}", p.display()))
}

fn append(base: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}{suffix}", base.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new(label: &str) -> Self {
            let mut root = std::env::temp_dir();
            root.push(format!("sower-reboot-test-{}-{label}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(&root).unwrap();
            Self { root }
        }

        fn store(&self, name: &str) -> PathBuf {
            let p = self.root.join(name);
            std::fs::create_dir_all(&p).unwrap();
            p
        }

        fn link(&self, name: &str, target: &Path) -> PathBuf {
            let p = self.root.join(name);
            symlink(target, &p).unwrap();
            p
        }
    }

    #[test]
    fn no_reboot_when_all_match() {
        let f = Fixture::new("match");
        let a = f.store("a");
        let profile = f.link("profile", &a);
        let current = f.link("current", &a);
        let booted = f.link("booted", &a);

        assert!(!needs_reboot_at(&profile, &current, &booted).unwrap());
    }

    #[test]
    fn reboot_when_current_differs_from_profile() {
        let f = Fixture::new("profile-drift");
        let a = f.store("a");
        let b = f.store("b");
        let profile = f.link("profile", &a);
        let current = f.link("current", &b);
        let booted = f.link("booted", &b);

        assert!(needs_reboot_at(&profile, &current, &booted).unwrap());
    }

    #[test]
    fn reboot_when_current_differs_from_booted() {
        let f = Fixture::new("booted-drift");
        let a = f.store("a");
        let b = f.store("b");
        let profile = f.link("profile", &a);
        let current = f.link("current", &a);
        let booted = f.link("booted", &b);

        assert!(needs_reboot_at(&profile, &current, &booted).unwrap());
    }

    #[test]
    fn missing_profile_symlink_errors() {
        let f = Fixture::new("missing");
        let a = f.store("a");
        let current = f.link("current", &a);
        let booted = f.link("booted", &a);
        let missing = f.root.join("profile");

        let err = needs_reboot_at(&missing, &current, &booted).unwrap_err();
        assert!(
            err.to_string().contains("eval symlink"),
            "unexpected error: {err}"
        );
    }
}
