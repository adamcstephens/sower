//! Execution-scoped, raw-byte forwarding. HTTP belongs to Nix and the host cache.
use std::fs::File;
use std::io::{self, Read, Write};
use std::net::TcpListener;
use std::os::fd::{AsRawFd, OwnedFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};

use rustix::net::{AddressFamily, SocketFlags, SocketType, socket_with};

pub const READ_URL: &str = "http://127.0.0.1:5001?trusted=true";
pub const WRITE_URL: &str = "http://127.0.0.1:5002?trusted=true";
const PORTS: [u16; 2] = [5001, 5002];
const MAX_CONNECTIONS: usize = 16;
const BUFFER_SIZE: usize = 8192;
const POLLIN: i16 = 1;
const POLLOUT: i16 = 4;
const POLLERR: i16 = 8;
const POLLHUP: i16 = 16;
const POLLNVAL: i16 = 32;
const SHUT_WR: i32 = 1;

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

#[repr(C)]
struct VsockAddress {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
    flags: u8,
    zero: [u8; 3],
}

unsafe extern "C" {
    fn poll(fds: *mut PollFd, count: usize, timeout: i32) -> i32;
    fn connect(fd: i32, address: *const VsockAddress, length: u32) -> i32;
    fn shutdown(fd: i32, how: i32) -> i32;
    fn getsockopt(fd: i32, level: i32, option: i32, value: *mut i32, length: *mut u32) -> i32;
}

fn poll_ready(fds: &mut [PollFd]) -> io::Result<()> {
    // Every socket is nonblocking. This bounded wait also makes cancellation interruptible.
    if unsafe { poll(fds.as_mut_ptr(), fds.len(), 50) } < 0 {
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
    Ok(())
}

fn host_connection(port: u16, stop: &AtomicBool) -> io::Result<File> {
    let socket = socket_with(
        AddressFamily::VSOCK,
        SocketType::STREAM,
        SocketFlags::CLOEXEC | SocketFlags::NONBLOCK,
        None,
    )?;
    let address = VsockAddress {
        family: AddressFamily::VSOCK.as_raw(),
        reserved: 0,
        port: u32::from(port),
        cid: 2,
        flags: 0,
        zero: [0; 3],
    };
    // rustix does not expose sockaddr_vm. The only destinations are the two fixed ports.
    let result = unsafe {
        connect(
            socket.as_raw_fd(),
            &address,
            std::mem::size_of::<VsockAddress>() as u32,
        )
    };
    if result != 0 {
        let error = io::Error::last_os_error();
        // Linux EINPROGRESS: completion (or failure) is reported through SO_ERROR.
        if error.raw_os_error() != Some(115) {
            return Err(error);
        }
        let mut fds = [PollFd {
            fd: socket.as_raw_fd(),
            events: POLLOUT,
            revents: 0,
        }];
        loop {
            if stop.load(Ordering::Acquire) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "execution stopped",
                ));
            }
            poll_ready(&mut fds)?;
            if fds[0].revents != 0 {
                let mut error = 0;
                let mut length = std::mem::size_of::<i32>() as u32;
                // Linux SOL_SOCKET = 1, SO_ERROR = 4.
                if unsafe { getsockopt(socket.as_raw_fd(), 1, 4, &mut error, &mut length) } != 0 {
                    return Err(io::Error::last_os_error());
                }
                if error != 0 {
                    return Err(io::Error::from_raw_os_error(error));
                }
                break;
            }
        }
    }
    Ok(File::from(socket))
}

struct Direction {
    bytes: [u8; BUFFER_SIZE],
    start: usize,
    end: usize,
    eof: bool,
}

impl Direction {
    fn new() -> Self {
        Self {
            bytes: [0; BUFFER_SIZE],
            start: 0,
            end: 0,
            eof: false,
        }
    }

    fn read(&mut self, source: &mut File, destination: &File) -> io::Result<()> {
        if self.eof || self.start != self.end {
            return Ok(());
        }
        match source.read(&mut self.bytes) {
            Ok(0) => {
                self.eof = true;
                // Preserve the other direction after EOF (HTTP clients may half-close).
                if unsafe { shutdown(destination.as_raw_fd(), SHUT_WR) } != 0 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(length) => {
                self.start = 0;
                self.end = length;
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) => {}
            Err(error) => return Err(error),
        }
        Ok(())
    }

    fn write(&mut self, destination: &mut File) -> io::Result<()> {
        if self.start == self.end {
            return Ok(());
        }
        match destination.write(&self.bytes[self.start..self.end]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "proxy write stopped",
                ));
            }
            Ok(length) => self.start += length,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) => {}
            Err(error) => return Err(error),
        }
        Ok(())
    }
}

fn forward(mut local: File, mut host: File, stop: &AtomicBool) -> io::Result<()> {
    let mut upload = Direction::new();
    let mut download = Direction::new();
    let mut fds = [
        PollFd {
            fd: local.as_raw_fd(),
            events: 0,
            revents: 0,
        },
        PollFd {
            fd: host.as_raw_fd(),
            events: 0,
            revents: 0,
        },
    ];
    while !stop.load(Ordering::Acquire) && !(upload.eof && download.eof) {
        fds[0].events = if !upload.eof && upload.start == upload.end {
            POLLIN
        } else {
            0
        } | if download.start != download.end {
            POLLOUT
        } else {
            0
        };
        fds[1].events = if !download.eof && download.start == download.end {
            POLLIN
        } else {
            0
        } | if upload.start != upload.end {
            POLLOUT
        } else {
            0
        };
        // poll reports HUP even without requested events. Ignore fully drained
        // half-closed directions so they cannot spin while the other side stalls.
        fds[0].fd = if fds[0].events == 0 {
            -1
        } else {
            local.as_raw_fd()
        };
        fds[1].fd = if fds[1].events == 0 {
            -1
        } else {
            host.as_raw_fd()
        };
        poll_ready(&mut fds)?;
        if fds.iter().any(|fd| fd.revents & (POLLERR | POLLNVAL) != 0) {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "proxy socket failed",
            ));
        }
        if fds[0].revents & (POLLOUT | POLLHUP) != 0 {
            download.write(&mut local)?;
        }
        if fds[1].revents & (POLLOUT | POLLHUP) != 0 {
            upload.write(&mut host)?;
        }
        if fds[0].revents & (POLLIN | POLLHUP) != 0 {
            upload.read(&mut local, &host)?;
        }
        if fds[1].revents & (POLLIN | POLLHUP) != 0 {
            download.read(&mut host, &local)?;
        }
    }
    Ok(())
}

pub struct Proxies {
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Proxies {
    pub fn start() -> io::Result<Self> {
        // Bind both before returning: the command cannot race listener readiness.
        let listeners = [
            TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, PORTS[0]))?,
            TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, PORTS[1]))?,
        ];
        for listener in &listeners {
            listener.set_nonblocking(true)?;
        }
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let worker = thread::Builder::new()
            .name("work-store".into())
            .spawn(move || {
                let mut workers: Vec<JoinHandle<()>> = Vec::with_capacity(MAX_CONNECTIONS);
                let mut fds = [
                    PollFd {
                        fd: listeners[0].as_raw_fd(),
                        events: POLLIN,
                        revents: 0,
                    },
                    PollFd {
                        fd: listeners[1].as_raw_fd(),
                        events: POLLIN,
                        revents: 0,
                    },
                ];
                while !worker_stop.load(Ordering::Acquire) {
                    let mut index = 0;
                    while index < workers.len() {
                        if workers[index].is_finished() {
                            let _ = workers.swap_remove(index).join();
                        } else {
                            index += 1;
                        }
                    }
                    if poll_ready(&mut fds).is_err() {
                        break;
                    }
                    for (index, listener) in listeners.iter().enumerate() {
                        if fds[index].revents & POLLIN == 0 {
                            continue;
                        }
                        // Accept at most one per listener per turn, keeping stop/reaping responsive.
                        if let Ok((local, _)) = listener.accept() {
                            if workers.len() == MAX_CONNECTIONS {
                                continue;
                            }
                            if local.set_nonblocking(true).is_err() {
                                continue;
                            }
                            let stop = Arc::clone(&worker_stop);
                            if let Ok(worker) = thread::Builder::new()
                                .name("cache-stream".into())
                                .spawn(move || {
                                    if let Ok(host) = host_connection(PORTS[index], &stop) {
                                        let _ =
                                            forward(File::from(OwnedFd::from(local)), host, &stop);
                                    }
                                })
                            {
                                workers.push(worker);
                            }
                        }
                    }
                }
                worker_stop.store(true, Ordering::Release);
                drop(listeners);
                for worker in workers {
                    let _ = worker.join();
                }
            })?;
        Ok(Self {
            stop,
            worker: Some(worker),
        })
    }
}

impl Drop for Proxies {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Shutdown;
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    fn pair() -> (UnixStream, File) {
        let (client, proxy) = UnixStream::pair().unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        client
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        proxy.set_nonblocking(true).unwrap();
        (client, File::from(OwnedFd::from(proxy)))
    }

    #[test]
    fn streams_binary_bytes_and_preserves_response_after_request_half_close() {
        let (mut client, local) = pair();
        let (mut server, host) = pair();
        let payload: Vec<u8> = (0..BUFFER_SIZE * 129)
            .map(|index| (index % 256) as u8)
            .collect();
        let expected = payload.clone();
        let proxy = thread::spawn(move || forward(local, host, &AtomicBool::new(false)));
        let responder = thread::spawn(move || {
            let mut bytes = Vec::new();
            server.read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes, expected);
            server.write_all(b"response\0after\xffEOF").unwrap();
            server.shutdown(Shutdown::Write).unwrap();
        });
        client.write_all(&payload).unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        let mut response = Vec::new();
        client.read_to_end(&mut response).unwrap();
        assert_eq!(response, b"response\0after\xffEOF");
        responder.join().unwrap();
        proxy.join().unwrap().unwrap();
    }

    #[test]
    fn host_half_close_does_not_discard_later_upload_bytes() {
        let (mut client, local) = pair();
        let (mut server, host) = pair();
        let proxy = thread::spawn(move || forward(local, host, &AtomicBool::new(false)));
        server.write_all(b"early response").unwrap();
        server.shutdown(Shutdown::Write).unwrap();
        let mut response = Vec::new();
        client.read_to_end(&mut response).unwrap();
        assert_eq!(response, b"early response");
        client.write_all(b"late request body").unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        let mut body = Vec::new();
        server.read_to_end(&mut body).unwrap();
        assert_eq!(body, b"late request body");
        proxy.join().unwrap().unwrap();
    }

    #[test]
    fn cancellation_interrupts_stalled_backpressured_connection() {
        let (mut client, local) = pair();
        let (_server, host) = pair();
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let proxy = thread::spawn(move || forward(local, host, &worker_stop));
        let writer = thread::spawn(move || {
            let bytes = [42; BUFFER_SIZE];
            while client.write_all(&bytes).is_ok() {}
        });
        thread::sleep(Duration::from_millis(100));
        let started = Instant::now();
        stop.store(true, Ordering::Release);
        proxy.join().unwrap().unwrap();
        writer.join().unwrap();
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
