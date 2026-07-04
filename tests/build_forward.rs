use std::process::Command;

fn run_build(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_sower"))
        .env("SOWER_BUILD_CLI", "echo")
        .env_remove("SOWER_ENDPOINT")
        .env_remove("SOWER_ACCESS_TOKEN_FILE")
        .arg("build")
        .args(args)
        .output()
        .expect("run sower build")
}

#[test]
fn build_execs_the_configured_binary_with_canonical_args() {
    let out = run_build(&["-d", "-p", "--tag", "a=b", "-j", "8", "."]);
    assert!(out.status.success(), "stderr: {:?}", out.stderr);
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "build --debug --push --build-jobs 8 --tag a=b .\n"
    );
}

#[test]
fn build_rejects_unknown_flags_before_forwarding() {
    let out = run_build(&["--no-such-flag", "."]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("--no-such-flag"));
}
