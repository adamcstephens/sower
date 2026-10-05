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

#[cfg(unix)]
mod seed_warming {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Fixture {
        root: PathBuf,
        artifact: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "sower-deploy-warming-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("bin")).unwrap();
            let artifact = root.join("abc-nixos-system-host-26.05");
            fs::create_dir(&artifact).unwrap();
            fs::write(artifact.join("nixos-version"), "26.05").unwrap();
            let fixture = Self { root, artifact };
            fixture.executable(
                "nom",
                "#!/bin/sh\nprintf 'flake-build\\n' >> \"$SOWER_TEST_LOG\"\nprintf '%s\\n' \"$SOWER_TEST_ARTIFACT\"\n",
            );
            fixture.executable(
                "nix",
                "#!/bin/sh\nprintf '%s\\n' \"$@\" | paste -sd ' ' - >> \"$SOWER_TEST_LOG\"\n",
            );
            fixture
        }

        fn executable(&self, name: &str, script: &str) {
            let path = self.root.join("bin").join(name);
            fs::write(&path, script).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }

        fn run(
            &self,
            responses: Vec<(&'static str, u16, Value)>,
            args: &[&str],
        ) -> (Output, Vec<String>) {
            self.run_flake(".#host", responses, args)
        }

        fn run_flake(
            &self,
            flake: &str,
            responses: Vec<(&'static str, u16, Value)>,
            args: &[&str],
        ) -> (Output, Vec<String>) {
            self.run_source(&[flake], responses, args)
        }

        fn run_source(
            &self,
            source: &[&str],
            responses: Vec<(&'static str, u16, Value)>,
            args: &[&str],
        ) -> (Output, Vec<String>) {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let endpoint = format!("http://{}", listener.local_addr().unwrap());
            let server = thread::spawn(move || {
                let mut requests = Vec::new();
                for (expected, status, body) in responses {
                    let deadline = Instant::now() + Duration::from_secs(10);
                    let mut stream = loop {
                        match listener.accept() {
                            Ok((stream, _)) => break stream,
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                                assert!(Instant::now() < deadline, "missing {expected}");
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
                    assert!(request.starts_with(expected), "{request}");
                    let mut length = 0;
                    let mut authenticated = false;
                    loop {
                        let mut line = String::new();
                        reader.read_line(&mut line).unwrap();
                        if line == "\r\n" {
                            break;
                        }
                        let lower = line.to_ascii_lowercase();
                        authenticated |= lower.trim() == "authorization: bearer test-token";
                        if let Some(value) = lower.strip_prefix("content-length:") {
                            length = value.trim().parse().unwrap();
                        }
                    }
                    assert!(authenticated, "missing auth for {request}");
                    reader.read_exact(&mut vec![0; length]).unwrap();
                    requests.push(request.trim().to_owned());
                    let body = body.to_string();
                    write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
                }
                requests
            });
            let mut command = Command::new(env!("CARGO_BIN_EXE_sower"));
            let path = format!(
                "{}:{}",
                self.root.join("bin").display(),
                std::env::var("PATH").unwrap()
            );
            let output = command
                .env("PATH", path)
                .env("SOWER_TEST_LOG", self.root.join("calls"))
                .env("SOWER_TEST_ARTIFACT", &self.artifact)
                .env_remove("SOWER_ACCESS_TOKEN_FILE")
                .env_remove("SOWER_CONFIG_FILE")
                .env("RUST_LOG", "warn")
                .arg("deploy")
                .args(source)
                .args([
                    "--to",
                    "garden name",
                    "--no-wait",
                    "--access-token",
                    "test-token",
                    "--endpoint",
                    &endpoint,
                ])
                .args(args)
                .output()
                .unwrap();
            let requests = server.join().unwrap();
            (output, requests)
        }

        fn calls(&self) -> String {
            fs::read_to_string(self.root.join("calls")).unwrap_or_default()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.root).unwrap();
        }
    }

    fn registration() -> Value {
        json!({"artifact": "/nix/store/built", "name": "host", "seed_type": "nixos", "sid": "seed_built", "tags": []})
    }

    fn deployment() -> Value {
        super::deployment("created", None, vec![])
    }

    #[test]
    fn warms_matching_seed_with_caches_before_flake_build_and_substitutes_copy() {
        let fixture = Fixture::new();
        let (out, requests) = fixture.run(vec![
            ("GET /api/v1/gardens/garden%20name/latest-seed?name=host&seed_type=nixos ", 200,
                json!({"artifact": "/nix/store/previous", "name": "host", "seed_type": "nixos", "sid": "seed_previous", "tags": []})),
            ("GET /api/v1/nix/caches ", 200, json!([{"sid": "cache_1", "url": "https://cache.example", "public_key": "cache.example:key"}])),
            ("POST /api/v1/seeds ", 201, registration()),
            ("POST /api/v1/deployments ", 201, deployment()),
        ], &["--copy-to", "ssh://host"]);
        assert!(out.status.success(), "{}", stderr(&out));
        assert_eq!(requests.len(), 4);
        let calls = fixture.calls();
        let lines: Vec<_> = calls.lines().collect();
        assert_eq!(
            lines[0],
            "build /nix/store/previous --extra-substituters https://cache.example --extra-trusted-public-keys cache.example:key"
        );
        assert_eq!(lines[1], "flake-build");
        assert_eq!(
            lines[2],
            format!(
                "copy --to ssh://host --substitute-on-destination {}",
                fixture.artifact.display()
            )
        );
    }

    #[test]
    fn no_match_and_disabled_download_leave_build_unwarmed() {
        for (response, flags) in [(Some(204), vec![]), (None, vec!["--no-seed-download"])] {
            let fixture = Fixture::new();
            let mut responses = Vec::new();
            if let Some(status) = response {
                responses.push((
                    "GET /api/v1/gardens/garden%20name/latest-seed?name=host&seed_type=nixos ",
                    status,
                    json!(null),
                ));
            }
            responses.extend([
                ("POST /api/v1/seeds ", 201, registration()),
                ("POST /api/v1/deployments ", 201, deployment()),
            ]);
            let (out, requests) = fixture.run(responses, &flags);
            assert!(out.status.success(), "{}", stderr(&out));
            assert_eq!(requests.len(), if response.is_some() { 3 } else { 2 });
            assert_eq!(fixture.calls(), "flake-build\n");
        }
    }

    #[test]
    fn unknown_prebuild_name_does_not_query_previous_seed() {
        let fixture = Fixture::new();
        let (out, requests) = fixture.run_flake(
            ".#packages.x86_64-linux.thing",
            vec![
                ("POST /api/v1/seeds ", 201, registration()),
                ("POST /api/v1/deployments ", 201, deployment()),
            ],
            &[],
        );
        assert!(out.status.success(), "{}", stderr(&out));
        assert_eq!(requests.len(), 2);
        assert_eq!(fixture.calls(), "flake-build\n");
        assert!(stderr(&out).contains("Cannot infer a seed name"));
    }

    #[test]
    fn old_server_or_lookup_failure_warns_but_still_deploys() {
        for status in [401, 404, 409, 500] {
            let fixture = Fixture::new();
            let (out, requests) = fixture.run(
                vec![
                    (
                        "GET /api/v1/gardens/garden%20name/latest-seed?name=host&seed_type=nixos ",
                        status,
                        json!({}),
                    ),
                    ("POST /api/v1/seeds ", 201, registration()),
                    ("POST /api/v1/deployments ", 201, deployment()),
                ],
                &[],
            );
            assert!(out.status.success(), "{status}: {}", stderr(&out));
            assert_eq!(requests.len(), 3);
            assert_eq!(fixture.calls(), "flake-build\n");
            assert!(
                stderr(&out).contains("Could not download previous seed"),
                "{status}: {}",
                stderr(&out)
            );
        }
    }

    #[test]
    fn cache_lookup_and_realization_failure_warn_but_still_build() {
        for fail_realization in [false, true] {
            let fixture = Fixture::new();
            if fail_realization {
                fixture.executable(
                    "nix",
                    "#!/bin/sh\nprintf '%s\\n' \"$@\" | paste -sd ' ' - >> \"$SOWER_TEST_LOG\"\nexit 88\n",
                );
            }
            let (out, requests) = fixture.run(vec![
                ("GET /api/v1/gardens/garden%20name/latest-seed?name=host&seed_type=nixos ", 200,
                    json!({"artifact": "/nix/store/previous", "name": "host", "seed_type": "nixos", "sid": "seed_previous", "tags": []})),
                ("GET /api/v1/nix/caches ", if fail_realization { 200 } else { 500 },
                    if fail_realization { json!([]) } else { json!({}) }),
                ("POST /api/v1/seeds ", 201, registration()),
                ("POST /api/v1/deployments ", 201, deployment()),
            ], &[]);
            assert!(out.status.success(), "{}", stderr(&out));
            assert_eq!(requests.len(), 4);
            assert!(stderr(&out).contains("Could not download previous seed"));
            let calls = fixture.calls();
            if fail_realization {
                assert_eq!(calls, "build /nix/store/previous\nflake-build\n");
            } else {
                assert_eq!(calls, "flake-build\n");
            }
        }
    }

    #[test]
    fn explicit_name_is_used_for_matching_without_changing_artifact() {
        let fixture = Fixture::new();
        let (out, requests) = fixture.run(vec![
            ("GET /api/v1/gardens/garden%20name/latest-seed?name=explicit+host&seed_type=nixos ", 204, json!(null)),
            ("POST /api/v1/seeds ", 201, registration()),
            ("POST /api/v1/deployments ", 201, deployment()),
        ], &["--name", "explicit host"]);
        assert!(out.status.success(), "{}", stderr(&out));
        assert_eq!(requests.len(), 3);
        assert_eq!(fixture.calls(), "flake-build\n");
    }

    #[test]
    fn canonical_jobs_validate_manifests_before_copy_or_registration() {
        for (flake, manifest, expected) in [
            (".#nixos/host", None, "seed.json"),
            (".#home/alice", Some("not json"), "seed manifest"),
            (
                ".#seed/custom",
                Some(
                    r#"{"version":2,"name":"host","seed_type":"nixos","artifact":"/nix/store/00000000000000000000000000000000-target","tags":{}}"#,
                ),
                "version",
            ),
            (
                ".#packages.x86_64-linux.nixos/host",
                Some(
                    r#"{"version":1,"name":"host","seed_type":"nixos","artifact":"/tmp/not-a-store-path","tags":{}}"#,
                ),
                "artifact",
            ),
        ] {
            let fixture = Fixture::new();
            if let Some(manifest) = manifest {
                fs::write(fixture.artifact.join("seed.json"), manifest).unwrap();
            }
            let (out, _) = fixture.run_flake(
                flake,
                vec![],
                &["--no-seed-download", "--copy-to", "ssh://host"],
            );
            assert!(!out.status.success(), "{}", stderr(&out));
            assert!(stderr(&out).contains(expected), "{}", stderr(&out));
            assert_eq!(fixture.calls(), "flake-build\n");
        }
    }

    #[test]
    fn canonical_deployment_prechecks_the_manifest_target_not_the_wrapper() {
        let fixture = Fixture::new();
        let target = "/nix/store/00000000000000000000000000000000-sower-missing-target";
        fs::write(
            fixture.artifact.join("seed.json"),
            json!({"version": 1, "name": "alice", "seed_type": "home-manager",
                "artifact": target, "tags": {"owner": "alice"}})
            .to_string(),
        )
        .unwrap();
        for flake in [
            ".#home/alice",
            ".#\"home/alice\"",
            ".#packages.x86_64-linux.\"home/alice.example\"",
            ".#\"nixos/alice.example\"",
            ".#packages.x86_64-linux.\"seed/alice.example\"",
        ] {
            let (out, _) = fixture.run_flake(
                flake,
                vec![],
                &["--no-seed-download", "--copy-to", "ssh://host"],
            );
            assert!(!out.status.success(), "{flake}: {}", stderr(&out));
            assert!(
                stderr(&out).contains(&format!("{target}/hm-version")),
                "{flake}: {}",
                stderr(&out)
            );
        }
        assert_eq!(fixture.calls(), "flake-build\n".repeat(5));
    }

    #[test]
    fn quoted_home_job_warms_using_the_unquoted_name_and_home_manager_type() {
        let fixture = Fixture::new();
        let (out, requests) = fixture.run_flake(
            ".#packages.x86_64-linux.\"home/alice.example\"",
            vec![(
                "GET /api/v1/gardens/garden%20name/latest-seed?name=alice.example&seed_type=home-manager ",
                204,
                json!(null),
            )],
            &[],
        );
        assert!(!out.status.success());
        assert!(stderr(&out).contains("seed.json"), "{}", stderr(&out));
        assert_eq!(requests.len(), 1);
        assert_eq!(fixture.calls(), "flake-build\n");
    }

    #[test]
    fn quoted_jobs_keep_explicit_name_and_type_overrides() {
        let fixture = Fixture::new();
        let target = "/nix/store/00000000000000000000000000000000-sower-missing-target";
        fs::write(
            fixture.artifact.join("seed.json"),
            json!({"version": 1, "name": "manifest-name", "seed_type": "home-manager",
                "artifact": target, "tags": {}})
            .to_string(),
        )
        .unwrap();
        let (out, requests) = fixture.run_flake(
            ".#\"home/alice.example\"",
            vec![(
                "GET /api/v1/gardens/garden%20name/latest-seed?name=explicit+name&seed_type=nixos ",
                204,
                json!(null),
            )],
            &[
                "--name",
                "explicit name",
                "--type",
                "nixos",
                "--copy-to",
                "ssh://host",
            ],
        );
        assert!(!out.status.success());
        assert!(
            stderr(&out).contains(&format!("{target}/nixos-version")),
            "{}",
            stderr(&out)
        );
        assert_eq!(requests.len(), 1);
        assert_eq!(fixture.calls(), "flake-build\n");
    }

    #[test]
    fn path_and_registered_seed_never_fetch_previous_seed() {
        let fixture = Fixture::new();
        let (out, requests) = fixture.run_source(
            &["--path", fixture.artifact.to_str().unwrap()],
            vec![
                ("POST /api/v1/seeds ", 201, registration()),
                ("POST /api/v1/deployments ", 201, deployment()),
            ],
            &[],
        );
        assert!(out.status.success(), "{}", stderr(&out));
        assert_eq!(requests.len(), 2);
        assert_eq!(fixture.calls(), "");

        let fixture = Fixture::new();
        let (out, requests) = fixture.run_source(
            &["--seed", "seed_existing"],
            vec![("POST /api/v1/deployments ", 201, deployment())],
            &[],
        );
        assert!(out.status.success(), "{}", stderr(&out));
        assert_eq!(requests.len(), 1);
        assert_eq!(fixture.calls(), "");
    }
}
