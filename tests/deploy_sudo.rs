#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    artifact: PathBuf,
    env_binary: PathBuf,
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
        let env_binary = std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|path| path.join("env"))
            .find(|path| path.is_file())
            .expect("env executable on PATH");
        let shell_binary = std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|path| path.join("sh"))
            .find(|path| path.is_file())
            .expect("sh executable on PATH");
        let bash_binary = std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|path| path.join("bash"))
            .find(|path| path.is_file())
            .expect("bash executable on PATH");
        let fixture = Self {
            root,
            artifact,
            env_binary,
        };
        fs::create_dir(fixture.root.join("bin")).unwrap();
        symlink(&fixture.env_binary, fixture.root.join("bin/env")).unwrap();
        symlink(shell_binary, fixture.root.join("bin/sh")).unwrap();
        symlink(bash_binary, fixture.root.join("bin/bash")).unwrap();
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
command=$*
case "$command" in
    '/usr/bin/env '*) command="env ${command#'/usr/bin/env '}" ;;
esac
exec sh -c "$command"
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
if [ "$1" = '/usr/bin/env' ]; then
    shift
    exec env "$@"
fi
exec "$@"
"#,
        );
        fixture.executable(
            "sower",
            r#"#!/usr/bin/env sh
set -eu
IFS= read -r request
printf '%s\n' "$request" >> "$SOWER_TEST_ROOT/requests"
while IFS= read -r line; do
    printf '%s\n' "$line"
done < "$SOWER_TEST_ROOT/response"
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
        let script = format!(
            "#!{} {}",
            self.env_binary.display(),
            script.strip_prefix("#!/usr/bin/env ").unwrap(),
        );
        fs::write(&path, script).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_sower"));
        command
            .env_clear()
            .env("PATH", self.root.join("bin"))
            .env("HOME", &self.root)
            .env("XDG_CONFIG_HOME", &self.root)
            .env("SOWER_TEST_ROOT", &self.root)
            .env("SOWER_TEST_ARTIFACT", &self.artifact)
            .current_dir(&self.root)
            .args(["deploy", "--config-file"])
            .arg(self.root.join("client.json"));
        command
    }

    fn run(&self, target: &str) -> Output {
        self.command()
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
    assert_eq!(copied.lines().next(), Some("copy"));
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
fn nom_build_output_is_live_and_its_stdout_selects_the_artifact() {
    let fixture = Fixture::new("{\"id\":\"sudo-deploy\",\"type\":\"complete\",\"exit_code\":0}\n");
    fixture.executable(
        "nom",
        r#"#!/usr/bin/env sh
set -eu
printf '%s\n' "$@" > "$SOWER_TEST_ROOT/nom-args"
printf 'nom build is live\n' >&2
printf '%s\n' "$SOWER_TEST_ARTIFACT"
while [ ! -e "$SOWER_TEST_ROOT/release-build" ]; do :; done
"#,
    );

    let mut child = fixture
        .command()
        .arg(".#built-host")
        .args(["--copy-to", "ssh://user@host", "--sudo"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn sower deploy");
    let stderr = child.stderr.take().unwrap();
    let (lines_tx, lines_rx) = mpsc::channel();
    let stderr_reader = thread::spawn(move || {
        for line in BufReader::new(stderr).lines() {
            lines_tx.send(line.unwrap()).unwrap();
        }
    });

    let mut saw_live_output = false;
    for _ in 0..20 {
        let line = lines_rx
            .recv_timeout(Duration::from_millis(250))
            .expect("build output before timeout");
        if line.contains("nom build is live") {
            saw_live_output = true;
            break;
        }
    }
    assert!(saw_live_output);
    assert!(
        child.try_wait().unwrap().is_none(),
        "build already completed"
    );

    fs::write(fixture.root.join("release-build"), "").unwrap();
    let out = child.wait_with_output().expect("finish sower deploy");
    stderr_reader.join().unwrap();
    assert!(
        out.status.success(),
        "stdout: {}\n",
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(out.stdout.is_empty(), "nom stdout leaked from sower");
    assert_eq!(
        fs::read_to_string(fixture.root.join("nom-args")).unwrap(),
        "build\n--no-link\n--print-out-paths\n.#nixosConfigurations.built-host.config.system.build.toplevel\n"
    );
    assert_eq!(
        fixture.request()["path"],
        fixture.artifact.to_str().unwrap()
    );
}

#[test]
fn nix_fallback_prints_build_logs_and_selects_the_artifact() {
    let fixture = Fixture::new("{\"id\":\"sudo-deploy\",\"type\":\"complete\",\"exit_code\":0}\n");
    fixture.executable(
        "nix",
        r#"#!/usr/bin/env sh
set -eu
printf '%s\n' "$@" >> "$SOWER_TEST_ROOT/nix-args"
case "$1" in
    build)
        printf 'plain nix build output\n' >&2
        printf '%s\n' "$SOWER_TEST_ARTIFACT"
        ;;
    copy) ;;
    *) exit 81 ;;
esac
"#,
    );

    let out = fixture
        .command()
        .arg(".#built-host")
        .args(["--copy-to", "ssh://user@host", "--sudo"])
        .output()
        .expect("run sower deploy");

    assert!(
        out.status.success(),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    assert!(String::from_utf8_lossy(&out.stderr).contains("plain nix build output"));
    assert!(out.stdout.is_empty(), "nix stdout leaked from sower");
    let args = fs::read_to_string(fixture.root.join("nix-args")).unwrap();
    assert!(args.lines().any(|arg| arg == "--print-build-logs"));
    assert_eq!(
        fixture.request()["path"],
        fixture.artifact.to_str().unwrap()
    );
}

#[test]
fn failed_nom_build_is_not_retried_or_deployed() {
    let fixture = Fixture::new("{\"id\":\"sudo-deploy\",\"type\":\"complete\",\"exit_code\":0}\n");
    fixture.executable(
        "nom",
        r#"#!/usr/bin/env sh
printf 'nom failed visibly\n' >&2
exit 42
"#,
    );

    let out = fixture
        .command()
        .arg(".#built-host")
        .args(["--copy-to", "ssh://user@host", "--sudo"])
        .output()
        .expect("run sower deploy");

    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("nom failed visibly"));
    assert!(!fixture.root.join("nix-args").exists());
    assert!(!fixture.root.join("ssh-used").exists());
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
