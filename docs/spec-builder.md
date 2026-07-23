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

- **Pipeline steps** — `eval`, `build`, `check`, `effect` as guest
  executions; `push` as a builder-side engine operation
  (spec-pipeline.md, Execution Environment).
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
- **Authority never rides with untrusted code.** Every sower
  credential — substitution, push, registration, signing — is held
  host-side, minted short-TTL and scoped, and exercised on the
  execution's behalf. Guests receive only the user secrets a step
  declares, injected as files.
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
| Host agent    | The builder-side service: VM lifecycle, vsock services, secret injection, the work store.     |
| Guest runtime | The sower-owned service inside every image that receives the command and mediates I/O.        |
| Work store    | The host agent's separate Nix store for all execution I/O; the host system store stays clean. |
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
| network  | string   | yes      | `none` (default; no network device) or `full` — NIC presence, host-enforced.         |
| caches   | object[] | no       | Upstream caches the read proxy fronts for this execution; server-resolved.           |
| secrets  | object   | no       | Named user-secret material injected as files (see Security). Never logged/persisted. |
| paths    | string[] | no       | Work-store roots the read proxy serves this execution (closure allowlist).           |
| timeout  | string   | yes      | Per-attempt execution deadline.                                                      |

The host never templates or interprets `command` and `payload` — it
execs one and delivers the other, exactly once, per the item context
convention (spec-pipeline.md). The pipeline engine, not the builder,
resolves step kinds to commands: `eval` becomes the stock runtime's
eval program; a `check` becomes the built app's executable. Arbitrary
*commands* are excluded at pipeline validation, not here — a definition
may only name executables built from the pinned source, while the
builder contract stays deliberately mechanism, not policy. Commands are
customized through three channels: static `args`, static `env`, and the
structured payload on stdin; anything richer is Nix — wrap the program
and bake the configuration into the derivation.

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

Transport between host agent and guest runtime is vsock, carrying
three services: the control channel (command delivery, events, exit),
the read proxy, and the write endpoint (see Nix Store Strategy). The
guest runtime forwards localhost HTTP to the latter two, so unmodified
nix inside the guest sees an ordinary substituter and upload target.
The command's own I/O convention is unchanged from the pipeline spec:
payload as JSON on stdin, stdout and stderr captured as the step log.
Programs that emit items (eval; later, checks enriching items) write
JSON lines to a runtime-provided descriptor, which the runtime forwards
as `item` events — application stdout stays log, never protocol.

The guest runtime receives the command over vsock after boot, injects
nothing into its environment beyond `command.env`, and reports exit
status. VMs are ephemeral: booted per execution, destroyed after,
nothing surviving but exported paths and the event stream.

## Nix Store Strategy

The execution layer never touches the builder host's own store. All
execution I/O flows through the **work store** — a separate Nix store
at its own root, owned by the host agent — so the host system's closure
contains exactly what the operator deployed and never a guest-produced
path. Wiping the work store must never break the builder host.

- **Ingress: substitution through the read proxy.** Guests have no
  network device by default. The guest runtime forwards localhost HTTP
  to host-side vsock services, so unmodified nix inside the guest sees
  an ordinary substituter: the read proxy serves the execution's
  declared work-store roots first and its resolved upstream caches on
  miss, caching fetches in the work store (LRU, size-limited — the
  ncps shape). Upstream credentials live in the proxy, never in the
  guest. The guest builds in its own scratch store; inputs are copied
  in once per miss and are warm for every later guest on that builder.
- **Egress: `nix copy` to the write endpoint.** A producing program
  copies the closures it wants to persist to the host agent's write
  endpoint — plain binary-cache protocol over the same vsock. The
  agent imports into the work store under run-scoped gcroots and emits
  the `paths` event. What a program does not copy out does not exist
  after the VM dies, so egress naming needs no separate mechanism.
- **Boot images** are read from where they legitimately live: stock and
  environment images are registered seeds staged through the builder's
  own subscription — operator-governed, subscription-pinned, in the
  host store like any staged seed. Ephemeral merge-run images are work
  products and live in the work store like any other.
- **Sharing between builders** happens at the cache layer: a builder's
  work store may be fronted to peers through the same proxy protocol,
  or several builders may share an upstream caching proxy. Work stores
  are never shared filesystems — nix local stores are single-writer.
- **Fixed-output derivations** under the default no-network policy must
  substitute from the proxy or fail, consistent with sources-are-inputs
  (spec-pipeline.md, Repository Input). `full` network exists for the
  checks and effects that genuinely reach out.

Run gcroots release when the run closes; the LRU governs retention
beyond that, and the cache remains the durable artifact layer. Storage
is not endorsement — whether a work-store path may be activated
anywhere is the signing layer's question (spec-seed-trust.md).

## Dispatch

The server owns a queue of executions and assigns each to a connected
builder matching `system` with a free slot and sufficient memory,
over the garden channel — the same discipline as deployment dispatch.
Not everything dispatched boots a VM: builder-side engine operations —
`push`, uploading from the work store with the scheme-dispatched
backend client (`niks3://`, `attic://`, otherwise `nix copy`) and
host-held credentials — ride the same queue and channel without a
guest.

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

- **Network policy is NIC presence.** Guests default to no network
  device at all — substitution and egress ride vsock, so `none` costs
  nothing. `full` attaches a device for checks and effects that reach
  out and currently grants unrestricted egress; an internet-only tier
  (special-use ranges blackholed, as spindle does) is a future
  expansion.
- **Secrets** are injected by the host agent at VM start as files under
  `/run/sower/secrets/<name>` on a tmpfs, and die with the VM. They
  arrive in the dispatch message over the channel's TLS, are never
  written to the builder's disk or logs, and never enter the image or
  any Nix store. Access decisions happened server-side (spec-pipeline.md,
  Secrets); the host mounts only what dispatch delivered.
- **Sower's own credentials never enter guests.** Upstream-cache auth
  lives in the read proxy; push and registration credentials are
  minted short-TTL and scoped to the host agent and server, which
  authenticate on the execution's behalf. The quarantine-cache
  redirection for untrusted runs happens at minting; the builder is
  indifferent.
- **Host-side push is bounded by minting and by the trust model.** A
  push operation uploads exactly the server-named paths from the work
  store, with a credential minted for that operation — short-TTL,
  bound to the one cache resource the run's capability set selected.
  A compromised guest holds nothing; a compromised builder host can
  pollute the caches it was directed at, during the window, and
  nothing more — cache content is transport, never trust. Activation
  requires the signing layer's verification regardless of what any
  cache serves.
- **Backend clients are part of the builder closure.** The upload
  clients scheme dispatch selects among ship pinned in the builder
  host's own seed — operator-governed like the rest of the host
  closure, overridable in the builder's NixOS configuration, and never
  influenced by a run definition: repository-derived code executes
  only in guests. The builtin push serves registered cache resources;
  uploading anywhere else — a public cachix, mirrors, unsupported
  backends — is an `effect` in a guest with the user's own secret,
  which is its correct owner.
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
real cloud-hypervisor builders inside its incus VMs under nested KVM —
an accepted infrastructure assumption. There is no degraded or
container-backed builder mode.

## Phasing

1. **Builder role + generic executions.** Capability advertisement,
   dispatch, event stream, stock image with eval and build guest
   programs, the work store, and the vsock read/write services.
   Unblocks sow-221.
2. **Builder-side push, credential minting.** Backend upload clients
   on the host agent; scoped short-TTL credentials; quarantine
   redirection.
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
- **Commands are store-path executables with plain args.** The host
  execs what dispatch names and templates nothing. Excluding arbitrary
  *commands* is pipeline validation's job; static `args`/`env` and the
  stdin payload are the customization channels.
- **Structured output is a runtime channel, not stdout.** Items flow
  as JSONL over a runtime descriptor; application stdout stays log.
- **The work store is the only store executions touch.** The builder
  host's system store never holds a guest-produced path; wiping the
  work store never breaks the host. Sharing between builders happens
  at the cache layer, never as a shared filesystem.
- **Ingress and egress are the binary-cache protocol over vsock.**
  Guests substitute through the read proxy and `nix copy` results to
  the write endpoint; no NIC is involved, no bespoke NAR protocol
  exists, and what a program does not copy out does not persist.
- **Network modes are `none` and `full`.** Substitution needs no
  network — the proxy provides it — so `cache-only` disappears as a
  distinct mode; `full` means everything for now, internet-only
  blackholing later.
- **push is a builder-side engine operation.** No VM: the host agent
  uploads from the work store with the backend-specific client and
  host-held credentials. The builtin serves registered cache resources
  only; external publication is an `effect` with user credentials.
- **Backend clients are a pinned, operator-governed set.** They ship
  in the builder host closure; a run definition can never name a
  binary the host executes.
- **Storage is not endorsement.** Serving a guest-produced path says
  nothing about activation; that remains the signing layer's decision.
- **Executions are at-most-once.** Builder failure fails the
  execution; retry is memoized rerun at the client layer.
- **No sower authority in guests at all.** Proxies and host-side
  operations hold every sower credential — substitution, push,
  registration, signing; guests receive only declared user secrets.
- **Local mode stays.** `sower-build` runs in-process for dev and
  bootstrap; only the server-side path requires builders.
- **Cloud-hypervisor is the only execution backend.** No degraded or
  container-backed builder modes anywhere, tests included: e2e runs
  real cloud-hypervisor builders under nested KVM. Incus remains e2e
  scaffolding for gardens, never an execution backend.

## Open Questions

- **Secret transport.** User secrets ride the dispatch message today;
  is a pull-at-start flow (builder fetches sealed material when the VM
  boots) worth the extra round trip to shrink the window material
  exists outside the host's memory?
- **Capacity model.** Slots + memory budget vs. real bin-packing on
  cpus/memory; whether eval's memory ceilings need reflecting in
  advertisement. Spindle's per-image budgets with work-conserving fair
  allocation are prior art.
- **Work-store sizing and eviction.** The LRU bound governs cached
  substitutions; whether run-gcrooted outputs count against it or get
  their own budget, and what backpressure looks like when a run's
  outputs alone exceed the store.
- **vsock details.** Framing and versioning of the control channel;
  whether the guest contract marker also states the vsock protocol
  range or the marker version covers both.
