use std::io::{Read, Write};
use std::process::{Command, Stdio};

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

fn binary_path() -> &'static str {
    env!("CARGO_BIN_EXE_rexec_native")
}

fn spawn_rexec(args: &[&str]) -> std::process::Child {
    Command::new(binary_path())
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn rexec_native")
}

fn read_packet(reader: &mut impl Read) -> std::io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    Ok(buf)
}

fn write_command_packet(writer: &mut impl Write, tag: u8, data: &[u8]) {
    let len = (1 + data.len()) as u32;
    writer.write_all(&len.to_be_bytes()).unwrap();
    writer.write_all(&[tag]).unwrap();
    writer.write_all(data).unwrap();
    writer.flush().unwrap();
}

#[test]
fn echo_stdout() {
    let mut child = spawn_rexec(&["echo", "hello world"]);
    let mut stdout = child.stdout.take().unwrap();

    // First packet: PID
    let pkt = read_packet(&mut stdout).unwrap();
    assert_eq!(pkt[0], TAG_PID);
    let pid = u32::from_be_bytes(pkt[1..5].try_into().unwrap());
    assert!(pid > 0);

    // Collect remaining packets
    let mut got_stdout = false;
    let mut got_exit = false;
    loop {
        match read_packet(&mut stdout) {
            Ok(pkt) if pkt[0] == TAG_STDOUT => {
                let data = String::from_utf8_lossy(&pkt[1..]);
                assert!(data.contains("hello world"));
                got_stdout = true;
            }
            Ok(pkt) if pkt[0] == TAG_EXIT => {
                let code = i32::from_be_bytes(pkt[1..5].try_into().unwrap());
                assert_eq!(code, 0);
                got_exit = true;
                break;
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }

    assert!(got_stdout, "expected stdout packet");
    assert!(got_exit, "expected exit packet");
    child.wait().unwrap();
}

#[test]
fn stderr_capture() {
    let mut child = spawn_rexec(&["sh", "-c", "echo oops >&2"]);
    let mut stdout = child.stdout.take().unwrap();

    // Skip PID packet
    let _ = read_packet(&mut stdout).unwrap();

    let mut got_stderr = false;
    loop {
        match read_packet(&mut stdout) {
            Ok(pkt) if pkt[0] == TAG_STDERR => {
                let data = String::from_utf8_lossy(&pkt[1..]);
                assert!(data.contains("oops"));
                got_stderr = true;
            }
            Ok(pkt) if pkt[0] == TAG_EXIT || pkt[0] == TAG_SIGNAL => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    assert!(got_stderr, "expected stderr packet");
    child.wait().unwrap();
}

#[test]
fn nonzero_exit() {
    let mut child = spawn_rexec(&["sh", "-c", "exit 42"]);
    let mut stdout = child.stdout.take().unwrap();

    // Skip PID
    let _ = read_packet(&mut stdout).unwrap();

    loop {
        match read_packet(&mut stdout) {
            Ok(pkt) if pkt[0] == TAG_EXIT => {
                let code = i32::from_be_bytes(pkt[1..5].try_into().unwrap());
                assert_eq!(code, 42);
                break;
            }
            Ok(_) => {}
            Err(_) => panic!("EOF before exit packet"),
        }
    }

    child.wait().unwrap();
}

#[test]
fn stdin_pipe() {
    let mut child = spawn_rexec(&["cat"]);
    let mut stdout = child.stdout.take().unwrap();
    let mut stdin = child.stdin.take().unwrap();

    // Skip PID
    let _ = read_packet(&mut stdout).unwrap();

    // Send data via stdin command
    write_command_packet(&mut stdin, CMD_STDIN, b"piped input");
    // Send EOF to close stdin
    write_command_packet(&mut stdin, CMD_EOF, &[]);

    let mut collected = String::new();
    loop {
        match read_packet(&mut stdout) {
            Ok(pkt) if pkt[0] == TAG_STDOUT => {
                collected.push_str(&String::from_utf8_lossy(&pkt[1..]));
            }
            Ok(pkt) if pkt[0] == TAG_EXIT => {
                let code = i32::from_be_bytes(pkt[1..5].try_into().unwrap());
                assert_eq!(code, 0);
                break;
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }

    assert_eq!(collected, "piped input");
    child.wait().unwrap();
}

#[test]
fn kill_signal() {
    let mut child = spawn_rexec(&["sleep", "60"]);
    let mut stdout = child.stdout.take().unwrap();
    let mut stdin = child.stdin.take().unwrap();

    // Read PID packet
    let pkt = read_packet(&mut stdout).unwrap();
    assert_eq!(pkt[0], TAG_PID);

    // Send SIGTERM (15)
    write_command_packet(&mut stdin, CMD_KILL, &[15]);

    // Should get a signal exit
    loop {
        match read_packet(&mut stdout) {
            Ok(pkt) if pkt[0] == TAG_SIGNAL => {
                assert_eq!(pkt[1], 15); // SIGTERM
                break;
            }
            Ok(pkt) if pkt[0] == TAG_EXIT => {
                // Some systems report as exit instead of signal
                break;
            }
            Ok(_) => {}
            Err(_) => panic!("EOF before signal/exit packet"),
        }
    }

    child.wait().unwrap();
}
