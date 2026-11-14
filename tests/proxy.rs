use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant};

fn cli(endpoint: &str, vars: &[(&str, &str)]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_sower"));
    for name in [
        "HTTP_PROXY",
        "http_proxy",
        "HTTPS_PROXY",
        "https_proxy",
        "ALL_PROXY",
        "all_proxy",
        "NO_PROXY",
        "no_proxy",
        "SOWER_CONFIG_FILE",
        "SOWER_ACCESS_TOKEN_FILE",
    ] {
        command.env_remove(name);
    }
    command.envs(vars.iter().copied());
    command.args([
        "seed",
        "--endpoint",
        endpoint,
        "--access-token",
        "origin-token",
        "--name",
        "proxy-test",
        "--type",
        "nixos",
        "info",
    ]);
    command.output().expect("run API command")
}

fn fixture() -> (String, thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    listener.set_nonblocking(true).unwrap();
    let worker = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "API did not reach fixture");
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept request: {error}"),
            }
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut request = Vec::new();
        let mut byte = [0];
        while !request.ends_with(b"\r\n\r\n") {
            assert_eq!(stream.read(&mut byte).unwrap(), 1);
            request.push(byte[0]);
        }
        stream.write_all(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
        String::from_utf8(request).unwrap()
    });
    (address, worker)
}

#[test]
fn api_uses_authenticated_proxy_and_uppercase_precedence() {
    let (proxy, request) = fixture();
    let authenticated = proxy.replacen("http://", "http://user:p%3Aa%40ss+@", 1);
    let output = cli(
        "http://origin.invalid",
        &[
            ("HTTP_PROXY", &authenticated),
            ("http_proxy", "http://127.0.0.1:1"),
        ],
    );
    assert!(!output.status.success());
    let request = request.join().unwrap().to_ascii_lowercase();
    assert!(
        request.starts_with("get http://origin.invalid/"),
        "{request}"
    );
    assert!(
        request.contains("proxy-authorization: basic dxnlcjpwomfac3mr"),
        "{request}"
    );
    assert!(
        request.contains("authorization: bearer origin-token"),
        "{request}"
    );
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(!error.contains("p%3Aa%40ss+") && !error.contains("p:a@ss+"));
}

#[test]
fn empty_uppercase_proxy_preserves_direct_requests() {
    let (origin, request) = fixture();
    let output = cli(
        &origin,
        &[("HTTP_PROXY", ""), ("http_proxy", "http://127.0.0.1:1")],
    );
    assert!(!output.status.success());
    let request = request.join().unwrap().to_ascii_lowercase();
    assert!(request.starts_with("get /"), "{request}");
    assert!(!request.contains("proxy-authorization"), "{request}");
}

#[test]
fn no_proxy_ip_bypasses_authenticated_proxy() {
    let (origin, request) = fixture();
    let output = cli(
        &origin,
        &[
            ("HTTP_PROXY", "http://secret:password@127.0.0.1:1"),
            ("NO_PROXY", "127.0.0.1"),
        ],
    );
    assert!(!output.status.success());
    let request = request.join().unwrap().to_ascii_lowercase();
    assert!(request.starts_with("get /"), "{request}");
    assert!(!request.contains("proxy-authorization"), "{request}");
}

#[test]
fn https_destination_uses_https_proxy_connect() {
    let (proxy, request) = fixture();
    let output = cli(
        "https://origin.invalid",
        &[
            ("HTTPS_PROXY", &proxy),
            ("HTTP_PROXY", "http://127.0.0.1:1"),
        ],
    );
    assert!(!output.status.success());
    assert!(
        request
            .join()
            .unwrap()
            .starts_with("CONNECT origin.invalid:443 HTTP/1.1\r\n")
    );
}

#[test]
fn lowercase_proxy_and_no_proxy_domain_boundaries() {
    let (proxy, request) = fixture();
    let output = cli(
        "http://notexample.invalid",
        &[("http_proxy", &proxy), ("no_proxy", "example.invalid")],
    );
    assert!(!output.status.success());
    assert!(
        request
            .join()
            .unwrap()
            .starts_with("GET http://notexample.invalid/")
    );
}

#[test]
fn no_proxy_exact_hostname_bypasses_proxy() {
    let (origin, request) = fixture();
    let origin = origin.replace("127.0.0.1", "localhost");
    let output = cli(
        &origin,
        &[
            ("HTTP_PROXY", "http://127.0.0.1:1"),
            ("NO_PROXY", "localhost"),
        ],
    );
    assert!(!output.status.success());
    let request = request.join().unwrap().to_ascii_lowercase();
    assert!(request.starts_with("get /"), "{request}");
    assert!(!request.contains("proxy-authorization"), "{request}");
}

#[test]
fn no_proxy_configuration_preserves_direct_requests() {
    let (origin, request) = fixture();
    let output = cli(&origin, &[]);
    assert!(!output.status.success());
    let request = request.join().unwrap().to_ascii_lowercase();
    assert!(request.starts_with("get /"), "{request}");
    assert!(!request.contains("proxy-authorization"), "{request}");
}
