use anyhow::{Context, Result, anyhow};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

use super::activate::{self, OutputCallback, REQ_REBOOT, SEED_HOME_MANAGER, SEED_NIXOS};
use super::log_tee::CallbackSlot;
use super::peercred;
use super::protocol::{Request, Response, ResponseType};

const VALID_MODES: &[&str] = &["switch", "boot", "test", "dry-activate"];

pub fn run(conn: UnixStream, allowed_gids: &[u32], slot: &CallbackSlot) -> Result<()> {
    let writer = Arc::new(Mutex::new(conn.try_clone().context("clone socket")?));
    let send = |resp: &Response| {
        let mut w = writer.lock().unwrap();
        if let Err(err) = serde_json::to_writer(&mut *w, resp) {
            tracing::error!(?err, "Failed to send response");
            return;
        }
        if let Err(err) = w.write_all(b"\n") {
            tracing::error!(?err, "Failed to send response");
        }
    };

    let creds = match peercred::get(std::os::fd::AsFd::as_fd(&conn)) {
        Ok(c) => c,
        Err(err) => {
            tracing::error!(?err, "Failed to get peer credentials");
            send(&Response::error("", "failed to get peer credentials"));
            return Ok(());
        }
    };
    tracing::debug!(
        pid = creds.pid,
        uid = creds.uid,
        gid = creds.gid,
        "Connection from peer"
    );

    if !peercred::is_authorized(&creds, allowed_gids) {
        tracing::warn!(
            uid = creds.uid,
            gid = creds.gid,
            "Unauthorized connection attempt"
        );
        send(&Response::error("", "unauthorized"));
        return Ok(());
    }

    let mut req = match read_request(&conn) {
        Ok(req) => req,
        Err(err) => {
            tracing::error!(?err, "Failed to read request");
            send(&Response::error("", err.to_string()));
            return Ok(());
        }
    };

    tracing::info!(
        "Received request id={} type={} path={} mode={} reason={}",
        req.id, req.kind, req.path, req.mode, req.reason
    );

    if let Err(err) = validate(&mut req) {
        tracing::warn!(id = %req.id, %err, "Invalid request");
        send(&Response::error(req.id, err.to_string()));
        return Ok(());
    }

    let cb_writer = Arc::clone(&writer);
    let cb_id = req.id.clone();
    let callback: OutputCallback = Arc::new(move |line: &str, is_error: bool| {
        let resp = if is_error {
            Response::error(&cb_id, line)
        } else {
            Response::output(&cb_id, line)
        };
        let mut w = cb_writer.lock().unwrap();
        if serde_json::to_writer(&mut *w, &resp).is_ok() {
            let _ = w.write_all(b"\n");
        }
    });

    slot.set(Arc::clone(&callback));
    let exit_code = match activate::run(&req, callback) {
        Ok(code) => code,
        Err(err) => {
            tracing::error!(id = %req.id, r#type = %req.kind, %err, "Request failed");
            send(&Response {
                id: req.id.clone(),
                kind: ResponseType::Error,
                data: err.to_string(),
                exit_code: None,
            });
            1
        }
    };
    slot.clear();

    send(&Response::complete(req.id, exit_code));
    Ok(())
}

fn read_request(conn: &UnixStream) -> Result<Request> {
    let mut reader = BufReader::new(conn);
    let mut line = String::new();
    let n = reader.read_line(&mut line).context("read request")?;
    if n == 0 {
        return Err(anyhow!("empty request"));
    }
    serde_json::from_str(&line).context("invalid JSON")
}

fn validate(req: &mut Request) -> Result<()> {
    if req.id.is_empty() {
        return Err(anyhow!("missing request ID"));
    }
    if req.kind == REQ_REBOOT {
        return Ok(());
    }
    if req.kind != SEED_NIXOS && req.kind != SEED_HOME_MANAGER {
        return Err(anyhow!("invalid type: {}", req.kind));
    }
    if !req.path.starts_with("/nix/store/") {
        return Err(anyhow!("path must be in /nix/store"));
    }
    if req.path.split('/').any(|part| part == "..") {
        return Err(anyhow!("invalid path"));
    }
    if req.kind == SEED_NIXOS && !VALID_MODES.contains(&req.mode.as_str()) {
        return Err(anyhow!("invalid mode: {}", req.mode));
    }
    Ok(())
}
