use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const MAX_FRAME: usize = 65_536;
const CHUNK: usize = 8192;
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(3);
const POLLIN: i16 = 1;
const POLLOUT: i16 = 4;
const WNOHANG: i32 = 1;
const WALL: i32 = 0x4000_0000;
const ECHILD: i32 = 10;
const ESRCH: i32 = 3;
const SIGKILL: i32 = 9;

// The guest owns all of its children. Serializing the entire connection also
// keeps subreaper adoption and waitpid(-1) scoped to exactly one command.
static CONNECTION: Mutex<()> = Mutex::new(());
static FAILED: AtomicBool = AtomicBool::new(false);

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

unsafe extern "C" {
    fn prctl(option: i32, ...) -> i32;
    fn fcntl(fd: i32, command: i32, ...) -> i32;
    fn poll(fds: *mut PollFd, count: usize, timeout: i32) -> i32;
    fn kill(pid: i32, signal: i32) -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
}

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

fn nonblocking(fd: &impl AsRawFd) -> io::Result<()> {
    // Linux F_GETFL, F_SETFL and O_NONBLOCK. rustix's fs feature is not enabled
    // for the standalone guest package.
    let flags = unsafe { fcntl(fd.as_raw_fd(), 3) };
    if flags == -1 || unsafe { fcntl(fd.as_raw_fd(), 4, flags | 0x800) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn request(stream: &mut File, version: &mut u64) -> io::Result<(Command, Vec<u8>)> {
    let mut header = [0; 5];
    stream.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    if header[0] != 1 || length > MAX_FRAME {
        return Err(invalid("expected bounded execute metadata frame"));
    }
    let mut body = vec![0; length];
    stream.read_exact(&mut body)?;
    let request: Value = serde_json::from_slice(&body)?;
    if request["version"] == 1 {
        *version = 1;
    }
    if request["type"] != "execute" || (request["version"] != 1 && request["version"] != 2) {
        return Err(invalid("expected execute request version 1 or 2"));
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
    command
        .process_group(0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    Ok((command, serde_json::to_vec(payload)?))
}

fn wait_child(pid: i32) -> io::Result<Option<(i32, ExitStatus)>> {
    loop {
        let mut status = 0;
        // __WALL also reaps descendants created with non-SIGCHLD clone flags.
        match unsafe { waitpid(pid, &mut status, WNOHANG | WALL) } {
            -1 => {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
            0 => return Ok(None),
            child => return Ok(Some((child, ExitStatus::from_raw(status)))),
        }
    }
}

fn kill_child(pid: i32) -> io::Result<()> {
    if unsafe { kill(pid, SIGKILL) } != 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(ESRCH) {
            return Err(error);
        }
    }
    Ok(())
}

struct CommandTree {
    root: i32,
    status: Option<ExitStatus>,
    clean: bool,
}

impl CommandTree {
    fn root_exited(&mut self) -> io::Result<bool> {
        if self.status.is_none() {
            self.status = wait_child(self.root)?.map(|(_, status)| status);
        }
        Ok(self.status.is_some())
    }

    fn cleanup(&mut self) -> io::Result<()> {
        let result = self.cleanup_inner();
        if result.is_err() {
            FAILED.store(true, Ordering::Relaxed);
        }
        result
    }

    fn cleanup_inner(&mut self) -> io::Result<()> {
        if self.clean {
            return Ok(());
        }
        let deadline = Instant::now() + CLEANUP_TIMEOUT;
        // Kill the initial group promptly, but do not rely on group membership:
        // setsid/double-fork descendants are adopted by this subreaper.
        if self.status.is_none() {
            kill_child(-self.root)?;
        }
        loop {
            // A child can have been created by any runtime thread. /proc's
            // per-thread children lists include both live children and zombies.
            // Do not reap between enumerating and killing: an unreaped child PID
            // cannot be recycled and accidentally name an unrelated process.
            for task in fs::read_dir("/proc/self/task")? {
                let children = match fs::read_to_string(task?.path().join("children")) {
                    Ok(children) => children,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                    Err(error) => return Err(error),
                };
                for pid in children.split_whitespace() {
                    kill_child(pid.parse().map_err(|_| invalid("invalid child PID"))?)?;
                }
            }
            loop {
                if Instant::now() >= deadline {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "command descendants could not be killed and reaped",
                    ));
                }
                match wait_child(-1) {
                    Ok(Some((pid, status))) => {
                        if pid == self.root {
                            self.status = Some(status);
                        }
                    }
                    Ok(None) => break,
                    Err(error) if error.raw_os_error() == Some(ECHILD) => {
                        if self.status.is_none() {
                            return Err(io::Error::other("command exit status was lost"));
                        }
                        // ECHILD, not an empty /proc snapshot, certifies that
                        // all descendants have been adopted, killed and reaped.
                        self.clean = true;
                        return Ok(());
                    }
                    Err(error) => return Err(error),
                }
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "command descendants could not be killed and reaped",
                ));
            }
            thread::sleep(Duration::from_millis(5));
        }
    }
}

#[derive(Default)]
struct Control {
    header: [u8; 5],
    header_length: usize,
    body: Vec<u8>,
    body_length: usize,
}

enum ControlEvent {
    Pending,
    Cancel,
    Disconnected,
}

impl Control {
    fn read(&mut self, stream: &mut File, version: u64) -> io::Result<ControlEvent> {
        loop {
            let bytes = if self.header_length < 5 {
                &mut self.header[self.header_length..]
            } else {
                &mut self.body[self.body_length..]
            };
            match stream.read(bytes) {
                Ok(0) => return Ok(ControlEvent::Disconnected),
                Ok(length) if self.header_length < 5 => {
                    self.header_length += length;
                    if self.header_length == 5 {
                        let length =
                            u32::from_be_bytes(self.header[1..].try_into().unwrap()) as usize;
                        if self.header[0] != 1 || length == 0 || length > MAX_FRAME {
                            return Err(invalid("expected bounded cancel metadata frame"));
                        }
                        self.body.resize(length, 0);
                    }
                }
                Ok(length) => {
                    self.body_length += length;
                    if self.body_length == self.body.len() {
                        let cancel: Value = serde_json::from_slice(&self.body)?;
                        if version != 2 || cancel["type"] != "cancel" || cancel["version"] != 2 {
                            return Err(invalid("expected cancel request version 2"));
                        }
                        self.header_length = 0;
                        self.body_length = 0;
                        return Ok(ControlEvent::Cancel);
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    return Ok(ControlEvent::Pending);
                }
                Err(error) => return Err(error),
            }
        }
    }
}

struct Output {
    bytes: [u8; CHUNK + 5],
    length: usize,
    sent: usize,
}

impl Output {
    fn new() -> Self {
        Self {
            bytes: [0; CHUNK + 5],
            length: 0,
            sent: 0,
        }
    }

    fn is_empty(&self) -> bool {
        self.length == 0
    }

    fn header(&mut self, kind: u8, length: usize) {
        self.length = length + 5;
        self.bytes[0] = kind;
        self.bytes[1..5].copy_from_slice(&(length as u32).to_be_bytes());
    }

    fn pipe(&mut self, pipe: &mut Option<impl Read>, kind: u8) -> io::Result<()> {
        if !self.is_empty() {
            return Ok(());
        }
        if let Some(reader) = pipe {
            match reader.read(&mut self.bytes[5..]) {
                Ok(0) => {
                    *pipe = None;
                }
                Ok(length) => self.header(kind, length),
                Err(error)
                    if error.kind() == io::ErrorKind::WouldBlock
                        || error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }

    fn flush(&mut self, stream: &mut File) -> io::Result<()> {
        while self.sent < self.length {
            match stream.write(&self.bytes[self.sent..self.length]) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(length) => self.sent += length,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(error) => return Err(error),
            }
        }
        self.sent = 0;
        self.length = 0;
        Ok(())
    }

    fn exited(&mut self, version: u64, status: ExitStatus) -> io::Result<()> {
        let mut body = &mut self.bytes[5..];
        serde_json::to_writer(
            &mut body,
            &json!({"type": "exited", "version": version, "code": status.code(), "signal": status.signal()}),
        )?;
        let length = CHUNK - body.len();
        self.header(1, length);
        Ok(())
    }
}

fn run(
    stream: &mut File,
    child: &mut Child,
    input: &[u8],
    version: u64,
    tree: &mut CommandTree,
) -> io::Result<()> {
    let mut stdin = child.stdin.take();
    let mut stdout = child.stdout.take();
    let mut stderr = child.stderr.take();
    nonblocking(stream)?;
    nonblocking(stdin.as_ref().unwrap())?;
    nonblocking(stdout.as_ref().unwrap())?;
    nonblocking(stderr.as_ref().unwrap())?;
    let mut input_sent = 0;
    let mut control = Control::default();
    let mut output = Output::new();
    let mut stderr_first = false;
    let mut terminal = false;
    loop {
        // No writer thread or mutex can block control delivery. The socket and
        // every pipe are nonblocking; at most one output frame is buffered.
        match control.read(stream, version)? {
            ControlEvent::Disconnected => return Ok(()),
            ControlEvent::Cancel => {
                stdin = None;
                tree.cleanup()?;
            }
            ControlEvent::Pending => {}
        }
        if !tree.clean && tree.root_exited()? {
            stdin = None;
            tree.cleanup()?;
        }
        output.flush(stream)?;
        if terminal && output.is_empty() {
            return Ok(());
        }
        if let Some(writer) = &mut stdin {
            match writer.write(&input[input_sent..]) {
                Ok(length) => {
                    input_sent += length;
                    if input_sent == input.len() {
                        stdin = None;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::BrokenPipe => stdin = None,
                Err(error)
                    if error.kind() == io::ErrorKind::WouldBlock
                        || error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error),
            }
        }
        if !terminal && output.is_empty() {
            if stderr_first {
                output.pipe(&mut stderr, 3)?;
                output.pipe(&mut stdout, 2)?;
            } else {
                output.pipe(&mut stdout, 2)?;
                output.pipe(&mut stderr, 3)?;
            }
            stderr_first = !stderr_first;
            if tree.clean && stdout.is_none() && stderr.is_none() && output.is_empty() {
                output.exited(version, tree.status.unwrap())?;
                terminal = true;
            }
        }
        let mut descriptors = [
            PollFd {
                fd: stream.as_raw_fd(),
                events: POLLIN | if output.is_empty() { 0 } else { POLLOUT },
                revents: 0,
            },
            PollFd {
                fd: stdin.as_ref().map_or(-1, AsRawFd::as_raw_fd),
                events: POLLOUT,
                revents: 0,
            },
            PollFd {
                fd: if output.is_empty() {
                    stdout.as_ref().map_or(-1, AsRawFd::as_raw_fd)
                } else {
                    -1
                },
                events: POLLIN,
                revents: 0,
            },
            PollFd {
                fd: if output.is_empty() {
                    stderr.as_ref().map_or(-1, AsRawFd::as_raw_fd)
                } else {
                    -1
                },
                events: POLLIN,
                revents: 0,
            },
        ];
        if unsafe { poll(descriptors.as_mut_ptr(), descriptors.len(), 20) } == -1 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

/// Serve one readiness/execute connection. Ok means all command descendants
/// are gone, including on request, spawn or transport errors. Err means cleanup
/// is uncertain: the caller must stop the runtime, never accept another command.
pub fn serve_connection(connection: OwnedFd) -> io::Result<()> {
    let _connection = CONNECTION
        .lock()
        .map_err(|_| io::Error::other("guest runtime lock poisoned"))?;
    if FAILED.load(Ordering::Relaxed) {
        return Err(io::Error::other("guest runtime cleanup previously failed"));
    }
    // PR_SET_CHILD_SUBREAPER makes orphaned command descendants our children,
    // even when they escaped the original process group/session.
    if unsafe { prctl(36, 1usize, 0usize, 0usize, 0usize) } != 0 {
        FAILED.store(true, Ordering::Relaxed);
        return Err(io::Error::last_os_error());
    }
    let mut stream = File::from(connection);
    if metadata(
        &mut stream,
        json!({"type": "ready", "version": 1, "contract": 2}),
    )
    .is_err()
    {
        return Ok(());
    }
    let mut version = 2;
    let result = (|| {
        let (mut command, input) = request(&mut stream, &mut version)?;
        let mut child = command.spawn()?;
        let mut tree = CommandTree {
            root: child.id() as i32,
            status: None,
            clean: false,
        };
        let result = run(&mut stream, &mut child, &input, version, &mut tree);
        if FAILED.load(Ordering::Relaxed) {
            return result;
        }
        // This path also covers setup/pipe/socket failures and disconnects.
        // A failed stream may contain a partial output frame: close it rather
        // than inserting error metadata into the middle of that frame.
        tree.cleanup()?;
        Ok(())
    })();
    if FAILED.load(Ordering::Relaxed) {
        return result;
    }
    if let Err(error) = result {
        let message: String = error.to_string().chars().take(4096).collect();
        let _ = metadata(
            &mut stream,
            json!({"type": "error", "version": version, "message": message}),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs::{self, File};
    use std::io::{Read, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixStream;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc::{self, Sender};
    use std::thread;
    use std::time::{Duration, Instant};

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

    fn ready(client: &mut UnixStream) {
        client
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        client
            .set_write_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let (kind, body) = read_frame(client);
        assert_eq!(kind, 1);
        assert_eq!(
            serde_json::from_slice::<Value>(&body).unwrap(),
            json!({"type": "ready", "version": 1, "contract": 2})
        );
    }

    fn send(client: &mut UnixStream, request: Value) {
        let body = serde_json::to_vec(&request).unwrap();
        client.write_all(&[1]).unwrap();
        client
            .write_all(&(body.len() as u32).to_be_bytes())
            .unwrap();
        client.write_all(&body).unwrap();
    }

    fn connect(request: Value) -> (UnixStream, thread::JoinHandle<std::io::Result<()>>) {
        let (mut client, guest) = UnixStream::pair().unwrap();
        let worker = thread::spawn(move || super::serve_connection(guest.into()));
        ready(&mut client);
        send(&mut client, request);
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

    struct Runtime {
        connections: Sender<UnixStream>,
        worker: thread::JoinHandle<std::io::Result<()>>,
    }

    impl Runtime {
        fn new() -> Self {
            let (connections, incoming) = mpsc::channel::<UnixStream>();
            let worker = thread::spawn(move || {
                for guest in incoming {
                    super::serve_connection(guest.into())?;
                }
                Ok(())
            });
            Self {
                connections,
                worker,
            }
        }

        fn connect(&self) -> UnixStream {
            let (mut client, guest) = UnixStream::pair().unwrap();
            self.connections.send(guest).unwrap();
            ready(&mut client);
            client
        }

        fn execute(&self, mut request: Value) -> (Vec<u8>, Vec<u8>, Value) {
            let mut client = self.connect();
            request["version"] = json!(2);
            send(&mut client, request);
            let mut stdout = Vec::new();
            let mut stderr = Vec::new();
            loop {
                let (kind, body) = read_frame(&mut client);
                match kind {
                    2 => stdout.extend(body),
                    3 => stderr.extend(body),
                    1 => return (stdout, stderr, serde_json::from_slice(&body).unwrap()),
                    _ => panic!("unexpected frame kind {kind}"),
                }
            }
        }

        fn finish(self) {
            drop(self.connections);
            self.worker.join().unwrap().unwrap();
        }
    }

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            Self(std::env::temp_dir().join(format!(
                "sower-guest-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            )))
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    #[test]
    fn readiness_and_repeated_commands_preserve_scratch_and_independent_outcomes() {
        let runtime = Runtime::new();
        let scratch = Scratch::new();
        // A readiness probe must neither start a command nor consume the runtime.
        drop(runtime.connect());
        let (stdout, stderr, exited) = runtime.execute(request(
            &executable("sh"),
            &[
                "-c",
                "printf '%s' \"$1\" > \"$2\"; printf '\\377\\000first'; exit 17",
                "scratch",
                "persistent value",
                scratch.0.to_str().unwrap(),
            ],
            json!({}),
            Value::Null,
        ));
        assert_eq!(stdout, b"\xff\0first");
        assert!(stderr.is_empty());
        assert_eq!(
            exited,
            json!({"type": "exited", "version": 2, "code": 17, "signal": null})
        );
        let (stdout, stderr, exited) = runtime.execute(request(
            &executable("cat"),
            &[scratch.0.to_str().unwrap()],
            json!({}),
            Value::Null,
        ));
        assert_eq!(stdout, b"persistent value");
        assert!(stderr.is_empty());
        assert_eq!(
            exited,
            json!({"type": "exited", "version": 2, "code": 0, "signal": null})
        );
        runtime.finish();
    }

    #[test]
    fn malformed_and_spawn_errors_leave_runtime_usable() {
        let runtime = Runtime::new();
        let missing = Scratch::new();
        for path in ["relative/path", missing.0.to_str().unwrap()] {
            let (_, _, error) = runtime.execute(request(path, &[], json!({}), Value::Null));
            assert_eq!(error["type"], "error");
            assert_eq!(error["version"], 2);
        }
        let (stdout, stderr, exited) = runtime.execute(request(
            &executable("sh"),
            &["-c", "printf recovered"],
            json!({}),
            Value::Null,
        ));
        assert_eq!(stdout, b"recovered");
        assert!(stderr.is_empty());
        assert_eq!(exited["code"], 0);
        runtime.finish();
    }

    unsafe extern "C" {
        fn fork() -> i32;
        fn setsid() -> i32;
        fn getpid() -> i32;
        fn write(fd: i32, bytes: *const u8, length: usize) -> isize;
        fn pause() -> i32;
        fn _exit(code: i32) -> !;
    }

    // Invoked as a separate command via the test executable. After fork the
    // children use only async-signal-safe Linux calls and stack-local bytes.
    #[test]
    #[ignore = "subprocess fixture for command-tree cancellation tests"]
    fn orphan_tree_fixture() {
        let path = std::env::var_os("SOWER_TREE_FIXTURE").expect("fixture path");
        let mut pids = File::create(path).unwrap();
        writeln!(pids, "{}", std::process::id()).unwrap();
        let intermediate = unsafe { fork() };
        assert!(intermediate >= 0);
        if intermediate == 0 {
            unsafe {
                if setsid() == -1 {
                    _exit(91);
                }
                let descendant = fork();
                if descendant == -1 {
                    _exit(92);
                }
                if descendant != 0 {
                    _exit(0);
                }
                let mut pid = getpid() as u32;
                let mut digits = [0u8; 12];
                let mut start = digits.len() - 1;
                digits[start] = b'\n';
                loop {
                    start -= 1;
                    digits[start] = b'0' + (pid % 10) as u8;
                    pid /= 10;
                    if pid == 0 {
                        break;
                    }
                }
                if write(
                    pids.as_raw_fd(),
                    digits[start..].as_ptr(),
                    digits.len() - start,
                ) != (digits.len() - start) as isize
                {
                    _exit(93);
                }
                let bytes = [0u8; super::CHUNK];
                loop {
                    if write(1, bytes.as_ptr(), bytes.len()) <= 0 {
                        _exit(94);
                    }
                }
            }
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if super::wait_child(intermediate).unwrap().is_some() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "fixture intermediate did not exit"
            );
            thread::sleep(Duration::from_millis(5));
        }
        // Do not read stdin: cancellation must also interrupt a blocked input
        // writer, not just the orphan's saturated stdout.
        loop {
            unsafe { pause() };
        }
    }

    fn start_tree(runtime: &Runtime, scratch: &Scratch) -> (UnixStream, Vec<i32>) {
        let mut client = runtime.connect();
        let mut command = request(
            std::env::current_exe().unwrap().to_str().unwrap(),
            &[
                "--exact",
                "tests::orphan_tree_fixture",
                "--ignored",
                "--nocapture",
            ],
            json!({"SOWER_TREE_FIXTURE": scratch.0.to_str().unwrap()}),
            json!("x".repeat(60_000)),
        );
        command["version"] = json!(2);
        send(&mut client, command);
        let deadline = Instant::now() + Duration::from_secs(5);
        let pids = loop {
            let contents = fs::read_to_string(&scratch.0).unwrap_or_default();
            let pids: Vec<i32> = contents
                .lines()
                .filter_map(|line| line.parse().ok())
                .collect();
            if pids.len() == 2 {
                break pids;
            }
            assert!(
                Instant::now() < deadline,
                "fixture did not start: {contents}"
            );
            thread::sleep(Duration::from_millis(5));
        };
        // Do not drain output. Allow the orphan to fill both the pipe and the
        // connection so cancellation is exercised under real backpressure.
        thread::sleep(Duration::from_millis(200));
        for pid in &pids {
            assert!(PathBuf::from(format!("/proc/{pid}")).exists());
        }
        (client, pids)
    }

    fn assert_reaped(pids: &[i32]) {
        let deadline = Instant::now() + Duration::from_secs(8);
        while pids
            .iter()
            .any(|pid| PathBuf::from(format!("/proc/{pid}")).exists())
        {
            assert!(
                Instant::now() < deadline,
                "command processes survived: {pids:?}"
            );
            thread::sleep(Duration::from_millis(5));
        }
    }

    fn assert_next_command(runtime: &Runtime) {
        let (stdout, stderr, exited) = runtime.execute(request(
            &executable("sh"),
            &[
                "-c",
                "printf 'after-cleanup'; printf '\\376\\000' >&2; exit 23",
            ],
            json!({}),
            Value::Null,
        ));
        assert_eq!(stdout, b"after-cleanup");
        assert_eq!(stderr, b"\xfe\0");
        assert_eq!(
            exited,
            json!({"type": "exited", "version": 2, "code": 23, "signal": null})
        );
    }

    #[test]
    fn cancel_reaps_session_escaped_orphan_while_output_and_input_are_blocked() {
        let runtime = Runtime::new();
        let scratch = Scratch::new();
        let (mut client, pids) = start_tree(&runtime, &scratch);
        send(&mut client, json!({"type": "cancel", "version": 2}));
        // The host is still not reading: death/reaping must precede its draining
        // the queued frames or receiving cancellation acknowledgement.
        assert_reaped(&pids);
        let exited = loop {
            let (kind, body) = read_frame(&mut client);
            match kind {
                2 | 3 => {}
                1 => break serde_json::from_slice::<Value>(&body).unwrap(),
                _ => panic!("unexpected frame kind {kind}"),
            }
        };
        assert_eq!(
            exited,
            json!({"type": "exited", "version": 2, "code": null, "signal": 9})
        );
        drop(client);
        assert_next_command(&runtime);
        runtime.finish();
    }

    #[test]
    fn disconnect_reaps_session_escaped_orphan_before_next_readiness() {
        let runtime = Runtime::new();
        let scratch = Scratch::new();
        let (client, pids) = start_tree(&runtime, &scratch);
        drop(client);
        let probe = runtime.connect();
        // Receiving ready on the next connection certifies cleanup of the
        // disconnected command, rather than merely queuing a cleanup request.
        for pid in &pids {
            assert!(!PathBuf::from(format!("/proc/{pid}")).exists());
        }
        drop(probe);
        assert_next_command(&runtime);
        runtime.finish();
    }
}
