//! Hand-written serde for the garden admin socket protocol.
//!
//! Mirrors `SowerClient.Admin` (sow-201): newline-delimited compact JSON,
//! **adjacently tagged** — the request envelope is `{v, id, kind, payload}`
//! where `kind` selects the command and `payload` carries its fields (omitted
//! for the field-less `reload`/`status`). The garden replies with `ok`/`error`
//! frames then a terminal `complete` frame carrying the exit code.
//!
//! These types are CLI<->garden only and intentionally do not flow through
//! `openapi.json`; see the `SowerClient.Admin` moduledoc.

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

/// Protocol version stamped on every request envelope.
pub const PROTOCOL_VERSION: u32 = 1;

/// Maximum length of a single newline-delimited line, mirroring the garden's
/// `@max_line_bytes`. Requests over this are refused before sending and reply
/// frames over this abort the read.
pub const MAX_LINE_BYTES: usize = 65_536;

const KIND_DEPLOY: &str = "deploy";
const KIND_RELOAD: &str = "reload";
const KIND_STATUS: &str = "status";

/// Request envelope sent CLI -> garden.
#[derive(Debug, Serialize)]
struct Envelope<'a, P: Serialize> {
    v: u32,
    id: &'a str,
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    payload: Option<P>,
}

/// `deploy` payload. Either `seed_type` or `sid` scopes the deployment; the
/// garden rejects a deploy carrying neither.
#[derive(Debug, Serialize)]
struct DeployPayload<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    seed_type: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sid: Option<&'a str>,
    force: bool,
}

/// Encode a `deploy` request to a single JSON line.
pub fn deploy_request(
    id: &str,
    seed_type: Option<&str>,
    sid: Option<&str>,
    force: bool,
) -> Result<String> {
    encode(&Envelope {
        v: PROTOCOL_VERSION,
        id,
        kind: KIND_DEPLOY,
        payload: Some(DeployPayload {
            seed_type,
            sid,
            force,
        }),
    })
}

/// Encode a `reload` request to a single JSON line.
pub fn reload_request(id: &str) -> Result<String> {
    encode(&Envelope::<()> {
        v: PROTOCOL_VERSION,
        id,
        kind: KIND_RELOAD,
        payload: None,
    })
}

/// Encode a `status` request to a single JSON line.
pub fn status_request(id: &str) -> Result<String> {
    encode(&Envelope::<()> {
        v: PROTOCOL_VERSION,
        id,
        kind: KIND_STATUS,
        payload: None,
    })
}

fn encode<P: Serialize>(envelope: &Envelope<P>) -> Result<String> {
    let line = serde_json::to_string(envelope).map_err(anyhow::Error::from)?;
    if line.len() > MAX_LINE_BYTES {
        bail!("request exceeds {MAX_LINE_BYTES} byte limit");
    }
    Ok(line)
}

/// A reply frame received garden -> CLI. The `v`/`id` envelope fields are
/// ignored (serde drops unknown fields); only `kind` and its data matter.
#[derive(Debug, Deserialize)]
pub struct Reply {
    pub kind: ReplyKind,
    #[serde(default)]
    pub data: Option<String>,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub status: Option<StatusReport>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReplyKind {
    Ok,
    Error,
    Complete,
}

/// Garden status returned on the ok frame of a `status` request.
#[derive(Debug, Deserialize)]
pub struct StatusReport {
    pub version: String,
    #[serde(default)]
    pub active_deployments: Vec<String>,
}

/// Parse a single newline-stripped JSON line into a reply frame.
pub fn parse_reply(line: &str) -> Result<Reply> {
    serde_json::from_str(line).map_err(anyhow::Error::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn value(line: &str) -> Value {
        serde_json::from_str(line).unwrap()
    }

    #[test]
    fn deploy_by_type_omits_sid() {
        let line = deploy_request("7", Some("nixos"), None, false).unwrap();
        assert_eq!(
            value(&line),
            json!({"v": 1, "id": "7", "kind": "deploy",
                   "payload": {"seed_type": "nixos", "force": false}})
        );
    }

    #[test]
    fn deploy_by_sid_omits_seed_type_and_carries_force() {
        let line = deploy_request("7", None, Some("abc"), true).unwrap();
        assert_eq!(
            value(&line),
            json!({"v": 1, "id": "7", "kind": "deploy",
                   "payload": {"sid": "abc", "force": true}})
        );
    }

    #[test]
    fn reload_has_no_payload() {
        let line = reload_request("7").unwrap();
        assert_eq!(value(&line), json!({"v": 1, "id": "7", "kind": "reload"}));
    }

    #[test]
    fn status_has_no_payload() {
        let line = status_request("7").unwrap();
        assert_eq!(value(&line), json!({"v": 1, "id": "7", "kind": "status"}));
    }

    #[test]
    fn parse_ok_data_frame() {
        let reply = parse_reply(r#"{"v":1,"id":"7","kind":"ok","data":"enqueued"}"#).unwrap();
        assert_eq!(reply.kind, ReplyKind::Ok);
        assert_eq!(reply.data.as_deref(), Some("enqueued"));
        assert!(reply.status.is_none());
    }

    #[test]
    fn parse_status_frame() {
        let reply = parse_reply(
            r#"{"v":1,"id":"7","kind":"ok","status":{"version":"1.2.3","active_deployments":["a","b"]}}"#,
        )
        .unwrap();
        let status = reply.status.unwrap();
        assert_eq!(status.version, "1.2.3");
        assert_eq!(status.active_deployments, vec!["a", "b"]);
    }

    #[test]
    fn parse_status_frame_defaults_active_deployments() {
        let reply = parse_reply(r#"{"id":"7","kind":"ok","status":{"version":"1.2.3"}}"#).unwrap();
        assert!(reply.status.unwrap().active_deployments.is_empty());
    }

    #[test]
    fn parse_complete_frame_carries_exit_code() {
        let reply = parse_reply(r#"{"v":1,"id":"7","kind":"complete","exit_code":1}"#).unwrap();
        assert_eq!(reply.kind, ReplyKind::Complete);
        assert_eq!(reply.exit_code, Some(1));
    }

    #[test]
    fn parse_error_frame() {
        let reply = parse_reply(r#"{"id":"7","kind":"error","data":"boom"}"#).unwrap();
        assert_eq!(reply.kind, ReplyKind::Error);
        assert_eq!(reply.data.as_deref(), Some("boom"));
    }
}
