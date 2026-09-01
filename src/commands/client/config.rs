use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

#[derive(Debug, Default, Deserialize)]
pub struct FileConfig {
    pub endpoint: Option<String>,
    pub access_token: Option<String>,
    pub access_token_file: Option<PathBuf>,
}

impl FileConfig {
    fn merge(&mut self, other: FileConfig) {
        if other.endpoint.is_some() {
            self.endpoint = other.endpoint;
        }
        if other.access_token.is_some() {
            self.access_token = other.access_token;
        }
        if other.access_token_file.is_some() {
            self.access_token_file = other.access_token_file;
        }
    }
}

pub fn load(explicit: &[PathBuf]) -> Result<FileConfig> {
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
        merged.merge(read_one(path)?);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_default_path() {
        let got = default_path_for(Some("root"), |_| None);
        assert_eq!(got, Some(PathBuf::from("/etc/sower/client.json")));
    }

    #[test]
    fn non_root_uses_xdg_config_home() {
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
    fn non_root_falls_back_to_home() {
        let got = default_path_for(Some("alice"), |k| match k {
            "HOME" => Some(PathBuf::from("/home/alice")),
            _ => None,
        });
        assert_eq!(
            got,
            Some(PathBuf::from("/home/alice/.config/sower/client.json"))
        );
    }

    #[test]
    fn merge_later_overrides_earlier() {
        let mut a = FileConfig {
            endpoint: Some("a".into()),
            access_token: Some("ta".into()),
            access_token_file: None,
        };
        a.merge(FileConfig {
            endpoint: Some("b".into()),
            access_token: None,
            access_token_file: Some(PathBuf::from("/tmp/t")),
        });
        assert_eq!(a.endpoint.as_deref(), Some("b"));
        assert_eq!(a.access_token.as_deref(), Some("ta"));
        assert_eq!(a.access_token_file, Some(PathBuf::from("/tmp/t")));
    }

    #[test]
    fn load_skips_missing_files() {
        let cfg = load(&[PathBuf::from("/does/not/exist.json")]).unwrap();
        assert!(cfg.endpoint.is_none());
        assert!(cfg.access_token.is_none());
        assert!(cfg.access_token_file.is_none());
    }

    #[test]
    fn load_merges_files_in_order() {
        let dir = tempdir();
        let a = dir.join("a.json");
        let b = dir.join("b.json");
        std::fs::write(
            &a,
            r#"{"endpoint":"https://a","access_token":"ta","access_token_file":"/a"}"#,
        )
        .unwrap();
        std::fs::write(&b, r#"{"endpoint":"https://b"}"#).unwrap();

        let cfg = load(&[a, b]).unwrap();
        assert_eq!(cfg.endpoint.as_deref(), Some("https://b"));
        assert_eq!(cfg.access_token.as_deref(), Some("ta"));
        assert_eq!(cfg.access_token_file, Some(PathBuf::from("/a")));
    }

    fn tempdir() -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("sower-config-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
