# Builders — Specification

> Status: DRAFT for refinement. See Resolved Decisions for what is
> settled and Open Questions for what is not.

## Overview

A builder is sower's isolated execution layer: a garden that runs work
in cloud-hypervisor microVMs on behalf of the server. Pipelines are the
first client, not the point — the builder contract is a general
"execute this, isolated" primitive, and everything sower executes
server-side goes through it from day one. Evaluating a repository is
code execution; it never happens on the server, only inside a builder
VM.

Known clients:

- **Pipeline steps** — `eval`, `build`, `push`, `seed`, `check`,
  `effect` (spec-pipeline.md, Execution Environment).
- **Environment materialization** — the builtin chain applied to
  environment images (spec-pipeline.md, Environment seeds).
- **Seed trust** — the sandboxed eval/build half of the ephemeral
  signing model (spec-seed-trust.md, D5c and phases 4–5).
- **Remote `sower-build`** — a possible later client submitting work
  instead of running it locally.

This spec owns the builder role, the execution contract, the host–guest
contract, the guest Nix store strategy, dispatch, and the security
boundaries. The pipeline definition contract that generates executions
is spec-pipeline.md's; the trust model executions must uphold is
spec-seed-trust.md's.

## Design Principles

- **A builder is a garden role, not a second fleet.** Builders
  register, authenticate (`private_key_jwt`), connect outbound, report
  versions, and self-update via seeds and subscriptions exactly as
  gardens do. There is no separate builder registration, protocol
  stack, or upgrade mechanism.
- **Executions are generic; semantics live in the guest.** The host
  knows images, resources, network policy, commands, and streams. It
  does not know what a pipeline, step, or seed is. Builtin step
  behavior ships as programs in the stock image, versioned by the guest
  contract.
- **Isolation is the product.** The VM boundary plus host-enforced
  network policy is what makes untrusted eval, checks, and effects
  safe. There is no non-VM server-side execution path.
- **Authority never rides with untrusted code.** Credentials are
  minted per execution, short-TTL and scoped, injected as files by the
  host. An execution that evaluates repository code never receives
  signing credentials; signing happens outside the guest, on a clean
  result.
- **Everything the builder runs is Nix.** Images are seeds; the stock
  image and user environments arrive through the same registry, cache,
  and subscription machinery as every other closure.
- **Local mode stays.** `sower-build` keeps its in-process eval/build
  for development and bootstrap. It shares the step vocabulary, not the
  builder path; only server-side execution requires builders.

## Model

| Term          | Meaning                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------- |
| Builder       | A garden with the builder capability: a host agent executing microVMs for the server.         |
| Execution     | One unit of dispatched work: image + command + payload + resources → event stream + result.   |
| Image         | A complete guest system closure — the stock image or a `mkEnvironment` output, as a seed.     |
| Host agent    | The builder-side service: VM lifecycle, network enforcement, secret injection, store egress.  |
| Guest runtime | The sower-owned service inside every image that receives the command and mediates I/O.        |
| Dispatch      | Server-side assignment of a queued execution to a connected builder with capacity.            |

## Builder Role

A builder is a registered garden whose connection advertises the
builder capability:

| Field    | Description                                                  |
| -------- | ------------------------------------------------------------ |
| systems  | Systems it can execute (`x86_64-linux`, `aarch64-linux`, …). |
| slots    | Maximum concurrent executions.                               |
| memory   | Total memory budget for guest VMs, in MiB.                   |
| features | Host capabilities (e.g. `kvm`; nested virtualisation later). |

The server gates dispatch on the builder's reported version, following
the existing contract discipline. Builder software is deployed like any
garden's: as seeds under the builder's own subscriptions and policy.
Stock images and pinned environments pre-warm the same way — a builder
subscribes to `environment` seeds with a stage-only policy
(spec-pipeline.md, Environment seeds), so images are pinned locally
before a run asks.

## Execution Contract

The dispatch message. Schemas live in `sower_client` and are covered by
the contract baseline.

| Field    | Type     | Required | Description                                                                          |
| -------- | -------- | -------- | ------------------------------------------------------------------------------------ |
| sid      | string   | yes      | Execution id; idempotency key for redispatch.                                        |
| image    | string   | yes      | Store path of the guest image closure (a registered seed's artifact).                |
| command  | object   | yes      | `{ path, args, env }` — a store-path executable inside the image's closure.          |
| payload  | object   | yes      | JSON delivered to the command on stdin (a pipeline item, for step executions).       |
| vm       | object   | yes      | `{ cpus, memory }`, resolved by the server from definition defaults.                 |
| network  | string   | yes      | `none`, `cache-only`, or `full` — enforced by the host.                              |
| caches   | object[] | no       | Resolved substituter configuration for `cache-only`; server-materialized.            |
| secrets  | object   | no       | Named secret material to inject as files (see Security). Never logged nor persisted. |
| paths    | string[] | no       | Store paths the guest must see (inputs beyond the image closure).                    |
| timeout  | string   | yes      | Per-attempt execution deadline.                                                      |

The host never templates or interprets `command` and `payload` — it
execs one and delivers the other, exactly once, per the item context
convention (spec-pipeline.md). The pipeline engine, not the builder,
resolves step kinds to commands: `eval` becomes the stock runtime's
eval program; a `check` becomes the built app's executable. Arbitrary
argv is excluded at pipeline validation, not here — the builder
contract is deliberately mechanism, not policy.

Events stream back over the garden channel as the execution proceeds:

| Event     | Payload                                                              |
| --------- | -------------------------------------------------------------------- |
| started   | Builder accepted; VM booted.                                         |
| log       | Stdout/stderr chunks, interleaved, sequence-numbered.                |
| item      | A structured JSON document emitted by the command (see Host–Guest).  |
| paths     | Store paths produced and exported (see Store Strategy).              |
| exited    | Terminal: exit code, or `failed` / `cancelled` / `timeout` + reason. |

`item` events are how streaming entry-point steps work: one eval
execution emits an item per derivation as its attribute walk proceeds,
and the pipeline engine fans them into consuming phases without waiting
for the walk to finish.

## Host–Guest Contract

Every image embeds the sower guest runtime via the mandatory base
module of `sower.lib.mkEnvironment` (spec-pipeline.md, Execution
Environment), and stamps `/etc/sower/env.json` with a versioned
guest-contract marker. The host agent refuses images whose marker is
missing or out of its supported range — the runtime surface is a
cross-component contract like any other.

Transport between host agent and guest runtime is a vsock control
channel. The command's own I/O convention is unchanged from the
pipeline spec: payload as JSON on stdin, stdout and stderr captured as
the step log. Programs that emit items (eval; later, checks enriching
items) write JSON lines to a runtime-provided descriptor, which the
runtime forwards as `item` events — application stdout stays log, never
protocol.

The guest runtime receives the command over vsock after boot, injects
nothing into its environment beyond `command.env`, and reports exit
status. VMs are ephemeral: booted per execution, destroyed after,
nothing surviving but exported paths and the event stream.

## Nix Store Strategy

The guest needs closures (image, command, inputs) and may produce paths
(builds). The leaning:

- **Ingress: read-only virtiofs share of the host store.** The guest's
  Nix daemon uses the share as a local substitution source and builds
  into a guest-private scratch store. Guests can never write the host
  store; `cache-only` network additionally allows the resolved cache
  substituters. The host agent pins (gcroots) the image and declared
  input paths for the execution's duration.
- **Egress: NAR export to the host agent.** Produced paths named by the
  command are exported over the control channel and imported into the
  host store under a per-run gcroot. This is what lets a later `push`
  execution — its own VM, per the one-step-one-VM rule — see what
  `build` produced: through the read-only share, without any
  guest-to-guest or guest-to-host-store write path. `push` uploads from
  the share to the cache with its scoped credential; the cache remains
  the durable artifact layer.

Host-store hygiene: imported guest output is stored and served, but
storage is not endorsement — whether a path may be activated anywhere
is the signing layer's question (spec-seed-trust.md), not the store's.
Run-scoped gcroots are released when the run closes; retention beyond
that belongs to the cache.

## Dispatch

The server owns a queue of executions and assigns each to a connected
builder matching `system` with a free slot and sufficient memory,
over the garden channel — the same discipline as deployment dispatch.

- **Failure:** a builder disconnecting or dying mid-execution fails the
  execution; the server does not transparently re-run it. Retry is the
  client layer's move (a pipeline rerun memoizes past completed work),
  keeping builder semantics at-most-once and dumb.
- **Cancellation:** kills the VM; the execution reports `cancelled`.
  Already-exported paths and emitted items stand.
- **Placement policy** beyond system/capacity — labels, tenant pools,
  affinity — is a future consideration; the contract fields do not
  change for it.

## Security

- **Network policy is host-enforced** per VM (tap + host firewall):
  `none` for hermetic work, `cache-only` restricted to the resolved
  cache endpoints, `full` for checks and effects that reach out.
- **Secrets** are injected by the host agent at VM start as files under
  `/run/sower/secrets/<name>` on a tmpfs, and die with the VM. They
  arrive in the dispatch message over the channel's TLS, are never
  written to the builder's disk or logs, and never enter the image or
  any Nix store. Access decisions happened server-side (spec-pipeline.md,
  Secrets); the host mounts only what dispatch delivered.
- **Sower's own credentials** (cache push, seed registration) are
  minted per execution, short-TTL and scoped, delivered the same way.
  The quarantine-cache redirection for untrusted runs happens at
  minting; the builder is indifferent.
- **Signing separation (D5c):** no execution that evaluates or runs
  repository-derived code receives signing credentials. The ephemeral
  signing of spec-seed-trust.md is performed by the host agent (or a
  dedicated non-guest step) over a completed, exported result — the
  compromise of a guest never yields signing authority.

## Local Mode and Development

`sower-build` keeps its in-process eval/build path: development and
bootstrap must work on a laptop with no builder fleet, no KVM, no
server. The CLI and the stock image's guest programs share the step
vocabulary (`Nix.Eval.Jobs` and friends) as libraries; isolation is a
property of the server-side path, not of the vocabulary.

Server-side, there is exactly one execution path — through builders.
The development server therefore needs a local builder: `sower_dev`
runs one host agent beside the server (requiring KVM), and e2e runs
builders inside its incus VMs, which requires nested virtualisation on
the e2e host (Open Questions).

## Phasing

1. **Builder role + generic executions.** Capability advertisement,
   dispatch, event stream, stock image with eval and build guest
   programs, virtiofs ingress and NAR egress. Unblocks sow-221.
2. **Push, seed, and credential minting.** Scoped short-TTL
   credentials; quarantine redirection.
3. **Custom environments.** `sower.lib.mkEnvironment`, environment
   seeds, materialization, pre-warm subscriptions, pinning.
4. **Secrets and user code.** Secret injection; `check` and `effect`
   step kinds land in the pipeline engine.
5. **Seed-trust integration.** Ephemeral signing on builders
   (spec-seed-trust.md phases 4–5), signing separation enforced.

## Resolved Decisions

- **Builders are a garden role.** Registration, auth, channel,
  versioning, and self-update are the garden's; no parallel mechanism.
- **The execution contract is generic.** Image + command + payload +
  resources + network + secrets → events. Step semantics live in guest
  programs; the host never interprets work.
- **Commands are store-path executables.** The host execs what
  dispatch names and templates nothing; restricting what may be named
  is pipeline validation's job.
- **Structured output is a runtime channel, not stdout.** Items flow
  as JSONL over a runtime descriptor; application stdout stays log.
- **Guest store: read-only host share in, NAR export out.** Guests
  never write the host store; produced paths re-enter host-side under
  run-scoped gcroots; the cache is the durable layer.
- **Storage is not endorsement.** Serving a guest-produced path says
  nothing about activation; that remains the signing layer's decision.
- **Executions are at-most-once.** Builder failure fails the
  execution; retry is memoized rerun at the client layer.
- **No signing authority in guests.** Executions touching
  repository-derived code never hold signing credentials.
- **Local mode stays.** `sower-build` runs in-process for dev and
  bootstrap; only the server-side path requires builders.

## Open Questions

- **Nested virtualisation in e2e.** Builders inside incus VMs need
  nested KVM on the e2e host; is that acceptable infrastructure, or
  does e2e need a degraded builder (single shared VM? container-backed
  host agent) that keeps the contract but weakens isolation?
- **Egress naming.** How a command declares which produced paths to
  export — an explicit manifest over the runtime channel, or everything
  the scratch store gained? Leaning: explicit, via the item/event
  channel.
- **Secret transport.** Secrets ride the dispatch message today; is a
  pull-at-start flow (builder fetches sealed material when the VM
  boots) worth the extra round trip to shrink the window material
  exists outside the host's memory?
- **Capacity model.** Slots + memory budget vs. real bin-packing on
  cpus/memory; whether eval's memory ceilings need reflecting in
  advertisement.
- **Image cache lifecycle on builders.** Pre-warmed and fetched images
  accumulate; gc policy for images no longer referenced by any
  subscription or recent execution.
- **vsock details.** Framing and versioning of the control channel;
  whether the guest contract marker also states the vsock protocol
  range or the marker version covers both.
