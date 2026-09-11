//! One-shot root activation over SSH, without a garden or a local protocol socket.

use anyhow::{Context, Result, anyhow, bail};
use std::io::{Read, Write};
use std::net::Ipv6Addr;
use std::process::{Command, Stdio};

use crate::commands::activator::protocol::{Request, Response, ResponseType};

// Only the stdout pipe from the activator receives this prefix. The shell command
// contains its octal spelling, so terminal echo cannot turn the command into a frame.
const FRAME_PREFIX: &[u8] = b"\x1esower-activator\x1f";

const REMOTE_SCRIPT: &str = r#"
set -o errexit -o nounset -o pipefail
request=$1
download_base=$2
download_error=$3
if binary=$(command -v sower); then
    case "$binary" in
        /*) ;;
        *) binary="$PWD/$binary" ;;
    esac
else
    if [ -n "$download_error" ]; then
        printf '%s\n' "$download_error" >&2
        exit 1
    fi
    case "$(uname --kernel-name)" in
        Linux) os=linux ;;
        *) printf '%s\n' 'Unsupported target operating system for sower download' >&2; exit 1 ;;
    esac
    case "$(uname --machine)" in
        x86_64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) printf '%s\n' 'Unsupported target architecture for sower download' >&2; exit 1 ;;
    esac
    tmp_dir=$(mktemp --directory)
    trap 'rm --recursive --force -- "$tmp_dir"' EXIT
    binary="$tmp_dir/sower"
    curl --fail --location --show-error --proto '=https' --proto-redir '=https' \
        --output "$binary" -- "${download_base}${arch}-${os}"
    chmod u+x -- "$binary"
fi
printf '%s\n' "$request" |
    sudo --user=root -- /usr/bin/env \
        PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$binary" activator |
    while IFS= read -r line; do
        printf '\036sower-activator\037%s\n' "$line"
    done
"#;

#[derive(Debug, PartialEq, Eq)]
struct Target<'a> {
    host: &'a str,
    user: Option<&'a str>,
    port: Option<&'a str>,
}

impl<'a> Target<'a> {
    fn parse(target: &'a str) -> Result<Self> {
        let authority = target
            .strip_prefix("ssh://")
            .or_else(|| target.strip_prefix("ssh-ng://"))
            .ok_or_else(|| anyhow!("--sudo requires an ssh:// or ssh-ng:// copy target"))?;
        if authority.is_empty()
            || authority.bytes().any(|byte| {
                byte.is_ascii_whitespace()
                    || byte.is_ascii_control()
                    || matches!(byte, b'/' | b'?' | b'#' | b'%')
            })
        {
            bail!(
                "SSH copy target must contain only an authority, without a path, query, fragment, or escapes"
            );
        }
        let (user, address) = match authority.split_once('@') {
            Some((user, address)) => {
                if user.is_empty()
                    || !user
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"._-+".contains(&byte))
                {
                    bail!("invalid SSH target username");
                }
                (Some(user), address)
            }
            None => (None, authority),
        };
        let (host, port) = if let Some(address) = address.strip_prefix('[') {
            let (host, suffix) = address
                .split_once(']')
                .ok_or_else(|| anyhow!("unterminated IPv6 SSH target"))?;
            host.parse::<Ipv6Addr>()
                .context("invalid IPv6 SSH target")?;
            let port = if suffix.is_empty() {
                None
            } else {
                Some(
                    suffix
                        .strip_prefix(':')
                        .ok_or_else(|| anyhow!("invalid SSH target after IPv6 address"))?,
                )
            };
            (host, port)
        } else {
            let (host, port) = match address.split_once(':') {
                Some((host, port)) => (host, Some(port)),
                None => (address, None),
            };
            if host.is_empty()
                || host.starts_with('-')
                || !host
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
            {
                bail!("invalid SSH target hostname (IPv6 addresses require brackets)");
            }
            (host, port)
        };
        if let Some(port) = port
            && (port.is_empty()
                || !port.bytes().all(|byte| byte.is_ascii_digit())
                || port.parse::<u16>().ok().filter(|port| *port != 0).is_none())
        {
            bail!("SSH target port must be between 1 and 65535");
        }
        Ok(Self { host, user, port })
    }
}

pub(super) fn validate_target(target: &str) -> Result<()> {
    Target::parse(target).map(|_| ())
}

pub(super) fn run(target: &str, request: &str, endpoint: Option<&str>) -> Result<()> {
    let target = Target::parse(target)?;
    let parsed: Request = serde_json::from_str(request).context("invalid activator request")?;
    if parsed.id.is_empty() {
        bail!("activator request is missing its ID");
    }
    let mut command = Command::new("ssh");
    command.arg("-tt");
    if let Some(user) = target.user {
        command.args(["-l", user]);
    }
    if let Some(port) = target.port {
        command.args(["-p", port]);
    }
    command
        .arg("--")
        .arg(target.host)
        .arg(remote_command(request, endpoint))
        // SSH owns terminal input, including its raw-mode setup and sudo's
        // /dev/tty password exchange. No password enters the protocol pipe.
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    let mut child = command.spawn().context("start SSH root activation")?;
    let stdout = child.stdout.take().expect("SSH stdout was piped");
    let result = stream(stdout, &parsed.id, &mut std::io::stdout().lock());
    if result.is_err() {
        // Let SSH restore the invoking terminal; Child::kill uses SIGKILL and
        // would leave it in raw mode on malformed protocol or output failure.
        if let Some(pid) = rustix::process::Pid::from_raw(child.id() as i32) {
            let _ = rustix::process::kill_process(pid, rustix::process::Signal::TERM);
        }
    }
    let status = child.wait().context("wait for SSH root activation")?;
    let exit_code = result?;
    if !status.success() {
        bail!("SSH root activation transport failed ({status})");
    }
    if exit_code != 0 {
        bail!("root activation failed with exit code {exit_code}");
    }
    Ok(())
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn download_base(endpoint: Option<&str>) -> Result<String> {
    let endpoint = endpoint.ok_or_else(|| {
        anyhow!("sower is absent on the target; configure an HTTPS --endpoint for binary fallback")
    })?;
    if endpoint.bytes().any(|byte| byte.is_ascii_control()) {
        bail!("binary fallback requires a valid HTTPS endpoint");
    }
    let url = reqwest::Url::parse(endpoint)
        .map_err(|_| anyhow!("binary fallback requires a valid HTTPS endpoint"))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        bail!("binary fallback requires an HTTPS endpoint without credentials, query, or fragment");
    }
    Ok(format!(
        "{}/client/bin/",
        url.as_str().trim_end_matches('/')
    ))
}

fn remote_command(request: &str, endpoint: Option<&str>) -> String {
    // A missing or unusable endpoint must not prevent use of an installed
    // sower. The error is raised remotely only in the missing-binary branch.
    let (base, error) = match download_base(endpoint) {
        Ok(base) => (base, String::new()),
        Err(error) => (String::new(), error.to_string()),
    };
    format!(
        "/usr/bin/env bash --noprofile --norc -c {} sower-sudo {} {} {}",
        shell_quote(REMOTE_SCRIPT),
        shell_quote(request),
        shell_quote(&base),
        shell_quote(&error),
    )
}

struct Decoder<'a> {
    id: &'a str,
    pending: Vec<u8>,
    in_frame: bool,
    completion: Option<i32>,
}

impl<'a> Decoder<'a> {
    fn new(id: &'a str) -> Self {
        Self {
            id,
            pending: Vec::new(),
            in_frame: false,
            completion: None,
        }
    }

    fn push(&mut self, bytes: &[u8], terminal: &mut impl Write) -> Result<()> {
        self.pending.extend_from_slice(bytes);
        let mut cursor = 0;
        while cursor < self.pending.len() {
            let remaining = &self.pending[cursor..];
            if self.in_frame {
                let Some(end) = remaining.iter().position(|byte| *byte == b'\n') else {
                    break;
                };
                let response: Response = serde_json::from_slice(&remaining[..end])
                    .context("invalid framed activator response")?;
                if response.id == self.id {
                    if self.completion.is_some() {
                        bail!("activator sent another response after completion");
                    }
                    match response.kind {
                        ResponseType::Complete => {
                            self.completion = Some(response.exit_code.ok_or_else(|| {
                                anyhow!("activator completion is missing its exit code")
                            })?);
                        }
                        ResponseType::Output | ResponseType::Error => {
                            for line in response.data.split_inclusive('\n') {
                                terminal
                                    .write_all(line.trim_end_matches(['\r', '\n']).as_bytes())?;
                                // SSH's terminal raw mode disables local ONLCR.
                                terminal.write_all(b"\r\n")?;
                            }
                        }
                    }
                }
                cursor += end + 1;
                self.in_frame = false;
            } else if let Some(start) = remaining
                .windows(FRAME_PREFIX.len())
                .position(|window| window == FRAME_PREFIX)
            {
                terminal.write_all(&remaining[..start])?;
                cursor += start + FRAME_PREFIX.len();
                self.in_frame = true;
            } else {
                // Keep only a possible split marker, never a partial prompt.
                let retained = (1..FRAME_PREFIX.len().min(remaining.len() + 1))
                    .rev()
                    .find(|length| remaining.ends_with(&FRAME_PREFIX[..*length]))
                    .unwrap_or(0);
                let emitted = remaining.len() - retained;
                terminal.write_all(&remaining[..emitted])?;
                cursor += emitted;
                break;
            }
        }
        self.pending.drain(..cursor);
        terminal.flush()?;
        Ok(())
    }

    fn finish(self, terminal: &mut impl Write) -> Result<i32> {
        if self.in_frame {
            bail!("SSH closed during an activator response frame");
        }
        terminal.write_all(&self.pending)?;
        terminal.flush()?;
        self.completion
            .ok_or_else(|| anyhow!("SSH closed without a matching activator completion"))
    }
}

fn stream(mut reader: impl Read, id: &str, terminal: &mut impl Write) -> Result<i32> {
    let mut decoder = Decoder::new(id);
    let mut bytes = [0; 8192];
    loop {
        let count = match reader.read(&mut bytes) {
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            result => result.context("read SSH activation output")?,
        };
        if count == 0 {
            return decoder.finish(terminal);
        }
        decoder.push(&bytes[..count], terminal)?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(json: &str) -> Vec<u8> {
        [FRAME_PREFIX, json.as_bytes(), b"\r\n"].concat()
    }

    #[test]
    fn ssh_ng_preserves_user_ipv6_and_explicit_port() {
        assert_eq!(
            Target::parse("ssh-ng://builder@[2001:db8::1]:2222").unwrap(),
            Target {
                host: "2001:db8::1",
                user: Some("builder"),
                port: Some("2222"),
            }
        );
        assert_eq!(Target::parse("ssh://worker3").unwrap().host, "worker3");
    }

    #[test]
    fn rejects_ambiguous_or_option_injecting_targets() {
        for target in [
            "worker3",
            "https://worker3",
            "ssh://",
            "ssh://worker3/",
            "ssh://worker3?ssh-key=key",
            "ssh://worker3#fragment",
            "ssh://user:password@worker3",
            "ssh://worker3:0",
            "ssh://worker3:65536",
            "ssh://worker3:",
            "ssh://worker3:22:33",
            "ssh://2001:db8::1",
            "ssh://[::1]suffix",
            "ssh://[not-ipv6]",
            "ssh://-oProxyCommand=evil",
            "ssh://worker3\nother",
            "ssh://user%40other@worker3",
        ] {
            assert!(Target::parse(target).is_err(), "accepted {target:?}");
        }
    }

    #[test]
    fn prompt_is_immediate_and_completion_survives_every_chunk_boundary() {
        let completion = frame(r#"{"id":"sudo-deploy","type":"complete","exit_code":0}"#);
        for split in 0..=completion.len() {
            let mut decoder = Decoder::new("sudo-deploy");
            let mut terminal = Vec::new();
            decoder
                .push(b"[sudo] password for builder: ", &mut terminal)
                .unwrap();
            assert_eq!(terminal, b"[sudo] password for builder: ");
            decoder.push(&completion[..split], &mut terminal).unwrap();
            decoder.push(&completion[split..], &mut terminal).unwrap();
            assert_eq!(decoder.finish(&mut terminal).unwrap(), 0);
            assert_eq!(terminal, b"[sudo] password for builder: ");
        }
    }

    #[test]
    fn echoed_json_and_nested_output_cannot_complete_activation() {
        let mut decoder = Decoder::new("sudo-deploy");
        let mut terminal = Vec::new();
        decoder
            .push(
                b"{\"id\":\"sudo-deploy\",\"type\":\"complete\",\"exit_code\":0}\r\n",
                &mut terminal,
            )
            .unwrap();
        decoder.push(&frame(r#"{"id":"sudo-deploy","type":"output","data":"{\"id\":\"sudo-deploy\",\"type\":\"complete\",\"exit_code\":0}"}"#), &mut terminal).unwrap();
        decoder
            .push(
                &frame(r#"{"id":"another-request","type":"complete","exit_code":0}"#),
                &mut terminal,
            )
            .unwrap();
        assert!(decoder.finish(&mut terminal).is_err());
    }

    #[test]
    fn completion_requires_exit_code_and_cannot_be_overwritten() {
        let mut terminal = Vec::new();
        assert!(
            stream(
                frame(r#"{"id":"sudo-deploy","type":"complete"}"#).as_slice(),
                "sudo-deploy",
                &mut terminal
            )
            .is_err()
        );
        let failure = frame(r#"{"id":"sudo-deploy","type":"complete","exit_code":7}"#);
        assert_eq!(
            stream(failure.as_slice(), "sudo-deploy", &mut terminal).unwrap(),
            7
        );
        let mut duplicate = failure;
        duplicate.extend(frame(
            r#"{"id":"sudo-deploy","type":"complete","exit_code":0}"#,
        ));
        assert!(stream(duplicate.as_slice(), "sudo-deploy", &mut terminal).is_err());
    }

    #[test]
    fn truncated_or_malformed_protocol_never_completes() {
        let complete = frame(r#"{"id":"sudo-deploy","type":"complete","exit_code":0}"#);
        let mut terminal = Vec::new();
        assert!(
            stream(
                &complete[..complete.len() - 2],
                "sudo-deploy",
                &mut terminal
            )
            .is_err()
        );
        assert!(stream(frame("not JSON").as_slice(), "sudo-deploy", &mut terminal).is_err());
    }

    #[test]
    fn fallback_endpoint_disallows_credentials_and_downgrade() {
        assert_eq!(
            download_base(Some("https://sower.example/base/")).unwrap(),
            "https://sower.example/base/client/bin/"
        );
        for endpoint in [
            None,
            Some("http://sower.example"),
            Some("https://user:secret@sower.example"),
            Some("https://sower.example?token=secret"),
            Some("https://sower.example#fragment"),
        ] {
            assert!(download_base(endpoint).is_err());
        }
    }
}
