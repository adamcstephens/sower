use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant};

fn deployment(state: &str, result: Option<&str>, seeds: Vec<Value>) -> Value {
    json!({"sid": "dply_test", "garden_sid": "grdn_test", "state": state,
        "result": result, "skipped": false, "seeds": seeds})
}

fn seed(name: &str, result: &str, log: Option<&str>) -> Value {
    json!({"seed_sid": format!("seed_{name}"), "name": name, "seed_type": "nixos",
        "state": "completed", "result": result, "log": log})
}

fn run(responses: Vec<(u16, Value)>, no_wait: bool, trailing_slash: bool) -> (Output, String) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = thread::spawn(move || {
        for (index, (status, body)) in responses.into_iter().enumerate() {
            let status = if index == 0 && status == 200 {
                201
            } else {
                status
            };
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "missing request {index}");
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("{error}"),
                }
            };
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut reader = BufReader::new(&mut stream);
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            let path = if index == 0 { "POST /" } else { "GET /" };
            assert!(request.starts_with(path), "{request}");
            assert!(
                request.contains(if index == 0 {
                    "/api/v1/deployments HTTP/1.1"
                } else {
                    "/api/v1/deployments/dply_test HTTP/1.1"
                }),
                "{request}"
            );
            let mut length = 0;
            let mut authenticated = false;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                let line = line.to_ascii_lowercase();
                if let Some(value) = line.strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap();
                }
                authenticated |= line.trim() == "authorization: bearer test-token";
            }
            assert!(authenticated);
            reader.read_exact(&mut vec![0; length]).unwrap();
            let body = body.to_string();
            write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        }
    });
    let mut command = Command::new(env!("CARGO_BIN_EXE_sower"));
    command
        .env_remove("SOWER_ACCESS_TOKEN_FILE")
        .env_remove("SOWER_CONFIG_FILE")
        .env("RUST_LOG", "off")
        .args([
            "deploy",
            "--seed",
            "seed_test",
            "--to",
            "grdn_test",
            "--access-token",
            "test-token",
            "--endpoint",
        ])
        .arg(format!(
            "{endpoint}{}",
            if trailing_slash { "/" } else { "" }
        ));
    if no_wait {
        command.arg("--no-wait");
    }
    let output = command.output().unwrap();
    assert!(server.join().is_ok(), "CLI stderr: {}", stderr(&output));
    (output, format!("{endpoint}/deployments/dply_test"))
}

fn stderr(output: &Output) -> String {
    String::from_utf8(output.stderr.clone()).unwrap()
}

#[test]
fn success_and_skipped_deployments_link_without_tracing() {
    for skipped in [false, true] {
        let mut info = deployment("completed", Some("success"), vec![]);
        info["skipped"] = json!(skipped);
        let (output, url) = run(vec![(200, info)], false, skipped);
        assert!(output.status.success(), "{}", stderr(&output));
        assert!(stderr(&output).contains(&url));
        assert!(!stderr(&output).contains("test-token"));
        assert!(output.stdout.is_empty());
    }
}

#[test]
fn no_wait_prints_only_sid_to_stdout_and_never_fetches_logs() {
    let info = deployment(
        "completed",
        Some("failure"),
        vec![seed("host", "failure", Some("hidden-log"))],
    );
    let (output, url) = run(vec![(200, info)], true, true);
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(output.stdout, b"dply_test\n");
    assert!(stderr(&output).contains(&url));
    assert!(!stderr(&output).contains("hidden-log"));
}

#[test]
fn link_survives_poll_failure() {
    let (output, url) = run(
        vec![
            (200, deployment("dispatched", None, vec![])),
            (500, json!({})),
        ],
        false,
        false,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains(&url));
    assert!(stderr(&output).contains("poll deployment"));
}

#[test]
fn final_logs_refresh_without_state_change_and_prefer_failed_seeds() {
    for newline in ["", "\n"] {
        let old = deployment(
            "dispatched",
            None,
            vec![seed("host", "failure", Some("obsolete-log"))],
        );
        let terminal = deployment(
            "completed",
            Some("failure"),
            old["seeds"].as_array().unwrap().clone(),
        );
        let log = (1..=60)
            .map(|n| format!("line-{n:02}"))
            .collect::<Vec<_>>()
            .join("\n")
            + newline;
        let latest = deployment(
            "completed",
            Some("failure"),
            vec![
                seed("host", "failure", Some(&log)),
                seed("healthy", "success", Some("healthy-log")),
            ],
        );
        let (output, _) = run(
            vec![(200, old), (200, terminal), (200, latest)],
            false,
            false,
        );
        let text = stderr(&output);
        assert!(!output.status.success());
        assert!(text.contains("host"));
        assert!(!text.contains("obsolete-log"));
        assert!(!text.contains("healthy-log"));
        assert!(!text.contains("line-10"));
        assert_eq!(
            text.lines()
                .filter(|line| line.starts_with("line-"))
                .collect::<Vec<_>>(),
            (11..=60)
                .map(|n| format!("line-{n:02}"))
                .collect::<Vec<_>>()
        );
    }
}

#[test]
fn deployment_level_failure_shows_short_available_logs() {
    let info = deployment(
        "canceled",
        None,
        vec![
            seed("first", "success", Some("first-line\nlast-line\n")),
            seed("second", "success", Some("single-line")),
        ],
    );
    let (output, _) = run(vec![(200, info.clone()), (200, info)], false, false);
    let text = stderr(&output);
    assert!(!output.status.success());
    for expected in [
        "first",
        "second",
        "first-line\nlast-line",
        "single-line",
        "result canceled",
    ] {
        assert!(text.contains(expected), "{text}");
    }
}

#[test]
fn diagnostic_failure_preserves_result_and_uses_known_log() {
    let info = deployment(
        "completed",
        Some("partial"),
        vec![seed("host", "failure", Some("known-log"))],
    );
    let (output, _) = run(vec![(200, info), (500, json!({}))], false, false);
    let text = stderr(&output);
    assert!(!output.status.success());
    assert!(text.contains("known-log"));
    assert!(text.contains("Could not fetch deployment logs"));
    assert!(text.contains("result partial"));
}

#[test]
fn missing_logs_are_explicit_even_when_diagnostic_fetch_fails() {
    for status in [200, 500] {
        let info = deployment("stale", None, vec![seed("host", "failure", None)]);
        let (output, _) = run(vec![(200, info.clone()), (status, info)], false, false);
        let text = stderr(&output);
        assert!(!output.status.success());
        assert!(text.contains("No deployment logs available"), "{text}");
        assert!(text.contains("result stale"));
    }
}
