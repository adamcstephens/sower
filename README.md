# Sower

Sower is a deployment and lifecycle management tool for Nix based configurations, including NixOS and Home-Manager.

With sower we sow the seeds of our systems.

- A seed is an extra bundle of metadata for an artifact path, e.g. a Nix store path.
- Seed metadata includes a set of tags, with git and user-provided tags.
- A garden defines seeds they want to subscribe to.
- Seeds are submitted to a server to be used for deployments.

**WARNING**
This project is experimental and is not recommended for production installation.
One of the goals is never break deployments, but it is **not guaranteed yet**.
I'm only using this in a homelab with approximately a dozen gardens.
This means the risk to me of breaking deployments is moderately low.

I'd love for others to get value out of what I'm building here.
Please reach out if you're a user, I want to chat. :)

## Installation

Read the NixOS modules for the server and the garden. There is an example in nix/tests/e2e.nix

1. An example server config exists in nix/tests/e2e.nix
2. An example garden config is below.

Good luck, everyone's counting on you.

## Components

- Server including Phoenix LiveView web interface.
- Always-on end-system daemon (Garden) with bi-directional communication to the Server over real-time WebSocket connection.
- Activator used by the Garden for running limited, specific actions as root, over a systemd initiated socket; also accepts one-shot activation requests over stdio.
- CLI for building and submitting seeds, garden-managed deployment, and explicit sudo recovery deployment.

Normal `sower deploy` requests `activate` by default. Use `--action stage` to
stage only, or `--action restart` to request a restart without `--override`.
The garden's `direct` policy must permit the exact requested action, including
its windows and confirmation requirements; the server rejects a disallowed
action rather than choosing another. The garden still applies its local policy
when executing the deployment.

Use `--override --action restart --reason "emergency recovery"` to bypass deployment
policy on both the server and garden. Override permission is required, and the
action and reason are recorded in the deployment audit trail. Overrides still
enforce supported seed actions, activator privileges, and activation failure checks.
The garden must be connected and advertise override support; otherwise the server
rejects the request with an upgrade-required error. Ordinary deployments remain
available during upgrades.

To deploy without a working garden or activator socket, use
`sower deploy .#worker3 --copy-to ssh://worker3 --sudo`. The CLI copies the closure,
then runs the target's existing `sower activator` as root over SSH. Sudo prompts
are passed through to your terminal. If `sower` is absent, the target downloads
the server-provided static binary from
`https://<endpoint>/client/bin/<target-system>` using the configured endpoint
(`--endpoint`, `SOWER_ENDPOINT`, or client config). Binary fallback supports
`x86_64-linux` and `aarch64-linux` and requires HTTPS and `curl` on the target.
SSH activation requires Bash and sudo on the target.

`--sudo` supports NixOS (`switch`) and home-manager activation as root, requires
an `ssh://` or `ssh-ng://` copy destination, and does not use server authentication,
garden policy, or deployment reporting. It cannot be combined with server-only
options such as `--seed`, `--to`, `--action`, or `--override`. Activation success
does not confirm garden health or resolve an already-pending server deployment.
Without `--sudo`, `--copy-to` remains transfer-only and the garden performs activation.

### Gardens

Gardens are an always on client, which have full control over what the seeds from the server can or will do.
Through the garden's configuration, you can determine what the garden should subscribe to and what should happen when working with seeds for deployment.

#### Subscriptions

Subscriptions are the main controls for how systems are deployed. They include:

- A set of seed tag matching rules
- Schedule in cron format for pull-based deployments
- A `policy` controlling which deployment actions are permitted, and when

#### Policy

Each subscription carries a `policy` map of named rules. Each rule permits a set
of `actions` (`stage`, `activate`, `restart`) for a set of `triggers` (`manual`,
`scheduled`, `realtime`, `poll_on_connect`), optionally constrained to a time
`window`. Multiple rules are OR-ed; the highest-disruption permitted action
wins. See `docs/spec-deployment-policy.md` for the full specification.

#### Example garden config

```nix
{
  age.secrets.sower-api-token = {
    file = cfg.access_token_secret;
    owner = "sower-garden";
  };

  services.sower = {
    activator = {
      package = inputs.sower-next.packages.${pkgs.stdenv.hostPlatform.system}.activator;
      allowedGroups = [ "users" ];
    };

    garden = {
      enable = true;
      accessTokenFile = config.age.secrets.sower-api-token.path;
      package = inputs.sower-next.packages.${pkgs.stdenv.hostPlatform.system}.garden;

      settings = {
        access_token_file = config.age.secrets.sower-api-token.path;
        endpoint = "http://localhost:7150";

        subscriptions = {
          ${config.networking.hostName} = {
            seed_name = config.networking.hostName;
            seed_type = "nixos";
            rules = [ "git_branch=main" ];
            # https://hexdocs.pm/crontab/cron_notation.html
            schedule = "0 3 * * *";
            timezone = "America/New_York";

            policy = {
              # Allow manual activations anytime.
              manual = {
                actions = [ "activate" ];
                triggers = [ "manual" ];
              };
              # Scheduled / poll-on-connect deploys may stage, activate, and
              # reboot — but only inside the maintenance window.
              maintenance = {
                actions = [ "stage" "activate" "restart" ];
                triggers = [ "scheduled" "poll_on_connect" ];
                window = {
                  time_start = "02:00";
                  time_end = "04:00";
                };
              };
            };
          };
        };
      };
    };
  };

  users.users.adam.extraGroups = [ "sower-activator" ];
};
```

## Disclaimer

This project uses coding agents for assisting and producing code.
