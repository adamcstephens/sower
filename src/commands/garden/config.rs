//! Resolve the garden admin socket path: explicit flag/env, then the
//! `admin_socket` key of the client config file(s), then the built-in default.
//!
//! The default mirrors `SowerClient.Config.default_admin_socket/0`: a non-root
//! user binds under `$XDG_RUNTIME_DIR/sower-garden`, otherwise `/run`.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    admin_socket: Option<PathBuf>,
}

/// Resolve the socket path from the flag/env override, config file, or default.
pub fn resolve_socket(flag: Option<PathBuf>, config_files: &[PathBuf]) -> Result<PathBuf> {
    if let Some(path) = flag {
        return Ok(path);
    }
    if let Some(path) = load(config_files)?.admin_socket {
        return Ok(path);
    }
    Ok(default_admin_socket())
}

fn load(explicit: &[PathBuf]) -> Result<FileConfig> {
    let paths: Vec<PathBuf> = if explicit.is_empty() {
        default_path().into_iter().collect()
    } else {
        explicit.to_vec()
    };

    let mut merged = FileConfig::default();
    for path in &paths {
        if !path.exists() {
            tracing::debug!(file = %path.display(), "config file does not exist; skipping");
            continue;
        }
        tracing::debug!(file = %path.display(), "loading config file");
        if let Some(socket) = read_one(path)?.admin_socket {
            merged.admin_socket = Some(socket);
        }
    }
    Ok(merged)
}

fn read_one(path: &Path) -> Result<FileConfig> {
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("read config file: {}", path.display()))?;
    serde_json::from_str(&raw).with_context(|| format!("parse config file: {}", path.display()))
}

fn default_path() -> Option<PathBuf> {
    default_path_for(std::env::var("USER").ok().as_deref(), |k| {
        std::env::var_os(k).map(PathBuf::from)
    })
}

fn default_path_for(user: Option<&str>, env: impl Fn(&str) -> Option<PathBuf>) -> Option<PathBuf> {
    if user == Some("root") {
        return Some(PathBuf::from("/etc/sower/client.json"));
    }
    let base = env("XDG_CONFIG_HOME").or_else(|| env("HOME").map(|h| h.join(".config")))?;
    Some(base.join("sower").join("client.json"))
}

fn default_admin_socket() -> PathBuf {
    default_admin_socket_for(
        std::env::var("USER").ok().as_deref(),
        std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from),
    )
}

fn default_admin_socket_for(user: Option<&str>, xdg_runtime: Option<PathBuf>) -> PathBuf {
    match xdg_runtime {
        Some(dir) if user != Some("root") => dir.join("sower-garden").join("admin.sock"),
        _ => PathBuf::from("/run/sower-garden/admin.sock"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flag_overrides_everything() {
        let got = resolve_socket(Some(PathBuf::from("/tmp/explicit.sock")), &[]).unwrap();
        assert_eq!(got, PathBuf::from("/tmp/explicit.sock"));
    }

    #[test]
    fn reads_admin_socket_from_config_file() {
        let dir = tempdir("reads-admin-socket");
        let cfg = dir.join("client.json");
        std::fs::write(&cfg, r#"{"admin_socket":"/run/custom/admin.sock"}"#).unwrap();

        let got = resolve_socket(None, &[cfg]).unwrap();
        assert_eq!(got, PathBuf::from("/run/custom/admin.sock"));
    }

    #[test]
    fn later_config_file_overrides_earlier() {
        let dir = tempdir("later-overrides-earlier");
        let a = dir.join("a.json");
        let b = dir.join("b.json");
        std::fs::write(&a, r#"{"admin_socket":"/run/a.sock"}"#).unwrap();
        std::fs::write(&b, r#"{"admin_socket":"/run/b.sock"}"#).unwrap();

        let got = resolve_socket(None, &[a, b]).unwrap();
        assert_eq!(got, PathBuf::from("/run/b.sock"));
    }

    #[test]
    fn ignores_config_without_admin_socket() {
        let dir = tempdir("ignores-without-admin-socket");
        let cfg = dir.join("client.json");
        std::fs::write(&cfg, r#"{"endpoint":"https://x"}"#).unwrap();

        // Falls through to the default rather than erroring.
        let got = resolve_socket(None, &[cfg]).unwrap();
        assert!(got.ends_with("admin.sock"));
    }

    #[test]
    fn root_default_config_path() {
        let got = default_path_for(Some("root"), |_| None);
        assert_eq!(got, Some(PathBuf::from("/etc/sower/client.json")));
    }

    #[test]
    fn non_root_config_path_uses_xdg() {
        let got = default_path_for(Some("alice"), |k| match k {
            "XDG_CONFIG_HOME" => Some(PathBuf::from("/home/alice/.config")),
            _ => None,
        });
        assert_eq!(
            got,
            Some(PathBuf::from("/home/alice/.config/sower/client.json"))
        );
    }

    #[test]
    fn default_socket_root_uses_run() {
        let got = default_admin_socket_for(Some("root"), Some(PathBuf::from("/run/user/0")));
        assert_eq!(got, PathBuf::from("/run/sower-garden/admin.sock"));
    }

    #[test]
    fn default_socket_user_uses_xdg_runtime() {
        let got = default_admin_socket_for(Some("alice"), Some(PathBuf::from("/run/user/1000")));
        assert_eq!(got, PathBuf::from("/run/user/1000/sower-garden/admin.sock"));
    }

    #[test]
    fn default_socket_user_without_runtime_dir_falls_back_to_run() {
        let got = default_admin_socket_for(Some("alice"), None);
        assert_eq!(got, PathBuf::from("/run/sower-garden/admin.sock"));
    }

    fn tempdir(label: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "sower-garden-config-test-{}-{label}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
