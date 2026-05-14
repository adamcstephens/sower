use anyhow::{Context, Result, anyhow};
use std::io::{BufRead, BufReader, Read};
use std::process::{Command, Stdio};
use std::sync::{Arc, mpsc};
use std::thread;

use super::protocol::Request;

pub const SEED_NIXOS: &str = "nixos";
pub const SEED_HOME_MANAGER: &str = "home-manager";
pub const REQ_REBOOT: &str = "reboot";

pub type OutputCallback = Arc<dyn Fn(&str, bool) + Send + Sync>;

pub fn run(req: &Request, callback: OutputCallback) -> Result<i32> {
    match req.kind.as_str() {
        REQ_REBOOT => stream(reboot_cmd(), &callback),
        SEED_HOME_MANAGER => stream(home_manager_cmd(&req.path), &callback),
        SEED_NIXOS => {
            let exit = stream(nixos_profile_cmd(&req.path), &callback)?;
            if exit != 0 {
                return Ok(exit);
            }
            stream(nixos_switch_cmd(&req.path, &req.mode), &callback)
        }
        other => Err(anyhow!("unsupported seed type: {other}")),
    }
}

fn reboot_cmd() -> Command {
    let mut cmd = Command::new("systemctl");
    cmd.arg("reboot");
    cmd
}

fn home_manager_cmd(store_path: &str) -> Command {
    Command::new(format!("{store_path}/activate"))
}

fn nixos_profile_cmd(store_path: &str) -> Command {
    let mut cmd = Command::new("nix-env");
    cmd.args([
        "--set",
        "--profile",
        "/nix/var/nix/profiles/system",
        store_path,
    ]);
    cmd
}

fn nixos_switch_cmd(store_path: &str, mode: &str) -> Command {
    let mut cmd = Command::new(format!("{store_path}/bin/switch-to-configuration"));
    cmd.arg(mode);
    cmd
}

fn stream(mut cmd: Command, callback: &OutputCallback) -> Result<i32> {
    tracing::debug!(cmd = ?cmd, "Running command");

    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().context("spawn child")?;
    let stdout = child.stdout.take().context("stdout pipe")?;
    let stderr = child.stderr.take().context("stderr pipe")?;

    let (tx, rx) = mpsc::channel::<(String, bool)>();
    let tx_err = tx.clone();

    let stdout_thread = thread::spawn(move || pump(stdout, false, tx, None));
    let stderr_thread = thread::spawn(move || pump(stderr, true, tx_err, Some(std::io::stderr())));

    while let Ok((line, is_error)) = rx.recv() {
        callback(&line, is_error);
    }

    let _ = stdout_thread.join();
    let _ = stderr_thread.join();

    let status = child.wait().context("wait")?;
    Ok(status.code().unwrap_or(1))
}

fn pump<R: Read>(
    reader: R,
    is_error: bool,
    tx: mpsc::Sender<(String, bool)>,
    mut mirror: Option<std::io::Stderr>,
) {
    let buf = BufReader::new(reader);
    for line in buf.lines().map_while(Result::ok) {
        if let Some(w) = mirror.as_mut() {
            use std::io::Write;
            let _ = writeln!(w, "{line}");
        }
        let stamped = format!("{} {line}", super::time::rfc3339_now());
        if tx.send((stamped, is_error)).is_err() {
            break;
        }
    }
}
