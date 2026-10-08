use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::thread;

use serde_json::{Value, json};

const MAX_FRAME: usize = 65_536;
const CHUNK: usize = 8192;

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn frame(stream: &mut File, kind: u8, body: &[u8]) -> io::Result<()> {
    if body.len() > MAX_FRAME {
        return Err(invalid("frame exceeds 65536 bytes"));
    }
    stream.write_all(&[kind])?;
    stream.write_all(&(body.len() as u32).to_be_bytes())?;
    stream.write_all(body)
}

fn metadata(stream: &mut File, value: Value) -> io::Result<()> {
    frame(stream, 1, &serde_json::to_vec(&value)?)
}

fn pump(
    mut pipe: impl Read,
    kind: u8,
    output: &Mutex<&mut File>,
    child: &Mutex<Child>,
) -> io::Result<()> {
    let mut bytes = [0; CHUNK];
    let result = (|| {
        loop {
            match pipe.read(&mut bytes) {
                Ok(0) => return Ok(()),
                Ok(length) => {
                    let mut writer = output
                        .lock()
                        .map_err(|_| io::Error::other("output worker panicked"))?;
                    frame(&mut writer, kind, &bytes[..length])?;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
    })();
    if result.is_err() {
        let _ = child
            .lock()
            .map_err(|_| io::Error::other("child lock poisoned"))?
            .kill();
    }
    result
}

fn execute(stream: &mut File) -> io::Result<()> {
    let mut header = [0; 5];
    stream.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    if header[0] != 1 || length > MAX_FRAME {
        return Err(invalid("expected bounded execute metadata frame"));
    }
    let mut body = vec![0; length];
    stream.read_exact(&mut body)?;
    let request: Value = serde_json::from_slice(&body)?;
    if request["type"] != "execute" || request["version"] != 1 {
        return Err(invalid("expected execute request version 1"));
    }
    let path = request["path"]
        .as_str()
        .ok_or_else(|| invalid("path must be a string"))?;
    if !std::path::Path::new(path).is_absolute() {
        return Err(invalid("path must be absolute"));
    }
    let args = request["args"]
        .as_array()
        .ok_or_else(|| invalid("args must be an array"))?;
    let env = request["env"]
        .as_object()
        .ok_or_else(|| invalid("env must be an object"))?;
    let payload = request
        .get("stdin")
        .ok_or_else(|| invalid("stdin payload is required"))?;
    let mut command = Command::new(path);
    command.env_clear();
    for arg in args {
        command.arg(
            arg.as_str()
                .ok_or_else(|| invalid("args must contain strings"))?,
        );
    }
    for (key, value) in env {
        command.env(
            key,
            value
                .as_str()
                .ok_or_else(|| invalid("env values must be strings"))?,
        );
    }
    let input = serde_json::to_vec(payload)?;
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let child = Mutex::new(child);
    let output = Mutex::new(&mut *stream);
    let result = thread::scope(|scope| -> io::Result<()> {
        let input_worker = scope.spawn(move || stdin.write_all(&input));
        let stdout_worker = scope.spawn(|| pump(stdout, 2, &output, &child));
        let stderr_worker = scope.spawn(|| pump(stderr, 3, &output, &child));
        let stdout_result = stdout_worker
            .join()
            .map_err(|_| io::Error::other("stdout worker panicked"))?;
        let stderr_result = stderr_worker
            .join()
            .map_err(|_| io::Error::other("stderr worker panicked"))?;
        stdout_result?;
        stderr_result?;
        match input_worker
            .join()
            .map_err(|_| io::Error::other("stdin worker panicked"))?
        {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(()),
            Err(error) => Err(error),
        }
    });
    if let Err(error) = result {
        let mut child = child
            .lock()
            .map_err(|_| io::Error::other("child lock poisoned"))?;
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    let status = child
        .into_inner()
        .map_err(|_| io::Error::other("child lock poisoned"))?
        .wait()?;
    metadata(
        stream,
        json!({"type": "exited", "version": 1, "code": status.code(), "signal": status.signal()}),
    )
}

pub fn serve_connection(connection: OwnedFd) -> io::Result<()> {
    let mut stream = File::from(connection);
    metadata(&mut stream, json!({"type": "ready", "version": 1}))?;
    match execute(&mut stream) {
        Ok(()) => Ok(()),
        Err(error) => {
            let message: String = error.to_string().chars().take(4096).collect();
            let _ = metadata(
                &mut stream,
                json!({"type": "error", "version": 1, "message": message}),
            );
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixStream;
    use std::thread;

    use serde_json::{Value, json};

    fn executable(name: &str) -> String {
        let path = std::env::var_os("PATH").expect("test PATH must be supplied");
        let candidate = std::env::split_paths(&path)
            .map(|directory| directory.join(name))
            .find(|candidate| {
                candidate.metadata().is_ok_and(|metadata| {
                    metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
                })
            })
            .unwrap_or_else(|| {
                panic!("required test executable {name} not found in PATH: {path:?}")
            });
        std::path::absolute(candidate)
            .unwrap()
            .into_os_string()
            .into_string()
            .unwrap()
    }

    fn read_frame(stream: &mut UnixStream) -> (u8, Vec<u8>) {
        let mut header = [0; 5];
        stream.read_exact(&mut header).unwrap();
        let length = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
        assert!(length <= 65_536, "unbounded protocol frame: {length}");
        let mut body = vec![0; length];
        stream.read_exact(&mut body).unwrap();
        (header[0], body)
    }

    fn connect(request: Value) -> (UnixStream, thread::JoinHandle<std::io::Result<()>>) {
        let (mut client, guest) = UnixStream::pair().unwrap();
        client
            .set_read_timeout(Some(std::time::Duration::from_secs(20)))
            .unwrap();
        client
            .set_write_timeout(Some(std::time::Duration::from_secs(20)))
            .unwrap();
        let worker = thread::spawn(move || super::serve_connection(guest.into()));
        let (kind, body) = read_frame(&mut client);
        assert_eq!(kind, 1);
        assert_eq!(
            serde_json::from_slice::<Value>(&body).unwrap(),
            json!({"type": "ready", "version": 1})
        );
        let body = serde_json::to_vec(&request).unwrap();
        client.write_all(&[1]).unwrap();
        client
            .write_all(&(body.len() as u32).to_be_bytes())
            .unwrap();
        client.write_all(&body).unwrap();
        (client, worker)
    }

    fn request(path: &str, args: &[&str], env: Value, stdin: Value) -> Value {
        json!({"type": "execute", "version": 1, "path": path, "args": args, "env": env, "stdin": stdin})
    }

    fn collect(request: Value) -> (Vec<u8>, Vec<u8>, Value) {
        let (mut client, worker) = connect(request);
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let exited = loop {
            let (kind, body) = read_frame(&mut client);
            match kind {
                2 => stdout.extend(body),
                3 => stderr.extend(body),
                1 => break serde_json::from_slice::<Value>(&body).unwrap(),
                _ => panic!("unexpected frame kind {kind}"),
            }
        };
        assert_eq!(
            exited["type"], "exited",
            "unexpected terminal metadata: {exited}"
        );
        assert_eq!(exited["version"], 1);
        worker.join().unwrap().unwrap();
        (stdout, stderr, exited)
    }

    #[test]
    fn passes_exact_arguments_without_shell_interpolation() {
        let (stdout, stderr, exited) = collect(request(
            &executable("sh"),
            &[
                "-c",
                "printf '%s\\000' \"$0\" \"$@\"",
                "argv-zero",
                "",
                "space separated",
                "$(exit 99)",
                "*",
                "quote'\"",
            ],
            json!({}),
            Value::Null,
        ));
        assert_eq!(
            stdout,
            b"argv-zero\0\0space separated\0$(exit 99)\0*\0quote'\"\0"
        );
        assert!(stderr.is_empty());
        assert_eq!(
            exited,
            json!({"type": "exited", "version": 1, "code": 0, "signal": null})
        );
    }

    #[test]
    fn supplies_only_requested_environment() {
        let (stdout, stderr, exited) = collect(request(
            &executable("env"),
            &[],
            json!({"SOWER_EXACT": "value with spaces=and equals"}),
            Value::Null,
        ));
        assert_eq!(stdout, b"SOWER_EXACT=value with spaces=and equals\n");
        assert!(stderr.is_empty());
        assert_eq!(exited["code"], 0);
    }

    #[test]
    fn delivers_json_payload_and_closes_stdin() {
        let payload = json!({"text": "line\nλ", "nested": [false, null, 42]});
        let (stdout, stderr, exited) =
            collect(request(&executable("cat"), &[], json!({}), payload.clone()));
        assert_eq!(serde_json::from_slice::<Value>(&stdout).unwrap(), payload);
        assert!(stderr.is_empty());
        assert_eq!(exited["code"], 0);
    }

    #[test]
    fn preserves_binary_streams_and_nonzero_exit() {
        let (stdout, stderr, exited) = collect(request(
            &executable("sh"),
            &[
                "-c",
                "printf '\\000\\377\\200stdout'; printf '\\376\\000stderr' >&2; exit 37",
            ],
            json!({}),
            Value::Null,
        ));
        assert_eq!(stdout, b"\x00\xff\x80stdout");
        assert_eq!(stderr, b"\xfe\x00stderr");
        assert_eq!(
            exited,
            json!({"type": "exited", "version": 1, "code": 37, "signal": null})
        );
    }

    #[test]
    fn reports_signal_termination() {
        let (_, _, exited) = collect(request(
            &executable("sh"),
            &["-c", "kill -TERM $$"],
            json!({}),
            Value::Null,
        ));
        assert_eq!(
            exited,
            json!({"type": "exited", "version": 1, "code": null, "signal": 15})
        );
    }

    #[test]
    fn streams_sustained_output_on_both_pipes_with_bounded_frames() {
        let (mut client, worker) = connect(request(
            &executable("sh"),
            &[
                "-c",
                "\"$1\" if=/dev/zero bs=65536 count=64 status=none & \"$1\" if=/dev/zero bs=65536 count=64 status=none >&2 & wait",
                "sustained-output",
                &executable("dd"),
            ],
            json!({}),
            Value::Null,
        ));
        let mut counts = [0usize; 2];
        loop {
            let (kind, body) = read_frame(&mut client);
            match kind {
                2 | 3 => {
                    assert!(body.iter().all(|byte| *byte == 0));
                    counts[(kind - 2) as usize] += body.len();
                }
                1 => {
                    assert_eq!(
                        serde_json::from_slice::<Value>(&body).unwrap(),
                        json!({"type": "exited", "version": 1, "code": 0, "signal": null})
                    );
                    break;
                }
                _ => panic!("unexpected frame kind {kind}"),
            }
        }
        assert_eq!(counts, [4_194_304, 4_194_304]);
        worker.join().unwrap().unwrap();
    }
}
