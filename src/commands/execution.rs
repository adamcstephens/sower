use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Args, Subcommand};

use crate::api::{Client, types};
use crate::commands::client::ConnectionArgs;

#[derive(Debug, Args)]
pub struct ExecutionArgs {
    #[command(flatten)]
    connection: ConnectionArgs,
    #[command(subcommand)]
    command: ExecutionCommand,
}

#[derive(Debug, Subcommand)]
enum ExecutionCommand {
    /// Queue a literal JSON execution request; follows unless detached.
    Submit {
        /// JSON request file, or - to read the request from stdin.
        #[arg(long)]
        request: PathBuf,
        /// Print the execution SID without waiting. Does not cancel the execution.
        #[arg(long)]
        detach: bool,
    },
    /// Show an execution as JSON.
    Status { sid: String },
    /// List the latest 100 organization executions as JSON.
    List,
    /// Print stdout/stderr history, optionally following until terminal.
    Logs {
        sid: String,
        #[arg(long)]
        follow: bool,
        /// Resume strictly after this event sequence.
        #[arg(long, default_value_t = 0)]
        after: u64,
    },
    /// Persist cancellation and request VM teardown.
    Cancel { sid: String },
}

pub fn run(args: ExecutionArgs) -> Result<()> {
    let client = args.connection.authenticated_client()?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        match args.command {
            ExecutionCommand::Submit { request, detach } => {
                let mut bytes = Vec::new();
                if request.as_os_str() == "-" {
                    std::io::stdin().read_to_end(&mut bytes)?;
                } else {
                    bytes = std::fs::read(&request)
                        .with_context(|| format!("read {}", request.display()))?;
                }
                let request: types::ExecutionRequest =
                    serde_json::from_slice(&bytes).context("parse execution request")?;
                let execution = client
                    .new_execution(&request)
                    .await
                    .context("submit execution")?
                    .into_inner();
                if detach {
                    println!("{}", execution.sid);
                    Ok(())
                } else {
                    eprintln!("{}", execution.sid);
                    observe(&client, &execution.sid, 0, true, true).await
                }
            }
            ExecutionCommand::Status { sid } => {
                let execution = client
                    .get_execution(&sid)
                    .await
                    .context("get execution")?
                    .into_inner();
                println!("{}", serde_json::to_string_pretty(&execution)?);
                Ok(())
            }
            ExecutionCommand::List => {
                let executions = client
                    .list_executions()
                    .await
                    .context("list executions")?
                    .into_inner();
                println!("{}", serde_json::to_string_pretty(&executions)?);
                Ok(())
            }
            ExecutionCommand::Logs { sid, follow, after } => {
                observe(&client, &sid, after, follow, follow).await
            }
            ExecutionCommand::Cancel { sid } => {
                let execution = client
                    .cancel_execution(&sid)
                    .await
                    .context("cancel execution")?
                    .into_inner();
                println!("{}", serde_json::to_string_pretty(&execution)?);
                Ok(())
            }
        }
    })
}

async fn observe(
    client: &Client,
    sid: &str,
    mut cursor: u64,
    follow: bool,
    exit_result: bool,
) -> Result<()> {
    let mut warned_truncation = false;
    loop {
        let history = client
            .get_execution_logs(sid, Some(cursor))
            .await
            .context("read execution logs")?
            .into_inner();
        for event in &history.events {
            if let Some(bytes) = &event.bytes {
                let bytes = decode_base64(bytes)?;
                match event.stream {
                    Some(types::ExecutionEventStream::Stdout) => {
                        std::io::stdout().write_all(&bytes)?;
                        std::io::stdout().flush()?;
                    }
                    Some(types::ExecutionEventStream::Stderr) => {
                        std::io::stderr().write_all(&bytes)?;
                        std::io::stderr().flush()?;
                    }
                    None => bail!("log event has no stream"),
                }
            }
        }
        let previous = cursor;
        cursor = history.cursor;
        let execution = history.execution;
        if execution.dropped_log_bytes > 0 && !warned_truncation {
            eprintln!("execution log retention limit reached; later stream bytes were discarded");
            warned_truncation = true;
        }
        let terminal = matches!(
            execution.state.as_str(),
            "succeeded" | "failed" | "cancelled"
        );
        if terminal && cursor >= execution.cursor {
            if exit_result {
                return terminal_result(&execution);
            }
            return Ok(());
        }
        if !follow && cursor == previous {
            return Ok(());
        }
        if cursor == previous {
            std::thread::sleep(Duration::from_millis(250));
        }
    }
}

fn terminal_result(execution: &types::ExecutionInfo) -> Result<()> {
    if execution.state == "succeeded" {
        return Ok(());
    }
    if let Some(result) = &execution.result {
        if result.cleanup != types::ExecutionResultCleanup::Complete {
            bail!(
                "execution cleanup is not certified: {}",
                serde_json::to_string(result)?
            );
        }
        if let Some(signal) = result.signal {
            eprintln!("guest terminated by signal {signal}");
            std::process::exit((128 + signal.get()).min(255) as i32);
        }
        if let Some(code) = result.code.filter(|code| *code != 0) {
            std::process::exit(i32::from(code));
        }
    }
    bail!(
        "execution {}: {}",
        execution.state,
        serde_json::to_string(&execution.result)?
    );
}

fn decode_base64(encoded: &str) -> Result<Vec<u8>> {
    if !encoded.len().is_multiple_of(4) {
        bail!("invalid base64 log length");
    }
    let mut output = Vec::with_capacity(encoded.len() / 4 * 3);
    for (index, chunk) in encoded.as_bytes().chunks_exact(4).enumerate() {
        let mut value = 0u32;
        let mut padding = 0;
        for &byte in chunk {
            value <<= 6;
            if byte == b'=' {
                padding += 1;
                continue;
            }
            if padding > 0 {
                bail!("invalid base64 padding");
            }
            value |= match byte {
                b'A'..=b'Z' => byte - b'A',
                b'a'..=b'z' => byte - b'a' + 26,
                b'0'..=b'9' => byte - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                _ => bail!("invalid base64 log byte"),
            } as u32;
        }
        if padding > 2 || (padding > 0 && (index + 1) * 4 != encoded.len()) {
            bail!("invalid base64 padding");
        }
        output.push((value >> 16) as u8);
        if padding < 2 {
            output.push((value >> 8) as u8);
        }
        if padding == 0 {
            output.push(value as u8);
        }
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::decode_base64;

    #[test]
    fn log_bytes_remain_binary_with_both_padding_lengths() {
        assert_eq!(decode_base64("AP+A").unwrap(), [0, 255, 128]);
        assert_eq!(decode_base64("AP8=").unwrap(), [0, 255]);
        assert_eq!(decode_base64("AA==").unwrap(), [0]);
        for invalid in ["A", "=AAA", "AA=A", "AA==AAAA", "====", "AA?A"] {
            assert!(decode_base64(invalid).is_err(), "{invalid}");
        }
    }
}
