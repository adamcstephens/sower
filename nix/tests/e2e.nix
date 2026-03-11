# Debug like this:
# $ nix run .#checks.x86_64-linux.nixos-test.driverInteractive
# >>> start_all()
# >>> machine.shell_interact()
{
  flake,
  pkgs,
  testers,
}:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;

  npins = import ./npins;

  simple-service = flake.packages.${system}.tests-simple-service;
  agentPkg = flake.packages.${system}.agent;
  activatorPkg = flake.packages.${system}.activator;
  cliPkg = flake.packages.${system}.cli;
  serverPkg = flake.packages.${system}.server;

  hmAgentStateDir = "/home/testuser/.local/state/sower-agent";

  # Admin wrapper for home-manager agent RPC (must match RELEASE_NODE override)
  hmAgentAdmin = pkgs.writeShellApplication {
    name = "sower-hm-agent";
    text = ''
      export RELEASE_MODE="interactive"
      export RELEASE_NODE="sower_agent_hm"
      export SHELL="${lib.getExe pkgs.bash}"
      RELEASE_COOKIE=$(cat ${hmAgentStateDir}/release-cookie)
      export RELEASE_COOKIE
      exec ${lib.getExe agentPkg} "$@"
    '';
  };
in
testers.runNixOSTest {
  name = "sower";

  nodes = {
    server =
      {
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          ../nixos/module.nix
          "${npins.home-manager}/nixos"
        ];

        config = {
          # need switch-to-configuration
          system.switch.enable = true;
          # without trying to install grub
          boot.loader.grub.enable = false;

          # expose more paths to test vm
          virtualisation.additionalPaths = [
            simple-service
          ];

          environment.systemPackages = [
            cliPkg
            hmAgentAdmin
            pkgs.python3
          ];

          networking.firewall.allowedTCPPorts = [ 4000 ];

          nix.settings = {
            experimental-features = "flakes nix-command";
            substituters = lib.mkForce [ ];
            hashed-mirrors = null;
            connect-timeout = 1;
          };

          services.sower = {
            activator.package = activatorPkg;

            agent = {
              enable = true;
              package = agentPkg;

              settings = {
                access_token_file = "/run/sower/test_token";
                endpoint = "http://localhost:4000";
                subscriptions = [
                  {
                    seed_name = "server";
                    seed_type = "nixos";
                  }
                ];
              };
            };
          };
          # if agent fails to start, fail immediately
          systemd.services.sower-agent.serviceConfig.Restart = "no";

          services.sower.server = {
            enable = true;
            package = serverPkg;
            initSecrets = true;
            e2eTest = true;

            settings = {
              listen_address = "0.0.0.0";
              public_url = "http://server:4000";

              database = {
                socket = "/run/postgresql/.s.PGSQL.5432";
                username = "sower";
                database = "sower";
                encryption_key_file = "${pkgs.writeText "database-encryption-key" "b2s="}"; # ok in b64
              };

              log_level = "debug";

              clients."${system}".path = builtins.toString cliPkg;
            };
          };
          # if server fails to start, fail immediately
          systemd.services.sower.serviceConfig.Restart = "no";

          services.postgresql = {
            enable = true;

            initialScript = pkgs.writeText "sower-pg-init" ''
              CREATE USER sower;
              CREATE DATABASE sower OWNER sower;
            '';
          };

          # Home-manager test user
          users.users.testuser = {
            isNormalUser = true;
          };

          home-manager.users.testuser = {
            imports = [ ../home/module.nix ];

            home.stateVersion = "24.11";

            services.sower.agent = {
              enable = true;
              package = agentPkg;
              activatorPackage = activatorPkg;
              accessTokenFile = "/run/sower/test_token";

              settings = {
                endpoint = "http://localhost:4000";
                subscriptions = [
                  {
                    seed_name = "testuser";
                    seed_type = "home-manager";
                    rules = [
                      {
                        key = "username";
                        value = "testuser";
                        op = "eq";
                      }
                    ];
                  }
                ];
              };
            };
          };

          # Test overrides for home-manager agent
          home-manager.users.testuser.systemd.user.services.sower-agent.Service = {
            Restart = lib.mkForce "no";
            # Avoid Erlang node name clash with system-level agent
            Environment = lib.mkAfter [ "RELEASE_NODE=sower_agent_hm" ];
          };

          virtualisation.diskSize = 4096;
        };

      };
  };

  testScript = # python
    ''
      start_all()
      server.wait_for_unit("postgresql.service")
      server.wait_for_unit("sower.service")
      server.wait_for_unit("sower-activator.socket")
      server.wait_for_unit("sower-agent.service")
      server.wait_for_open_port(4000)

      with subtest("activator socket activation"):
          server.succeed("test -S /run/sower-activator/activator.sock")
          server.succeed("test \"$(stat -c '%a' /run/sower-activator/activator.sock)\" = 660")
          server.succeed("test \"$(stat -c '%G' /run/sower-activator/activator.sock)\" = sower-activator")

      with subtest("get client token"):
          token = server.succeed("cat /run/sower/test_token")
          server.succeed("mkdir -p /run/sower")
          server.succeed(f"echo -n {token} > /run/sower/test_token")

      with subtest("nixos agent registration"):
          server.wait_until_succeeds(
              "journalctl --no-pager -u sower-agent"
              " --grep='Joined channel topic'",
              timeout=15,
          )

      with subtest("basic cli submission and activation"):
          server_profile = server.succeed("readlink -f /run/booted-system").strip()
          server.succeed(f"sower seed submit --name server --type nixos --artifact {server_profile} --debug")
          server.succeed("sower seed upgrade --name server --type nixos --debug")

      with subtest("nixos agent deployment"):
          server.succeed('sower-agent rpc "SowerAgent.Admin.deploy(\\\"nixos\\\")"')
          server.wait_until_succeeds(
              "journalctl --no-pager -u sower-agent"
              " --grep='Completed.activation'",
              timeout=15,
          )

      with subtest("start home-manager agent"):
          server.wait_for_unit("home-manager-testuser.service")
          server.succeed("loginctl enable-linger testuser")
          # HM activation ran before user manager was up, so reload and start manually
          server.wait_until_succeeds(
              "systemctl --user -M testuser@ daemon-reload",
              timeout=15,
          )
          server.succeed("systemctl --user -M testuser@ start sower-agent.service")
          server.wait_until_succeeds(
              "systemctl --user -M testuser@ is-active sower-agent.service",
              timeout=15,
          )

      with subtest("home-manager agent registration"):
          server.wait_until_succeeds(
              "su -l testuser -c '"
              "journalctl --user --no-pager -u sower-agent"
              " --grep=Joined.channel.topic'",
              timeout=15,
          )

      with subtest("home-manager agent deployment"):
          hm_generation = server.succeed(
              "readlink -f /home/testuser/.local/state/home-manager/gcroots/current-home"
          ).strip()
          server.succeed(
              f"sower seed submit --name testuser --type home-manager"
              f" --artifact {hm_generation}"
              f" --tag username=testuser"
          )
          server.succeed(
              'sower-hm-agent rpc "SowerAgent.Admin.deploy(\\\"home-manager\\\")"'
          )
          server.wait_until_succeeds(
              "su -l testuser -c '"
              "journalctl --user --no-pager -u sower-agent"
              " --grep=Completed.activation'",
              timeout=15,
          )
    '';
}
