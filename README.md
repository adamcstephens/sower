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
- Activator used by the Garden for running limited, specific actions as root, over a systemd initiated socket.
- CLI for submitting seeds including a full code to submitted builder.

### Gardens

Gardens are an always on client, which have full control over what the seeds from the server can or will do.
Through the garden's configuration, you can determine what the garden should subscribe to and what should happen when working with seeds for deployment.

#### Subscriptions

Subscriptions are the main controls for how systems are deployed. They include:

- A set of (currently primitive) seed tag matching rules
- Schedule in cron format for pull-based deployments
- Which deployment profile to use

#### Deployment Profiles

Controls for what happens when the deploy occurs.

- Arguments to pass to activation
- Rules about rebooting (NixOS seeds only)

#### Example garden config

```nix
{
  age.secrets.sower-next-api-token = {
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
      accessTokenFile = config.age.secrets.sower-next-api-token.path;
      package = inputs.sower-next.packages.${pkgs.stdenv.hostPlatform.system}.garden;

      settings = {
        access_token_file = config.age.secrets.sower-next-api-token.path;
        endpoint = "http://localhost:7150";

        deployment_profiles = {
          boot = {
            activation_args = [ "boot" ];
            reboot_policy = "when-required";
          };
          switch = {
            activation_args = [ "switch" ];
            reboot_policy = "never";
          };
        };

        subscriptions = [
          {
            seed_name = config.networking.hostName;
            seed_type = "nixos";
            rules = [ "git_branch=main" ];
            # https://hexdocs.pm/crontab/cron_notation.html
            schedule = "0 3";
            deployment_profile = "boot";
          }
        ];
      };
    };
  };

  users.users.adam.extraGroups = [ "sower-activator" ];
};
```

## Disclaimer

This project uses coding agents for assisting and producing code.
