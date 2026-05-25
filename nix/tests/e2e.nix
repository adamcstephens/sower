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
  gardenPkg = flake.packages.${system}.garden;
  activatorPkg = flake.packages.${system}.activator;
  cliPkg = flake.packages.${system}.cli;
  serverPkg = flake.packages.${system}.server;

  hmGardenStateDir = "/home/testuser/.local/state/sower-garden";

  # Admin wrapper for home-manager garden RPC (must match the RELEASE_NODE
  # set by the home-manager module).
  hmGardenAdmin = pkgs.writeShellApplication {
    name = "sower-hm-garden";
    text = ''
      export RELEASE_MODE="interactive"
      export RELEASE_NODE="sower-garden-hm"
      export SHELL="${lib.getExe pkgs.bash}"
      RELEASE_COOKIE=$(cat ${hmGardenStateDir}/release-cookie)
      export RELEASE_COOKIE
      exec ${lib.getExe gardenPkg} "$@"
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
            hmGardenAdmin
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

            garden = {
              enable = true;
              package = gardenPkg;
              # the test drives ad-hoc deploys via `sower-garden rpc ...`
              distribution = true;

              settings = {
                access_token_file = "/run/sower/test_token";
                endpoint = "http://localhost:4000";
                subscriptions = {
                  server = {
                    seed_name = "server";
                    seed_type = "nixos";
                  };
                };
              };
            };
          };
          # if garden fails to start, fail immediately
          systemd.services.sower-garden.serviceConfig.Restart = "no";

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

            services.sower.garden = {
              enable = true;
              package = gardenPkg;
              activatorPackage = activatorPkg;
              accessTokenFile = "/run/sower/test_token";
              # the test drives ad-hoc deploys via `sower-hm-garden rpc ...`
              distribution = true;

              settings = {
                endpoint = "http://localhost:4000";
                subscriptions = {
                  testuser = {
                    seed_name = "testuser";
                    seed_type = "home-manager";
                    rules = [
                      {
                        key = "username";
                        value = "testuser";
                        op = "eq";
                      }
                    ];
                  };
                };
              };
            };
          };

          # Test overrides for home-manager garden
          home-manager.users.testuser.systemd.user.services.sower-garden.Service = {
            Restart = lib.mkForce "no";
          };

          # Second HM user exercises the signal-driven lifecycle with
          # distribution disabled (module default).
          users.users.nodist-user = {
            isNormalUser = true;
          };

          home-manager.users.nodist-user = {
            imports = [ ../home/module.nix ];

            home.stateVersion = "24.11";

            services.sower.garden = {
              enable = true;
              package = gardenPkg;
              activatorPackage = activatorPkg;
              accessTokenFile = "/run/sower/test_token";

              settings = {
                endpoint = "http://localhost:4000";
              };
            };
          };

          home-manager.users.nodist-user.systemd.user.services.sower-garden.Service = {
            Restart = lib.mkForce "no";
          };

          virtualisation.diskSize = 4096;
        };

      };

    # Second NixOS host runs only the system garden module with the
    # default distribution=false, so the no-distribution path is exercised
    # for the system service (different state dir, hardening, and unit
    # config than the home-manager case).
    client =
      { ... }:
      {
        imports = [
          ../nixos/module.nix
        ];

        config = {
          boot.loader.grub.enable = false;

          services.sower = {
            activator.package = activatorPkg;

            garden = {
              enable = true;
              package = gardenPkg;
              # endpoint/access_token are required by config validation;
              # this VM never actually reaches a server, the lifecycle test
              # only cares that the BEAM starts and answers signals.
              settings = {
                endpoint = "http://localhost:1";
                access_token = "dummy";
              };
            };
          };
          # if garden fails to start, fail immediately
          systemd.services.sower-garden.serviceConfig.Restart = "no";
        };
      };
  };

  testScript = # python
    ''
      start_all()
      server.wait_for_unit("postgresql.service")
      server.wait_for_unit("sower.service")
      server.wait_for_unit("sower-activator.socket")
      server.wait_for_unit("sower-garden.service")
      server.wait_for_open_port(4000)

      with subtest("activator socket activation"):
          server.succeed("test -S /run/sower-activator/activator.sock")
          server.succeed("test \"$(stat -c '%a' /run/sower-activator/activator.sock)\" = 660")
          server.succeed("test \"$(stat -c '%G' /run/sower-activator/activator.sock)\" = sower-activator")

      with subtest("get client token"):
          token = server.succeed("cat /run/sower/test_token")
          server.succeed("mkdir -p /run/sower")
          server.succeed(f"echo -n {token} > /run/sower/test_token")

      with subtest("nixos garden registration"):
          server.wait_until_succeeds(
              "journalctl --no-pager -u sower-garden"
              " --grep='Joined channel topic'",
              timeout=15,
          )

      with subtest("basic cli submission and activation"):
          server_profile = server.succeed("readlink -f /run/booted-system").strip()
          server.succeed(f"sower seed submit --name server --type nixos --artifact {server_profile} --debug")
          server.succeed("sower seed upgrade --name server --type nixos --debug")

      with subtest("nixos garden deployment"):
          server.wait_until_succeeds('sower-garden rpc "Garden.Admin.deploy(\\\"nixos\\\")"', timeout=15)
          server.wait_until_succeeds(
              "journalctl --no-pager -u sower-garden"
              " --grep='Completed.activation'",
              timeout=15,
          )

      with subtest("activator handled nixos request"):
          server.succeed(
              "journalctl --no-pager -u 'sower-activator@*'"
              " --grep='Received request.*type=nixos'"
          )

      with subtest("start home-manager garden"):
          server.wait_for_unit("home-manager-testuser.service")
          server.succeed("loginctl enable-linger testuser")
          # HM activation ran before user manager was up, so reload and start manually
          server.systemctl("daemon-reload", "testuser")
          server.systemctl("start sower-garden.service", "testuser")
          server.wait_for_unit("sower-garden.service", "testuser")

      with subtest("home-manager garden registration"):
          server.wait_until_succeeds(
              "su -l testuser -c '"
              "journalctl --user --no-pager -u sower-garden"
              " --grep=Joined.channel.topic'",
              timeout=15,
          )

      with subtest("home-manager garden deployment"):
          hm_generation = server.succeed(
              "readlink -f /home/testuser/.local/state/home-manager/gcroots/current-home"
          ).strip()
          server.succeed(
              f"sower seed submit --name testuser --type home-manager"
              f" --artifact {hm_generation}"
              f" --tag username=testuser"
          )
          server.succeed(
              'sower-hm-garden rpc "Garden.Admin.deploy(\\\"home-manager\\\")"'
          )
          server.wait_until_succeeds(
              "su -l testuser -c '"
              "journalctl --user --no-pager -u sower-garden"
              " --grep=Completed.activation'",
              timeout=15,
          )

      def assert_lifecycle(machine, unit, user=None):
          ctl = f"systemctl --machine={user}@.host --user" if user else "systemctl"
          if user:
              grep_prefix = (
                  f"su -l {user} -c '"
                  f"journalctl --user --no-pager -u {unit}"
              )
              grep_suffix = "'"
          else:
              grep_prefix = f"journalctl --no-pager -u {unit}"
              grep_suffix = ""

          # systemctl reload sends SIGHUP; Garden.SignalHandler logs receipt
          # and Garden.Socket triggers an in-app self-restart via busctl,
          # which cycles the BEAM. Verify both the signal log and that the
          # MainPID actually changed and the unit ended back up active.
          before = machine.succeed("date -u +%s").strip()
          pid_before = machine.succeed(f"{ctl} show -p MainPID --value {unit}").strip()
          machine.systemctl(f"reload {unit}", user)
          machine.wait_until_succeeds(
              f"{grep_prefix} --since=@{before} --grep=Received.SIGHUP{grep_suffix}",
              timeout=10,
          )
          machine.wait_until_succeeds(
              f"[ \"$({ctl} show -p MainPID --value {unit})\" != \"{pid_before}\" ]"
              f" && [ \"$({ctl} is-active {unit})\" = active ]",
              timeout=20,
          )

          # systemctl restart cycles the unit cleanly.
          machine.systemctl(f"restart {unit}", user)
          machine.wait_for_unit(unit, user)

          # systemctl stop sends SIGTERM; BEAM shuts down before SIGKILL fallback.
          machine.systemctl(f"stop {unit}", user)
          status, _ = machine.systemctl(f"is-active {unit}", user)
          assert status != 0, f"{unit} still active after stop (user={user})"

      with subtest("nixos signal-driven lifecycle (distribution off)"):
          client.wait_for_unit("sower-garden.service")
          assert_lifecycle(client, "sower-garden.service")

      with subtest("home-manager signal-driven lifecycle (distribution off)"):
          server.succeed("loginctl enable-linger nodist-user")
          server.systemctl("daemon-reload", "nodist-user")
          server.systemctl("start sower-garden.service", "nodist-user")
          server.wait_for_unit("sower-garden.service", "nodist-user")
          assert_lifecycle(server, "sower-garden.service", "nodist-user")

      with subtest("home-manager signal-driven lifecycle (distribution on)"):
          # testuser's garden is still running from prior subtests.
          assert_lifecycle(server, "sower-garden.service", "testuser")

      with subtest("nixos signal-driven lifecycle (distribution on)"):
          # system garden on server has distribution=true; run last because
          # the stop call leaves it inactive.
          assert_lifecycle(server, "sower-garden.service")

    '';
}
