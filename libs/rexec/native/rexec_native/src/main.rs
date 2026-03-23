use std::env;
use std::io::{self, Read, Write};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

// Protocol tags: Rust -> Elixir
const TAG_PID: u8 = 0x00;
const TAG_STDOUT: u8 = 0x01;
const TAG_STDERR: u8 = 0x02;
const TAG_EXIT: u8 = 0x03;
const TAG_SIGNAL: u8 = 0x04;

// Protocol tags: Elixir -> Rust
const CMD_STDIN: u8 = 0x01;
const CMD_EOF: u8 = 0x02;
const CMD_KILL: u8 = 0x03;

fn send_packet(writer: &Mutex<impl Write>, tag: u8, data: &[u8]) {
    let mut w = writer.lock().unwrap();
    let len = (1 + data.len()) as u32;
    let _ = w.write_all(&len.to_be_bytes());
    let _ = w.write_all(&[tag]);
    let _ = w.write_all(data);
    let _ = w.flush();
}

fn read_packet(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    Ok(buf)
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: rexec_native <command> [args...]");
        std::process::exit(1);
    }

    let mut child = Command::new(&args[0])
        .args(&args[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|e| {
            eprintln!("failed to spawn: {e}");
            std::process::exit(1);
        });

    let child_pid = child.id();
    let stdout_writer = Arc::new(Mutex::new(io::stdout()));

    // Send child PID
    send_packet(&stdout_writer, TAG_PID, &child_pid.to_be_bytes());

    // Take ownership of child I/O handles
    let child_stdout = child.stdout.take().unwrap();
    let child_stderr = child.stderr.take().unwrap();
    let child_stdin = child.stdin.take().unwrap();
    let child_stdin = Arc::new(Mutex::new(Some(child_stdin)));

    // Stdout reader thread
    let w = Arc::clone(&stdout_writer);
    let stdout_thread = thread::spawn(move || {
        let mut reader = io::BufReader::new(child_stdout);
        let mut buf = [0u8; 65536];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => send_packet(&w, TAG_STDOUT, &buf[..n]),
                Err(_) => break,
            }
        }
    });

    // Stderr reader thread
    let w = Arc::clone(&stdout_writer);
    let stderr_thread = thread::spawn(move || {
        let mut reader = io::BufReader::new(child_stderr);
        let mut buf = [0u8; 65536];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => send_packet(&w, TAG_STDERR, &buf[..n]),
                Err(_) => break,
            }
        }
    });

    // Stdin command reader thread
    let stdin_handle = Arc::clone(&child_stdin);
    let stdin_thread = thread::spawn(move || {
        let mut reader = io::stdin();
        loop {
            match read_packet(&mut reader) {
                Ok(packet) if packet.is_empty() => break,
                Ok(packet) => {
                    let tag = packet[0];
                    let data = &packet[1..];
                    match tag {
                        CMD_STDIN => {
                            if let Some(ref mut stdin) = *stdin_handle.lock().unwrap() {
                                let _ = stdin.write_all(data);
                                let _ = stdin.flush();
                            }
                        }
                        CMD_EOF => {
                            // Drop stdin to close it
                            *stdin_handle.lock().unwrap() = None;
                        }
                        CMD_KILL => {
                            if !data.is_empty() {
                                let signal = data[0] as i32;
                                unsafe {
                                    libc::kill(child_pid as i32, signal);
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Err(_) => break,
            }
        }
    });

    // Wait for child to exit
    let status = child.wait().unwrap();

    // Wait for I/O threads to finish
    let _ = stdout_thread.join();
    let _ = stderr_thread.join();

    // Send exit status
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            send_packet(&stdout_writer, TAG_SIGNAL, &[signal as u8]);
        } else {
            let code = status.code().unwrap_or(1) as i32;
            send_packet(&stdout_writer, TAG_EXIT, &code.to_be_bytes());
        }
    }

    #[cfg(not(unix))]
    {
        let code = status.code().unwrap_or(1) as i32;
        send_packet(&stdout_writer, TAG_EXIT, &code.to_be_bytes());
    }

    // Don't wait for stdin thread — it'll die when we exit
    drop(stdin_thread);
}
