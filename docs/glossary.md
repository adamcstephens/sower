# Glossary

Terms used in Sower's code, configuration, CLI, and design documents.
The current contracts take precedence where older specifications differ.
The pipeline and trust sections describe design vocabulary, not a claim that
those systems are implemented. Local VM execution is distinguished from the
broader builder design.

## Components

| Term | Meaning |
| ---- | ------- |
| **Sower** | The project as a whole: deployment and lifecycle management for Nix-based configurations. Also the name of the `sower` CLI and the server's Elixir application. |
| **Server** | The central service that stores seeds and gardens, orchestrates deployments, and provides the HTTP API and Phoenix LiveView web interface. |
| **Garden** | The always-on client daemon on a managed system, and its registered identity on the server. It connects outward to the server over WebSocket, reports local state, and manages deployments under local configuration and policy. |
| **Activator** | The constrained privilege boundary used for activation and explicitly enabled VM network setup. It accepts requests through a systemd-activated socket or one-shot stdio; it is not a general-purpose root shell. The Rust implementation is `sower activator`. |
| **CLI** | The `sower` command-line interface. Most commands are implemented in Rust; `sower build` forwards to the Elixir build CLI, also available as `sower-build`. |
| **SowerClient / `sower_client`** | The shared Elixir application defining communication schemas and client helpers used by the server, gardens, and Elixir CLI. It is not another name for a garden daemon. |
| **Agent / field** | Historical names encountered in older tickets and migrations for what is now called a garden. In builder discussions, **host agent** specifically means the garden's unprivileged VM orchestration role. |

Sources: [project overview](../README.md#components),
[CLI entry point](../src/main.rs),
[shared schemas](../apps/sower_client/lib/sower_client.ex),
[builder role](spec-builder.md#builder-role).

## Seeds and Nix artifacts

| Term | Meaning |
| ---- | ------- |
| **Seed** | Metadata describing an installable artifact: a name, seed type, artifact path, and tags. A registered seed also has a server-assigned SID. The seed is not the artifact's bytes. |
| **Seed name** | The logical name used to select seeds, such as a host or configuration name. Multiple registered seeds can have the same name and type; use a SID to identify a particular record. |
| **Seed type / `seed_type`** | The discriminator for activation behavior. The current seed and manifest contracts accept `nixos`, `home-manager`, `nix-darwin`, and `service`. Not every type supports every deployment action. |
| **Artifact / `artifact`** | The deployable Nix store path described by a seed, such as a NixOS system toplevel or Home Manager activation package. For wrapper-backed seeds, this is the path inside the manifest, not the wrapper's output path. |
| **Tag** | A string key/value attached to a seed, used for metadata and subscription matching. Examples include `git_branch`, `system`, and `username`. Manifest tags are a JSON object; the seed API represents them as tag records. |
| **Seed manifest / `seed.json`** | A versioned JSON description of a built seed. Version 1 requires `version`, `name`, `seed_type`, `artifact`, and `tags`. It describes the artifact rather than embedding it. |
| **Seed wrapper / wrapper package** | A Nix package produced by `sower.lib.mkSeed` whose output directory contains `seed.json`. Its reference to the target artifact makes that artifact part of the wrapper's Nix closure. |
| **Canonical seed job / selector** | A wrapper-backed package attribute, such as `packages.<system>."nixos/myhost"`, `"home/alice"`, or `"seed/custom"`. In a flake selector such as `.#nixos/myhost`, the slash belongs to an attribute name; it does not mean nested Nix attributes. |
| **Store path** | An immutable path in the Nix store, normally `/nix/store/<hash>-<name>`. Paths identify both build recipes and built outputs; the distinction matters when deploying. |
| **Derivation / `drv_path`** | A Nix build recipe, stored as a `.drv` path. Building or realizing it produces output paths. A derivation is not itself the configuration to activate. |
| **Output path / `out_path`** | A path produced by a derivation. A seed wrapper's output contains the manifest; its target's output is the deployable artifact. |
| **Closure** | A store path together with all store paths it transitively references. Copying or pinning a closure preserves the dependencies needed to use the artifact. |
| **GC root / gcroot** | A reference that keeps store paths reachable to Nix's garbage collector. Staging pins an artifact's closure without activating it. Older policy documents also use `gcroot` as a seed type; it is not in the current seed-type enum. |
| **System** | A Nix platform identifier such as `x86_64-linux` or `aarch64-linux`, used in package attributes and seed metadata. It is not a garden's hostname. |

Sources: [seed contract](../apps/sower_client/lib/sower_client/seed.ex),
[manifest schema](../nix/seed-manifest.schema.json),
[seed wrapper helpers](../nix/sowerlib.nix),
[deploy selectors](../src/commands/deploy.rs).

## Build and publication

| Term | Meaning |
| ---- | ------- |
| **Flake reference** | A Nix source reference, optionally followed by `#<attribute>`, identifying what to evaluate or build. For example, `.#nixos/myhost` selects a package from the current flake. |
| **Evaluation / eval** | Evaluating Nix expressions to discover derivations and output paths. Evaluation alone does not build or deploy them. |
| **Build / realization** | Making a derivation's outputs available in a Nix store. Nix may build missing outputs or obtain them through substitution. |
| **Substitution** | Fetching already-built store paths from a substituter instead of building them locally. Destination substitution lets a receiving store fetch available paths itself during a copy. |
| **Binary cache / cache** | An artifact distribution service from which Nix can substitute store paths and to which build outputs can be uploaded. A cache is not the seed registry. |
| **Push** | Uploading built paths and their closures to a configured binary cache. This does not by itself register a seed or request a deployment. |
| **Seed registration / seed publication** | Submitting seed metadata to the server. In the local build sequence this follows evaluation, build, and push. Registration can trigger realtime subscription processing; it is not itself activation. |
| **Seed registry** | The server's collection of seed records and tags, queried to find deployment candidates. Artifact contents live in Nix stores and caches. |
| **Local build pipeline** | The existing `sower-build` sequence: `eval → build`, optionally followed by `push` and `seed`. This is distinct from the server-side pipeline design below. |

Sources: [local build orchestration](../apps/sower_cli/lib/sower_cli/build.ex),
[direct deployment inputs and copying](../src/commands/deploy.rs),
[pipeline overview](spec-pipeline.md#overview).

## Subscriptions and deployment policy

| Term | Meaning |
| ---- | ------- |
| **Subscription** | A named garden configuration selecting seeds by `seed_name`, `seed_type`, and tag-matching `rules`, with an optional polling schedule, timezone, and deployment policy. The subscription name and seed name are separate fields. |
| **Matching rule / subscription rule** | A filter deciding which seeds qualify for a subscription. Current structured rules compare a tag's key and value with the `eq` operator; configuration also accepts forms such as `git_branch=main`. These rules select seeds, not deployment permissions. |
| **Policy / deployment policy** | Named permission rules deciding which deployment action is allowed for a trigger and time. Normal evaluation selects the highest-disruption supported action with a matching rule: `restart > activate > stage`. No match denies deployment. In the current evaluator, an absent or empty policy uses a built-in activate policy for `manual`, `scheduled`, and `poll_on_connect`. |
| **Policy rule** | An entry in a subscription's `policy` map, keyed by a human-readable name. It grants `actions`, optionally limited by `triggers`, a `window`, and `confirm`. Matching rules are alternatives; they are not an ordered allow/deny list. |
| **Stage / `stage`** | Download and pin an artifact's closure without changing the running configuration. This is a deployment action, not a pipeline phase. |
| **Activate / `activate`** | Apply a seed through its type-specific activation mechanism. This can change services or a user's environment without requesting a full machine reboot. |
| **Restart / `restart`** | The highest-disruption deployment policy action: a full machine restart. Supported for `nixos` and `nix-darwin`, not `home-manager` or `service`. A service's activation may restart that service without using this machine-restart action. |
| **Trigger** | The policy category describing how deployment was initiated: currently `manual`, `scheduled`, `realtime`, `poll_on_connect`, or `direct`. It is distinct from an audit reason and from a pipeline run's trigger. |
| **Manual** | A user-initiated subscription deployment, including a retry. It does not mean policy is bypassed. |
| **Scheduled** | Deployment processing initiated by a subscription's cron polling schedule. |
| **Realtime** | Deployment processing initiated when a newly registered seed matches a subscription. It does not mean the garden must activate immediately regardless of policy. |
| **Poll on connect / `poll_on_connect`** | Deployment processing when a garden connects and checks for pending seeds, rather than waiting for the next scheduled poll. |
| **Schedule** | The cron expression determining when to poll for seeds. It does not grant permission to activate what the poll finds. |
| **Window / maintenance window** | A policy rule's allowed days and time interval, evaluated in the subscription's timezone. Windows can cross midnight; the day refers to when the window opens. A window constrains permission, not polling. |
| **Confirmation / `confirm`** | A policy rule requirement that causes evaluation to return a confirmation-required outcome rather than unconditional permission. |
| **Activation mode** | The concrete mechanism chosen to carry out an allowed action, not the action itself. For NixOS, `switch` applies a configuration now; `boot` selects the next boot configuration and is paired with reboot for a restart deployment. |

Sources: [subscription contract](../apps/sower_client/lib/sower_client/orchestration/subscription.ex),
[matching-rule configuration](../apps/sower_client/lib/sower_client/subscription_rule_format.ex),
[current policy evaluator](../apps/sower_client/lib/sower_client/orchestration/subscription/policy.ex),
[activation-mode design](spec-deployment-policy.md#activation-mode-derivation).

## Deployment records and local state

| Term | Meaning |
| ---- | ------- |
| **Deployment** | An orchestrated request to apply one or more seeds to a garden, with an identity, progress, and result. It is an operation, not a seed or a Nix profile generation. |
| **Seed deployment** | The per-seed part of a deployment, carrying the seed, an optional subscription association, and the authorized action. |
| **Direct deployment** | Deploying a specific seed to a specific garden through the HTTP API rather than having a subscription select it. It uses the `direct` policy trigger and does not inherently bypass policy. `sower deploy` can build or register the seed first. |
| **Force / `--force`** | Requesting deployment even if an identical closure was previously deployed. This is not permission to bypass deployment policy. |
| **Override / `--override`** | An explicitly authorized break-glass direct deployment that bypasses deployment policy on server and garden. It requires override permission, an explicit action, an audit reason, and garden support. Seed/action support and activator privileges still apply. |
| **Sudo recovery deployment / `sower deploy --sudo`** | Copying and activating over SSH with interactive sudo, without garden/server deployment orchestration. This creates no server deployment record and is separate from a server-authorized policy override. |
| **Deployment event / audit reason** | A record explaining who initiated a deployment and why. For example, `user_triggered` and `user_retry` both map to the `manual` policy trigger; the distinct reasons remain useful for audit. |
| **Profile / Nix profile** | A stable local profile path, such as `/nix/var/nix/profiles/system`, with a history of numbered generations pointing at store paths. Gardens report profiles and their generations. |
| **Generation / seed generation** | A numbered entry in a local Nix profile's history, with its store path, link, creation time, and current flag. It is not a seed version number or a deployment attempt count. |
| **Current generation** | The generation marked current in a garden's profile report. A current profile, the running system, and the configuration used at last boot can differ; do not infer one from a deployment's success alone. |

Sources: [deployment contract](../apps/sower_client/lib/sower_client/orchestration/deployment.ex),
[seed deployment contract](../apps/sower_client/lib/sower_client/orchestration/seed_deployment.ex),
[direct deployment contract](../apps/sower_client/lib/sower_client/orchestration/direct_deployment.ex),
[CLI deployment modes](../src/commands/deploy.rs),
[profile report](../apps/sower_client/lib/sower_client/orchestration/garden_seed_profile.ex),
[generation report](../apps/sower_client/lib/sower_client/orchestration/garden_seed_generation.ex).

## Identity and access

| Term | Meaning |
| ---- | ------- |
| **SID / `sid`** | A public identifier used to address a particular server resource, for example a garden or seed. It is distinct from a resource's human-readable name and the database's internal ID. |
| **Organization / org** | The server's resource ownership and scoping boundary, represented by `org_id`. The trust design uses **tenant** when discussing the corresponding authorization boundary. |
| **API access token** | A user-associated credential with an expiry, organization, and explicit permissions, such as `seed:write` or `deployment:write`. It is distinct from a garden's OAuth client identity. |
| **Registration token** | A bootstrap credential authorized to register a garden. The garden submits its name and public key and receives an OAuth client identity; normal garden authentication uses that identity rather than the bootstrap token. |
| **OAuth client ID / `client_id`** | The Boruta-issued identity associated with a registered garden. It identifies the client; it is not the garden's private key or an access token. |
| **`private_key_jwt`** | Garden authentication using a short-lived JWT assertion signed with the garden's private RSA key to obtain an OAuth access token. The server receives the public key during registration. |
| **OAuth access token** | The token obtained through the garden's OAuth client-credentials flow and used for authenticated communication. It is distinct from the signed assertion used to request it. |
| **Contract / schema** | The agreed message shape between components, including types and enum values. `sower_client` registers shared schemas; server-pushed contracts must remain usable by gardens that have not upgraded yet. A VM's guest contract is a separate boundary. |

Sources: [access-token model](../apps/sower/lib/sower/accounts/access_token.ex),
[garden registration](../apps/sower_client/lib/sower_client/garden_registration.ex),
[OAuth identity reply](../apps/sower_client/lib/sower_client/auth/oauth_credentials.ex),
[garden authentication](../apps/garden/lib/garden/auth.ex),
[shared contract registration](../apps/sower_client/lib/sower_client.ex).

## Images and local VM execution

These terms apply to the Garden-local image execution code. That code is
documented as development orchestration, not a production sandbox. It does not
by itself establish the server-side builder dispatch system described below.

| Term | Meaning |
| ---- | ------- |
| **Image / `mkImage`** | A guest system built with `sower.lib.mkImage`, including boot artifacts and metadata. `Garden.Image` loads the image's `boot.json`, including kernel, initrd, root image, command line, and guest-contract information. |
| **Stock image** | The Sower-provided base execution image, as opposed to an operator-defined custom image. The builder design refers to it by the logical name `stock`. |
| **MicroVM / VM** | The virtual machine that boots an image and runs guest commands. It is not another registered garden. |
| **VMM / Cloud Hypervisor** | The host process providing the virtual machine. The `CloudHypervisor` Elixir application manages Cloud Hypervisor's process and API; Garden orchestrates image execution above it. |
| **Guest runtime / guest executor** | The Sower-owned program inside the VM that accepts commands and reports output and completion. The current executor is implemented in Rust. |
| **vsock** | The host–guest socket transport used for the guest command protocol. It does not require an ordinary guest network interface. |
| **Local execution / execution ID** | A Garden-managed image command lifecycle, addressable through `Garden.VM.Manager`. The manager admits work against capacity reservations and tracks status, cancellation, results, and cleanup. It is not a deployment SID or a pipeline run. |
| **Network lease** | Execution-scoped resources provisioned by the activator for networked VMs, including a routed TAP interface and host-enforced egress rules. `none` supplies no NIC; local `full` networking is still constrained, not unrestricted host access. |
| **Work store** | A separate host-agent-owned Nix store for execution inputs and outputs, distinct from the host system store. In the builder design, run-scoped GC roots preserve outputs across executions and the binary cache provides durable distribution. |

Sources: [local VM API and limitations](../apps/garden/lib/garden/vm.ex),
[image metadata](../apps/garden/lib/garden/image.ex),
[local admission manager](../apps/garden/lib/garden/vm/manager.ex),
[host–guest contract](spec-builder.md#hostguest-contract),
[work-store design](spec-builder.md#nix-store-strategy).

## Pipeline and builder design terminology

This section describes the [pipeline specification](spec-pipeline.md) and
[draft builder specification](spec-builder.md), not a list of available CLI
features or implemented server workflows.

| Term | Meaning |
| ---- | ------- |
| **Pipeline** | A named set of phases connected as a directed acyclic graph (DAG). It orchestrates build, checking, publication, and optionally rollout; it is not limited to deployment. |
| **Run** | One invocation of a pipeline, with pinned source and the resolved definition it executes. At the builder layer, a run is a client-scoped group of executions that shares placement and work-store roots. |
| **Phase** | An item source plus an ordered chain of steps applied to each item. Data-flow references establish dependencies; explicit `needs` adds ordering barriers. Do not call this a stage: `stage` is already a deployment action. |
| **Step** | One operation in a phase, such as `eval`, `build`, `push`, `seed`, `resolve`, `deploy`, `check`, or `effect`. |
| **Item** | A JSON document that flows through a phase's steps and accumulates fields, such as derivation paths, artifact paths, seed SIDs, and reports. It carries references and facts, not artifact contents. |
| **Reference / ref** | An address for a phase's output collection or an item in it, used to express data flow and dependencies. This is different from a Git ref or Nix flake reference. |
| **Eval-flavored pipeline** | A pipeline that starts from source evaluation and can build and publish new seeds. |
| **Resolve-flavored pipeline** | A pipeline that starts by matching garden subscriptions against existing seeds, without first evaluating source to produce seeds. Resolution selects candidates; deployment is a separate operation. |
| **Run context** | Server-supplied facts used when evaluating a definition, including pinned revision, source branch, trigger, run mode, and signature information. It contains no secrets and does not itself grant authority. |
| **Builder** | A garden with an advertised capability to execute isolated work for the server. It is a garden role, not a separate kind of fleet identity. |
| **Host agent** | The unprivileged builder role within the garden application, responsible for VM lifecycles, host–guest services, work-store access, and host-side credentials. The activator remains a separate privilege boundary. |
| **Execution** | One unit of builder work: image, command, payload, and resources producing an event stream and result. A pipeline step can cause an execution; the host need not understand that step's pipeline semantics. |
| **Dispatch** | Server-side assignment of queued work to an eligible builder. The design pins a run to one builder so its executions can share work-store outputs. |
| **Network endpoint** | An operator-approved address/protocol/port resource that an execution may request by reference. Requesting an endpoint does not grant access; authorization and host enforcement are separate. |
| **Image seed** | The proposed use of seed publication and stage-only subscriptions to distribute custom execution images. `image` is design vocabulary here, not a value accepted by the current seed manifest enum. |

Sources: [pipeline model](spec-pipeline.md#model),
[run context](spec-pipeline.md#run-context),
[steps](spec-pipeline.md#steps),
[builder model](spec-builder.md#model),
[dispatch](spec-builder.md#dispatch),
[network endpoint authorization](spec-builder.md#endpoint-references-and-authorization).

## Seed-trust design terminology

These terms come from the [draft seed-trust specification](spec-seed-trust.md).
They describe the intended security architecture, not guarantees provided by the
current activation path.

| Term | Meaning |
| ---- | ------- |
| **Operator** | The human authority controlling the fleet and pinning its trust roots and authorization policy independently of the server. |
| **Consumer garden** | A garden consuming and activating seeds, contrasted with a builder garden producing them. These describe roles, not separate registration mechanisms. |
| **Tenant** | The isolation scope for signing and activation authorization. A builder's authority is bounded to the tenants and targets permitted by operator policy. |
| **Trust anchor / issuer root** | An operator-pinned key or CA root used to verify signer identities. In this design the server may convey artifact paths but cannot replace the consumer's trust anchor. |
| **Issuer / STS** | The trusted credential-issuing service that authenticates builders and grants short-lived, scoped signing credentials. STS means security token service. |
| **Attestation / provenance** | Verifiable evidence linking an artifact to its builder identity and source, such as repository and pinned revision. Used to decide whether that builder and source are authorized for a target. |
| **Cache integrity** | Verification that artifact contents were not tampered with during distribution, using Nix signatures and trusted cache keys. This alone does not establish permission to activate that artifact on a particular garden. |
| **Activation authorization** | Verification that a signer, source, and artifact are permitted for a target under operator-owned policy. The design places enforcement in the activator, independently of server orchestration. |
| **Transparency log / trusted timestamp** | Evidence that a signature was made while its short-lived signing credential was valid, allowing later verification after the credential expires. |
| **Version floor** | An optional operator-controlled lower bound for accepted target versions, intended to prevent unauthorized downgrades. It is distinct from a local Nix profile generation number. |
| **TCB** | Trusted computing base: the components whose correctness is required for the security guarantee. The proposed runtime TCB includes operator roots, issuer, transparency log, and activator enforcement. |

Sources: [actors and threat model](spec-seed-trust.md#threat-model),
[operator-owned roots](spec-seed-trust.md#roots-of-trust-operator-owned-server-independent),
[verification layers](spec-seed-trust.md#two-distinct-verification-layers-do-not-conflate),
[trust decisions](spec-seed-trust.md#decisions-settled-in-discussion).
