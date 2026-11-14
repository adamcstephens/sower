//! Connect to the garden admin socket, send one request line, and stream the
//! reply frames to stdout/stderr, returning the terminal `complete` exit code.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};

use super::protocol::{self, MAX_LINE_BYTES, PendingDeployment, Reply, ReplyKind, StatusReport};

/// Bound idle reads for immediate admin commands.
const REPLY_TIMEOUT: Duration = Duration::from_secs(30);

/// Send `line` to the socket and stream replies until the `complete` frame,
/// returning its exit code.
pub fn run_request(socket: &Path, line: &str, wait_timeout: Option<u32>) -> Result<i32> {
    let stream = UnixStream::connect(socket)
        .with_context(|| format!("connect to garden admin socket {}", socket.display()))?;
    stream
        .set_read_timeout(Some(reply_timeout(wait_timeout)))
        .context("set admin socket read timeout")?;

    write_request(&stream, line).context("send admin request")?;

    let mut reader = BufReader::new(&stream);
    let mut out = std::io::stdout();
    let mut err = std::io::stderr();
    stream_replies(&mut reader, &mut out, &mut err)
}

fn reply_timeout(wait_timeout: Option<u32>) -> Duration {
    wait_timeout.map_or(REPLY_TIMEOUT, |seconds| {
        REPLY_TIMEOUT.max(Duration::from_secs(u64::from(seconds) + 5))
    })
}

fn write_request(mut stream: &UnixStream, line: &str) -> Result<()> {
    stream.write_all(line.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    Ok(())
}

fn stream_replies<R: BufRead, O: Write, E: Write>(
    reader: &mut R,
    out: &mut O,
    err: &mut E,
) -> Result<i32> {
    while let Some(line) = read_line_capped(reader, MAX_LINE_BYTES)? {
        let reply = protocol::parse_reply(&line).context("decode reply frame")?;
        match reply.kind {
            ReplyKind::Ok => emit_ok(&reply, out)?,
            ReplyKind::Error => emit_error(&reply, err)?,
            ReplyKind::Complete => {
                return reply
                    .exit_code
                    .ok_or_else(|| anyhow!("complete frame missing exit_code"));
            }
        }
    }
    Err(anyhow!(
        "garden closed the connection without a complete frame"
    ))
}

fn emit_ok<O: Write>(reply: &Reply, out: &mut O) -> Result<()> {
    if let Some(status) = &reply.status {
        write_status(status, out)?;
    }
    if let Some(data) = reply.data.as_deref().filter(|d| !d.is_empty()) {
        writeln!(out, "{data}")?;
    }
    out.flush()?;
    Ok(())
}

fn emit_error<E: Write>(reply: &Reply, err: &mut E) -> Result<()> {
    if let Some(data) = reply.data.as_deref().filter(|d| !d.is_empty()) {
        writeln!(err, "{data}")?;
    }
    err.flush()?;
    Ok(())
}

fn write_status<O: Write>(status: &StatusReport, out: &mut O) -> Result<()> {
    writeln!(out, "version: {}", status.version)?;
    let mut table = comfy_table::Table::new();
    table
        .load_style(comfy_table::presets::NOTHING)
        .set_content_arrangement(comfy_table::ContentArrangement::Disabled)
        .set_header(["SEED", "TYPE", "STATE", "SEED UPDATED"]);
    match &status.running_deployments {
        Some(running) => {
            for deployment in running {
                let state = format!(
                    "running {}",
                    hyperlink(&deployment.deployment_url, &deployment.deployment_sid)
                );
                if deployment.seeds.is_empty() {
                    table.add_row(["unknown", "unknown", &state, "unknown"]);
                } else {
                    for seed in &deployment.seeds {
                        table.add_row(seed_row(seed, &state));
                    }
                }
            }
        }
        None => {
            for sid in &status.active_deployments {
                table.add_row(["unknown", "unknown", &format!("running {sid}"), "unknown"]);
            }
        }
    }
    if let Some(pending) = &status.pending_deployments {
        for seed in pending {
            table.add_row(seed_row(seed, "pending"));
        }
    }
    writeln!(out, "{}", table.trim_fmt())?;
    if status
        .running_deployments
        .as_ref()
        .map_or(status.active_deployments.is_empty(), |running| {
            running.is_empty()
        })
    {
        writeln!(out, "running deployments: none")?;
    }
    match status.pending_deployments.as_deref() {
        None => writeln!(out, "pending deployments: unknown")?,
        Some([]) => writeln!(out, "pending deployments: none")?,
        Some(_) => {}
    }
    match &status.credentials_rejected_at {
        Some(at) => writeln!(
            out,
            "credentials: rejected at {at}, awaiting operator re-registration (sower garden reregister)"
        )?,
        None => writeln!(out, "credentials: ok")?,
    }
    Ok(())
}

fn hyperlink(url: &str, label: &str) -> String {
    format!("\x1b]8;;{url}\x1b\\{label}\x1b]8;;\x1b\\")
}

fn seed_row(seed: &PendingDeployment, state: &str) -> [String; 4] {
    let sid = hyperlink(&seed.seed_url, &seed.seed_sid);
    let label = match seed.name.as_deref() {
        Some(name) => format!("{} ({sid})", hyperlink(&seed.seed_url, name)),
        None => sid,
    };
    [
        label,
        seed.seed_type.as_deref().unwrap_or("unknown").to_owned(),
        state.to_owned(),
        seed.updated_at.as_deref().unwrap_or("unknown").to_owned(),
    ]
}

/// Read a single newline-terminated line, capping its length at `max` bytes so
/// an over-long frame aborts rather than buffering unbounded. Returns `None` at
/// a clean EOF.
fn read_line_capped<R: BufRead>(reader: &mut R, max: usize) -> Result<Option<String>> {
    let mut buf = Vec::new();
    loop {
        let chunk = match reader.fill_buf() {
            Ok(chunk) => chunk,
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                bail!("timed out waiting for a reply from the garden");
            }
            Err(e) => return Err(e).context("read reply frame"),
        };
        if chunk.is_empty() {
            return if buf.is_empty() {
                Ok(None)
            } else {
                Err(anyhow!("reply frame truncated (no trailing newline)"))
            };
        }
        match chunk.iter().position(|&b| b == b'\n') {
            Some(i) => {
                if buf.len() + i > max {
                    bail!("reply frame exceeds {max} byte limit");
                }
                buf.extend_from_slice(&chunk[..i]);
                reader.consume(i + 1);
                break;
            }
            None => {
                let n = chunk.len();
                if buf.len() + n > max {
                    bail!("reply frame exceeds {max} byte limit");
                }
                buf.extend_from_slice(chunk);
                reader.consume(n);
            }
        }
    }
    Ok(Some(
        String::from_utf8(buf).context("reply frame not valid UTF-8")?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn stream(input: &str) -> (i32, String, String) {
        let mut reader = Cursor::new(input.as_bytes().to_vec());
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = stream_replies(&mut reader, &mut out, &mut err).unwrap();
        (
            code,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    #[test]
    fn observation_timeout_includes_grace_period() {
        assert_eq!(reply_timeout(None), Duration::from_secs(30));
        assert_eq!(reply_timeout(Some(1)), Duration::from_secs(30));
        assert_eq!(reply_timeout(Some(75)), Duration::from_secs(80));
        assert_eq!(reply_timeout(Some(86_400)), Duration::from_secs(86_405));
    }

    #[test]
    fn streamed_frames_flush_before_completion() {
        #[derive(Default)]
        struct Output {
            bytes: Vec<u8>,
            flushes: usize,
        }

        impl Write for Output {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.bytes.extend_from_slice(bytes);
                Ok(bytes.len())
            }

            fn flush(&mut self) -> std::io::Result<()> {
                self.flushes += 1;
                Ok(())
            }
        }

        let mut reader = Cursor::new(concat!(
            "{\"kind\":\"ok\",\"data\":\"starting\"}\n",
            "{\"kind\":\"ok\",\"data\":\"output\"}\n",
            "{\"kind\":\"error\",\"data\":\"failed\"}\n",
            "{\"kind\":\"complete\",\"exit_code\":1}\n",
        ));
        let mut out = Output::default();
        let mut err = Output::default();
        assert_eq!(stream_replies(&mut reader, &mut out, &mut err).unwrap(), 1);
        assert_eq!(out.bytes, b"starting\noutput\n");
        assert_eq!(err.bytes, b"failed\n");
        assert_eq!(out.flushes, 2);
        assert_eq!(err.flushes, 1);
    }

    #[test]
    fn ok_then_complete_streams_data_and_exit_zero() {
        let input = "{\"id\":\"1\",\"kind\":\"ok\",\"data\":\"enqueued\"}\n\
                     {\"id\":\"1\",\"kind\":\"complete\",\"exit_code\":0}\n";
        let (code, out, err) = stream(input);
        assert_eq!(code, 0);
        assert_eq!(out, "enqueued\n");
        assert_eq!(err, "");
    }

    #[test]
    fn error_then_complete_streams_to_stderr_and_exit_one() {
        let input = "{\"id\":\"1\",\"kind\":\"error\",\"data\":\"boom\"}\n\
                     {\"id\":\"1\",\"kind\":\"complete\",\"exit_code\":1}\n";
        let (code, out, err) = stream(input);
        assert_eq!(code, 1);
        assert_eq!(out, "");
        assert_eq!(err, "boom\n");
    }

    #[test]
    fn status_links_each_pending_seed_with_osc8() {
        let input = concat!(
            r#"{"kind":"ok","status":{"version":"1.2.3","pending_deployments":["#,
            r#"{"seed_sid":"seed-a","seed_url":"https://sower.example/seeds/seed-a"},"#,
            r#"{"seed_sid":"seed-b","seed_url":"https://sower.example/seeds/seed-b"}]}}"#,
            "\n{\"kind\":\"complete\",\"exit_code\":0}\n"
        );
        let (code, out, err) = stream(input);
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(out.contains(&hyperlink("https://sower.example/seeds/seed-a", "seed-a")));
        assert!(out.contains(&hyperlink("https://sower.example/seeds/seed-b", "seed-b")));
        assert_eq!(out.matches("pending").count(), 2);
    }

    #[test]
    fn unified_table_preserves_links_and_aligns_unicode_display_width() {
        let status = serde_json::json!({
            "version": "1.2.3",
            "active_deployments": ["deploy-a"],
            "running_deployments": [{
                "deployment_sid": "deploy-a",
                "deployment_url": "https://sower.example/deployments/deploy-a",
                "seeds": [{
                    "seed_sid": "seed-a",
                    "seed_url": "https://sower.example/seeds/seed-a",
                    "name": "庭🌱",
                    "seed_type": "nixos",
                    "updated_at": "2026-11-14T19:00:00Z"
                }]
            }],
            "pending_deployments": [{
                "seed_sid": "seed-b",
                "seed_url": "https://sower.example/seeds/seed-b",
                "name": "cafe\u{301}",
                "seed_type": "nixos",
                "updated_at": "2026-11-14T20:00:00+01:00"
            }]
        });
        let input = format!(
            "{{\"kind\":\"ok\",\"status\":{status}}}\n{{\"kind\":\"complete\",\"exit_code\":0}}\n"
        );
        let (_, out, err) = stream(&input);
        assert!(err.is_empty());
        for (url, text) in [
            ("https://sower.example/seeds/seed-a", "庭🌱"),
            ("https://sower.example/seeds/seed-a", "seed-a"),
            ("https://sower.example/seeds/seed-b", "cafe\u{301}"),
            ("https://sower.example/seeds/seed-b", "seed-b"),
            ("https://sower.example/deployments/deploy-a", "deploy-a"),
        ] {
            assert!(out.contains(&hyperlink(url, text)));
        }
        let header = out
            .lines()
            .find(|line| line.contains("SEED UPDATED"))
            .unwrap();
        let type_column = console::measure_text_width(&header[..header.find("TYPE").unwrap()]);
        let state_column = console::measure_text_width(&header[..header.find("STATE").unwrap()]);
        let updated_column =
            console::measure_text_width(&header[..header.find("SEED UPDATED").unwrap()]);
        for (row, state, updated) in [
            ("庭🌱", "running ", "2026-11-14T19:00:00Z"),
            ("cafe\u{301}", "pending", "2026-11-14T20:00:00+01:00"),
        ] {
            let line = out.lines().find(|line| line.contains(row)).unwrap();
            assert_eq!(
                console::measure_text_width(&line[..line.find("nixos").unwrap()]),
                type_column
            );
            assert_eq!(
                console::measure_text_width(&line[..line.find(state).unwrap()]),
                state_column
            );
            assert_eq!(
                console::measure_text_width(&line[..line.find(updated).unwrap()]),
                updated_column
            );
        }
        assert_eq!(out.matches("SEED UPDATED").count(), 1);
        assert!(!out.contains("active"));
        assert!(out.contains("version: 1.2.3"));
        assert!(out.contains("credentials: ok"));
    }

    #[test]
    fn legacy_running_and_pending_rows_remain_readable() {
        let input = concat!(
            r#"{"kind":"ok","status":{"version":"old","active_deployments":["deploy-old"],"pending_deployments":[{"seed_sid":"seed-old","seed_url":"https://sower.example/seeds/seed-old"}]}}"#,
            "\n{\"kind\":\"complete\",\"exit_code\":0}\n"
        );
        let (_, out, _) = stream(input);
        assert!(out.contains("running deploy-old"));
        assert!(out.contains(&hyperlink(
            "https://sower.example/seeds/seed-old",
            "seed-old"
        )));
        assert!(out.contains("unknown"));
        assert!(!out.contains("pending deployments: none"));
    }

    #[test]
    fn status_distinguishes_no_pending_seeds_from_unavailable_status() {
        for (status, expected) in [
            (r#"{"version":"1.2.3"}"#, "pending deployments: unknown"),
            (
                r#"{"version":"1.2.3","pending_deployments":null}"#,
                "pending deployments: unknown",
            ),
            (
                r#"{"version":"1.2.3","pending_deployments":[]}"#,
                "pending deployments: none",
            ),
        ] {
            let input = format!(
                "{{\"kind\":\"ok\",\"status\":{status}}}\n\
                 {{\"kind\":\"complete\",\"exit_code\":0}}\n"
            );
            let (code, out, err) = stream(&input);
            assert_eq!(code, 0);
            assert!(err.is_empty());
            let pending = out
                .lines()
                .find(|line| line.starts_with("pending deployments: "))
                .unwrap();
            assert_eq!(pending, expected);
        }
    }

    #[test]
    fn status_frame_reports_rejected_credentials() {
        let input = "{\"id\":\"1\",\"kind\":\"ok\",\"status\":{\"version\":\"1.2.3\",\"credentials_rejected_at\":\"2026-08-29T00:00:00Z\"}}\n\
                     {\"id\":\"1\",\"kind\":\"complete\",\"exit_code\":0}\n";
        let (_code, out, _err) = stream(input);
        assert!(out.contains("credentials: rejected at 2026-08-29T00:00:00Z"));
        assert!(out.contains("awaiting operator re-registration"));
    }

    #[test]
    fn missing_complete_frame_errors() {
        let mut reader = Cursor::new(b"{\"id\":\"1\",\"kind\":\"ok\",\"data\":\"x\"}\n".to_vec());
        let mut out = Vec::new();
        let mut err = Vec::new();
        assert!(stream_replies(&mut reader, &mut out, &mut err).is_err());
    }

    #[test]
    fn read_line_capped_rejects_over_long_line() {
        let mut reader = Cursor::new(vec![b'x'; 100]);
        let got = read_line_capped(&mut reader, 10);
        assert!(got.is_err());
    }

    #[test]
    fn read_line_capped_reads_short_lines() {
        let mut reader = Cursor::new(b"hello\nworld\n".to_vec());
        assert_eq!(
            read_line_capped(&mut reader, 64).unwrap().as_deref(),
            Some("hello")
        );
        assert_eq!(
            read_line_capped(&mut reader, 64).unwrap().as_deref(),
            Some("world")
        );
        assert_eq!(read_line_capped(&mut reader, 64).unwrap(), None);
    }
}
