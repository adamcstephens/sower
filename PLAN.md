# Plan: Replace erlexec with Rexec — a lightweight Rust port wrapper

## Goal
Replace the erlexec dependency with `Rexec`, a standalone Elixir library (outside the umbrella) with a Rust port binary. Provides the same API surface: separate stdout/stderr streams, stdin forwarding, signal delivery, and exit status reporting. The Elixir callers (build.ex, eval.ex, store.ex, attic.ex) should need minimal changes.

## Architecture

**One Rust process per child command** (no long-running daemon, no multiplexing). The Rust binary:
- Receives the child command as argv
- fork/execs the child
- Sends child PID as the first message back
- Multiplexes child stdout and stderr as tagged packets over its own stdout
- Accepts tagged commands on its own stdin (forward-to-child-stdin, eof, kill)
- Reports exit status when child terminates

**Port protocol** (`{packet, 4}` — 4-byte big-endian length prefix):

Rust → Elixir:
- `0x00 ++ <4-byte pid>` — child OS pid (sent immediately after fork)
- `0x01 ++ <data>` — child stdout chunk
- `0x02 ++ <data>` — child stderr chunk
- `0x03 ++ <4-byte signed exit code>` — child exited normally
- `0x04 ++ <1-byte signal number>` — child killed by signal

Elixir → Rust:
- `0x01 ++ <data>` — forward data to child stdin
- `0x02` — close child stdin (eof)
- `0x03 ++ <1-byte signal number>` — send signal to child (e.g. 15 = SIGTERM)

**Elixir wrapper module** (`Rexec`) — a GenServer per child that:
- Opens a port to the Rust binary via `Port.open({:spawn_executable, path}, ...)`
- Parses the protocol and sends erlexec-compatible messages to the caller:
  - `{:stdout, ospid, data}`
  - `{:stderr, ospid, data}`
- On child exit: exits with `:normal` or `{:exit_status, code}` (matching erlexec behavior)
- Exposes `run_link/2`, `run/2`, `send/2`, `kill/2` matching the `:exec` API

## Steps

### 1. Create Rexec library (`libs/rexec/`)
- Standalone Mix project at `libs/rexec/` (outside the umbrella `apps/` directory)
- `mix.exs` with `rexec` app name
- Compilers: custom Mix compiler task to build the Rust binary via `cargo build --release`
- Priv directory holds the compiled Rust binary

### 2. Create Rust binary (`libs/rexec/native/rexec_native/`)
- New Cargo project: `libs/rexec/native/rexec_native/`
- Binary that:
  - Reads child command from argv
  - Forks/execs child via `std::process::Command` with piped stdin/stdout/stderr
  - Sends child PID as first packet
  - Spawns threads to read child stdout/stderr, send tagged packets
  - Reads stdin for commands (forward-stdin, eof, kill)
  - Waits for child exit, sends exit status packet, then exits itself

### 3. Create Elixir wrapper (`Rexec`)
- `libs/rexec/lib/rexec.ex` — GenServer that:
  - `run_link(cmd, opts)` — starts GenServer linked to caller, opens port, returns `{:ok, pid, ospid}`
  - `run(cmd, opts)` — starts GenServer (unlinked), caller monitors, returns `{:ok, pid, ospid}`
  - `send(ospid, data)` / `send(ospid, :eof)` — forwards stdin data or EOF
  - `kill(pid, signal)` — sends kill command via port
  - Handles `{port, {:data, packet}}` messages, decodes protocol, forwards to caller
  - On exit status message: stops GenServer with appropriate reason

### 4. Wire into sower
- Add `{:rexec, path: "../../libs/rexec"}` to `apps/nix/mix.exs` deps
- Add Rust binary to Nix package build in `nix/packages/`

### 5. Migrate callers (one at a time, test between each)
- **eval.ex**: Replace `:exec.run_link` → `Rexec.run_link`, `:exec.kill` → `Rexec.kill`
- **build.ex**: Replace `:exec.run_link` → `Rexec.run_link`
- **store.ex**: Replace `:exec.run_link` → `Rexec.run_link`, remove `Application.ensure_all_started(:erlexec)`
- **attic.ex**: Replace `:exec.run` → `Rexec.run`, `:exec.send` → `Rexec.send`, `:exec.kill` → `Rexec.kill`

### 6. Remove erlexec
- Remove `{:erlexec, "~> 2.0"}` from `apps/nix/mix.exs`
- Remove all `Application.ensure_all_started(:erlexec)` calls
- `mix deps.clean erlexec --unlock`

### 7. Test
- `just check-elixir` for unit tests
- `just check-e2e` for integration tests
- Verify memory monitoring in eval.ex still works (reads /proc/{ospid}/status — needs real OS pid from Rust)

## Key design decisions
- **Standalone library**: `Rexec` lives outside the umbrella in `libs/rexec/`, making it reusable and independently testable.
- **Per-child process, not daemon**: simpler, no multiplexing, no process table. Startup cost of the Rust binary is trivial (~1ms) vs nix commands (~200ms+).
- **Protocol-compatible messages**: callers keep their existing `handle_info` pattern matches unchanged.
- **ospid comes from Rust**: the Rust binary sends the actual child PID as the first packet, so /proc monitoring works.
- **No unsafe Rust needed**: `std::process::Command` handles fork/exec, `std::thread` for I/O multiplexing.
