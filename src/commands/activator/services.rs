use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::activate::{OutputCallback, stream};
use super::protocol::SeedRef;

pub const STATE_DIR: &str = "/var/lib/sower-activator/services";

pub fn run(seeds: &[SeedRef], callback: &OutputCallback) -> Result<i32> {
    let hash = content_hash(seeds);
    let profile_dir = PathBuf::from(STATE_DIR).join(&hash);
    let units_dir = profile_dir.join("systemd").join("system");

    let current_link = PathBuf::from(STATE_DIR).join("current");
    let old_profile = resolve_current(&current_link)?;

    if let Some(ref old) = old_profile
        && old == &profile_dir
    {
        tracing::info!(hash = %hash, "Services already activated");
        callback(
            &format!(
                "{} services already activated (hash={hash})",
                super::time::rfc3339_now()
            ),
            false,
        );
        return Ok(0);
    }

    fs::create_dir_all(&units_dir)
        .with_context(|| format!("create profile dir {}", units_dir.display()))?;

    copy_seeds(seeds, &profile_dir, callback)?;

    let (old_units, _empty_guard) = old_units_path(old_profile.as_deref())?;
    let new_units = units_dir;

    let exit = stream(sd_switch_cmd(&old_units, &new_units), callback)?;
    if exit != 0 {
        return Ok(exit);
    }

    update_current(&current_link, &profile_dir)?;
    Ok(0)
}

pub fn content_hash(seeds: &[SeedRef]) -> String {
    let mut paths: Vec<&str> = seeds.iter().map(|s| s.path.as_str()).collect();
    paths.sort_unstable();
    let mut hasher = Sha256::new();
    for path in paths {
        hasher.update(path.as_bytes());
        hasher.update(b"\n");
    }
    hex_encode(&hasher.finalize())
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn resolve_current(link: &Path) -> Result<Option<PathBuf>> {
    match fs::read_link(link) {
        Ok(target) => {
            let resolved = if target.is_absolute() {
                target
            } else {
                link.parent().unwrap_or(Path::new("/")).join(target)
            };
            Ok(Some(resolved))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err).context(format!("read current symlink {}", link.display())),
    }
}

fn old_units_path(old_profile: Option<&Path>) -> Result<(PathBuf, Option<EmptyDir>)> {
    match old_profile {
        Some(p) => Ok((p.join("systemd").join("system"), None)),
        None => {
            let dir = EmptyDir::new()?;
            let path = dir.path().join("systemd").join("system");
            fs::create_dir_all(&path)
                .with_context(|| format!("create empty old units {}", path.display()))?;
            Ok((path, Some(dir)))
        }
    }
}

fn copy_seeds(seeds: &[SeedRef], profile_dir: &Path, callback: &OutputCallback) -> Result<()> {
    let mut seen: HashSet<PathBuf> = HashSet::new();

    for seed in seeds {
        let source = Path::new(&seed.path).join(".sower").join("systemd");
        warn_collisions(&seed.name, &source, &mut seen, callback);

        let mut src_with_slash = source.into_os_string();
        src_with_slash.push("/");

        let mut cmd = Command::new("cp");
        cmd.arg("--recursive")
            .arg("--no-clobber")
            .arg(&src_with_slash)
            .arg(profile_dir);
        let exit = stream(cmd, callback)?;
        if exit != 0 {
            anyhow::bail!("cp failed for seed {} with exit {}", seed.name, exit);
        }
    }

    Ok(())
}

fn warn_collisions(
    seed_name: &str,
    source: &Path,
    seen: &mut HashSet<PathBuf>,
    callback: &OutputCallback,
) {
    let mut stack = vec![source.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let metadata = match entry.file_type() {
                Ok(ft) => ft,
                Err(_) => continue,
            };
            if metadata.is_dir() {
                stack.push(path);
                continue;
            }
            let rel = path.strip_prefix(source).unwrap_or(&path).to_path_buf();
            if !seen.insert(rel.clone()) {
                let msg = format!(
                    "{} [activator] WARN unit collision: seed={} file={}",
                    super::time::rfc3339_now(),
                    seed_name,
                    rel.display()
                );
                callback(&msg, false);
                tracing::warn!(seed = seed_name, file = %rel.display(), "unit collision");
            }
        }
    }
}

fn sd_switch_cmd(old_units: &Path, new_units: &Path) -> Command {
    let mut cmd = Command::new("sd-switch");
    cmd.arg("--verbose")
        .arg("--system")
        .arg("--old-units")
        .arg(old_units)
        .arg("--new-units")
        .arg(new_units);
    cmd
}

fn update_current(link: &Path, target: &Path) -> Result<()> {
    if let Some(parent) = link.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create state dir {}", parent.display()))?;
    }
    let tmp = link.with_extension("new");
    let _ = fs::remove_file(&tmp);
    std::os::unix::fs::symlink(target, &tmp)
        .with_context(|| format!("symlink {} -> {}", tmp.display(), target.display()))?;
    fs::rename(&tmp, link)
        .with_context(|| format!("rename {} -> {}", tmp.display(), link.display()))?;
    Ok(())
}

struct EmptyDir {
    path: PathBuf,
}

impl EmptyDir {
    fn new() -> Result<Self> {
        let nanos = super::time::rfc3339_now();
        let name = format!(
            "sower-activator-empty-{}-{}",
            std::process::id(),
            nanos.replace(':', "-")
        );
        let path = std::env::temp_dir().join(name);
        fs::create_dir_all(&path).with_context(|| format!("create temp dir {}", path.display()))?;
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for EmptyDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seed(name: &str, path: &str) -> SeedRef {
        SeedRef {
            name: name.to_string(),
            path: path.to_string(),
        }
    }

    #[test]
    fn content_hash_is_deterministic() {
        let a = vec![
            seed("foo", "/nix/store/aaa-foo"),
            seed("bar", "/nix/store/bbb-bar"),
        ];
        let b = vec![
            seed("bar", "/nix/store/bbb-bar"),
            seed("foo", "/nix/store/aaa-foo"),
        ];
        assert_eq!(content_hash(&a), content_hash(&b));
    }

    #[test]
    fn content_hash_uses_paths_not_names() {
        let a = vec![seed("foo", "/nix/store/aaa-foo")];
        let b = vec![seed("renamed", "/nix/store/aaa-foo")];
        assert_eq!(content_hash(&a), content_hash(&b));
    }

    #[test]
    fn content_hash_differs_for_different_paths() {
        let a = vec![seed("foo", "/nix/store/aaa-foo")];
        let b = vec![seed("foo", "/nix/store/bbb-foo")];
        assert_ne!(content_hash(&a), content_hash(&b));
    }

    #[test]
    fn update_current_atomically_replaces_existing_symlink() {
        let tmp = tempdir();
        let link = tmp.join("current");
        let first = tmp.join("first");
        let second = tmp.join("second");
        fs::create_dir_all(&first).unwrap();
        fs::create_dir_all(&second).unwrap();

        update_current(&link, &first).unwrap();
        assert_eq!(fs::read_link(&link).unwrap(), first);

        update_current(&link, &second).unwrap();
        assert_eq!(fs::read_link(&link).unwrap(), second);

        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn resolve_current_returns_none_when_missing() {
        let tmp = tempdir();
        let link = tmp.join("missing");
        assert!(resolve_current(&link).unwrap().is_none());
        fs::remove_dir_all(&tmp).unwrap();
    }

    fn tempdir() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "sower-services-test-{}-{}",
            std::process::id(),
            uniq()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn uniq() -> u64 {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        COUNTER.fetch_add(1, Ordering::Relaxed)
    }
}
