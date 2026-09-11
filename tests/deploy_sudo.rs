#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    artifact: PathBuf,
}

impl Fixture {
    fn new(response: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "sower-deploy-sudo-{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed),
        ));
        fs::create_dir(&root).unwrap();
        let artifact = root.join("artifact with spaces");
        let fixture = Self { root, artifact };
        fs::create_dir(fixture.root.join("bin")).unwrap();
        fs::create_dir(&fixture.artifact).unwrap();
        fs::write(fixture.artifact.join("nixos-version"), "26.05").unwrap();
        fs::write(fixture.root.join("client.json"), "{}").unwrap();
        fs::write(fixture.root.join("response"), response).unwrap();
        fixture.executable(
            "nix",
            r#"#!/usr/bin/env sh
set -eu
printf '%s\n' "$@" >> "$SOWER_TEST_ROOT/nix-args"
case "$1" in
    copy) exit 0 ;;
    *) exit 81 ;;
esac
"#,
        );
        fixture.executable(
            "ssh",
            r#"#!/usr/bin/env sh
set -eu
printf 'connected\n' >> "$SOWER_TEST_ROOT/ssh-used"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -p|-o|-l|-i|-F|-J|-S|-W|-b|-c|-D|-E|-e|-L|-m|-O|-Q|-R|-w) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
[ "$#" -gt 1 ] || exit 82
shift
# OpenSSH joins remote command arguments and lets the remote shell parse them.
exec sh -c "$*"
"#,
        );
        fixture.executable(
            "sudo",
            r#"#!/usr/bin/env sh
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in
        -v|--validate) exit 0 ;;
        -u|--user|-g|--group|-p|--prompt) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
"#,
        );
        fixture.executable(
            "sower",
            r#"#!/usr/bin/env sh
set -eu
IFS= read -r request
printf '%s\n' "$request" >> "$SOWER_TEST_ROOT/requests"
cat "$SOWER_TEST_ROOT/response"
exit 0
"#,
        );
        fixture.executable(
            "curl",
            "#!/usr/bin/env sh\nprintf 'download attempted\\n' > \"$SOWER_TEST_ROOT/download-attempted\"\nexit 83\n",
        );
        fixture
    }

    fn executable(&self, name: &str, script: &str) {
        let path = self.root.join("bin").join(name);
        fs::write(&path, script).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn run(&self, target: &str) -> Output {
        let mut paths = vec![self.root.join("bin")];
        if let Some(path) = std::env::var_os("PATH") {
            paths.extend(std::env::split_paths(&path));
        }
        Command::new(env!("CARGO_BIN_EXE_sower"))
            .env_clear()
            .env("PATH", std::env::join_paths(paths).unwrap())
            .env("HOME", &self.root)
            .env("XDG_CONFIG_HOME", &self.root)
            .env("SOWER_TEST_ROOT", &self.root)
            .current_dir(&self.root)
            .args(["deploy", "--config-file"])
            .arg(self.root.join("client.json"))
            .arg("--path")
            .arg(&self.artifact)
            .args(["--copy-to", target, "--sudo"])
            .output()
            .expect("run sower deploy")
    }

    fn request(&self) -> serde_json::Value {
        let requests = fs::read_to_string(self.root.join("requests"))
            .expect("remote activator received a request");
        serde_json::from_str(&requests).expect("one JSON activation request")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn sudo_deploy_uses_existing_remote_sower_without_server_credentials() {
    let fixture = Fixture::new("{\"id\":\"sudo-deploy\",\"type\":\"complete\",\"exit_code\":0}\n");
    let out = fixture.run("ssh://user@host");
    assert!(
        out.status.success(),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    assert!(fixture.root.join("ssh-used").exists());
    assert!(!fixture.root.join("download-attempted").exists());
    let copied = fs::read_to_string(fixture.root.join("nix-args")).unwrap();
    assert!(copied.lines().any(|arg| arg == "ssh://user@host"));
    assert!(
        copied
            .lines()
            .any(|arg| arg == fixture.artifact.to_str().unwrap())
    );
    let request = fixture.request();
    assert_eq!(request["id"], "sudo-deploy");
    assert_eq!(request["type"], "nixos");
    assert_eq!(request["path"], fixture.artifact.to_str().unwrap());
    assert_eq!(request["mode"], "switch");
}

#[test]
fn activation_failure_is_not_hidden_by_successful_ssh_exit() {
    let fixture = Fixture::new("{\"id\":\"sudo-deploy\",\"type\":\"complete\",\"exit_code\":41}\n");
    let out = fixture.run("ssh://user@host");
    assert_eq!(fixture.request()["id"], "sudo-deploy");
    assert!(!out.status.success(), "activation failure was ignored");
}

#[test]
fn successful_ssh_exit_without_completion_is_not_a_successful_deploy() {
    let fixture =
        Fixture::new("{\"id\":\"sudo-deploy\",\"type\":\"output\",\"data\":\"activating\"}\n");
    let out = fixture.run("ssh://user@host");
    assert_eq!(fixture.request()["id"], "sudo-deploy");
    assert!(!out.status.success(), "missing completion was ignored");
}

#[test]
fn unsupported_target_is_rejected_before_copying_or_connecting() {
    let fixture = Fixture::new("{\"id\":\"sudo-deploy\",\"type\":\"complete\",\"exit_code\":0}\n");
    let out = fixture.run("ssh://user@host/unexpected-store-path");
    assert!(!out.status.success());
    assert!(!fixture.root.join("nix-args").exists());
    assert!(!fixture.root.join("ssh-used").exists());
}
