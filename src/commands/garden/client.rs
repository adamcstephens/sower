//! Connect to the garden admin socket, send one request line, and stream the
//! reply frames to stdout/stderr, returning the terminal `complete` exit code.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};

use super::protocol::{self, MAX_LINE_BYTES, Reply, ReplyKind, StatusReport};

/// Bound how long we wait on a single reply frame. The garden replies promptly
/// (commands enqueue and return), so a stall means it is wedged or gone — fail
/// with a clear error rather than blocking the caller indefinitely.
const REPLY_TIMEOUT: Duration = Duration::from_secs(30);

/// Send `line` to the socket and stream replies until the `complete` frame,
/// returning its exit code.
pub fn run_request(socket: &Path, line: &str) -> Result<i32> {
    let stream = UnixStream::connect(socket)
        .with_context(|| format!("connect to garden admin socket {}", socket.display()))?;
    stream
        .set_read_timeout(Some(REPLY_TIMEOUT))
        .context("set admin socket read timeout")?;

    write_request(&stream, line).context("send admin request")?;

    let mut reader = BufReader::new(&stream);
    let mut out = std::io::stdout();
    let mut err = std::io::stderr();
    stream_replies(&mut reader, &mut out, &mut err)
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
    Ok(())
}

fn emit_error<E: Write>(reply: &Reply, err: &mut E) -> Result<()> {
    if let Some(data) = reply.data.as_deref().filter(|d| !d.is_empty()) {
        writeln!(err, "{data}")?;
    }
    Ok(())
}

fn write_status<O: Write>(status: &StatusReport, out: &mut O) -> Result<()> {
    writeln!(out, "version: {}", status.version)?;
    if status.active_deployments.is_empty() {
        writeln!(out, "active deployments: none")?;
    } else {
        writeln!(
            out,
            "active deployments: {}",
            status.active_deployments.join(", ")
        )?;
    }
    Ok(())
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
    fn status_frame_is_formatted() {
        let input = "{\"id\":\"1\",\"kind\":\"ok\",\"status\":{\"version\":\"1.2.3\",\"active_deployments\":[\"a\",\"b\"]}}\n\
                     {\"id\":\"1\",\"kind\":\"complete\",\"exit_code\":0}\n";
        let (code, out, _err) = stream(input);
        assert_eq!(code, 0);
        assert_eq!(out, "version: 1.2.3\nactive deployments: a, b\n");
    }

    #[test]
    fn status_frame_with_no_active_deployments() {
        let input = "{\"id\":\"1\",\"kind\":\"ok\",\"status\":{\"version\":\"1.2.3\"}}\n\
                     {\"id\":\"1\",\"kind\":\"complete\",\"exit_code\":0}\n";
        let (_code, out, _err) = stream(input);
        assert_eq!(out, "version: 1.2.3\nactive deployments: none\n");
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
