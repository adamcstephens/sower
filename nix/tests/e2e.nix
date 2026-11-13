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
  system = pkgs.stdenv.hostPlatform.system;

  npins = import ./npins;

  simple-service = flake.packages.${system}.tests-simple-service;
  gardenPkg = flake.packages.${system}.garden;
  activatorPkg = flake.packages.${system}.activator;
  delayedActivatorPkg = pkgs.writeShellApplication {
    name = "sower";
    text = ''
      if [ "''${1-}" = activator ]; then
        ${pkgs.lib.getExe' pkgs.coreutils "sleep"} 2
      fi
      exec ${pkgs.lib.getExe activatorPkg} "$@"
    '';
  };
  serverPkg = flake.packages.${system}.server;

  # `sower` on PATH is the Rust CLI wrapped with the Elixir `sower-build` build
  # engine, so seed/garden commands run natively and `sower build` forwards.
  sowerPkg = flake.packages.${system}.sower;

  # Public test-only key: retain signature verification during garden downloads.
  cachePublicKey = "sower-e2e-cache:SqIMhQSUh14wpAZMTgOGBX5hd9233ZAF9TXSBYlRQdk=";
  cacheSecretKey = pkgs.writeText "sower-e2e-cache-secret" "sower-e2e-cache:H5DCkmI4YSh4uZ0vZS9dG0or5AYtvHgzmNsg5mzHmshKogyFBJSHXjCkBkxOA4YFfmF33bfdkAX1NdIFiVFB2Q==";
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

          systemd.services.epmd = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "simple";
              DynamicUser = true;
              ExecStart = "${pkgs.beamMinimal29Packages.erlang}/bin/epmd";
              ExecStartPost = pkgs.writeShellScript "wait-for-epmd" ''
                until ${pkgs.beamMinimal29Packages.erlang}/bin/epmd -names; do
                  ${pkgs.coreutils}/bin/sleep 0.05
                done
              '';
              TimeoutStartSec = 10;
              Restart = "on-failure";
            };
          };
          systemd.services.sower = {
            after = [ "epmd.service" ];
            wants = [ "epmd.service" ];
          };
          systemd.services.sower-garden = {
            after = [ "epmd.service" ];
            wants = [ "epmd.service" ];
          };
          systemd.services."user@" = {
            after = [ "epmd.service" ];
            wants = [ "epmd.service" ];
          };

          # expose more paths to test vm
          virtualisation.additionalPaths = [
            simple-service
          ];

          environment.systemPackages = [
            sowerPkg
            pkgs.python3
          ];

          networking.firewall.allowedTCPPorts = [ 4000 ];

          nix.settings = {
            experimental-features = [
              "flakes"
              "nix-command"
            ];
            substituters = lib.mkForce [ "http://builder:8080" ];
            trusted-public-keys = [ cachePublicKey ];
            hashed-mirrors = null;
            connect-timeout = 1;
          };

          services.sower = {
            activator.package = delayedActivatorPkg;

            garden = {
              enable = true;
              package = gardenPkg;
              # kept on to exercise the distribution-on lifecycle subtest;
              # deploys now go over the admin socket (sow-204 drops distribution).
              distribution = true;

              settings = {
                access_token_file = "/run/sower/test_token";
                endpoint = "http://localhost:4000";
                name = "server";
                policy = {
                  direct = {
                    actions = [
                      "activate"
                      "stage"
                    ];
                    triggers = [ "direct" ];
                  };
                };
                subscriptions = {
                  server = {
                    seed_name = "server";
                    seed_type = "nixos";
                    policy.manual = {
                      actions = [ "activate" ];
                      triggers = [ "manual" ];
                    };
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

              clients."${system}".path = builtins.toString sowerPkg;
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

          users.users.profile-consumer.isSystemUser = true;
          users.users.profile-consumer.group = "profile-consumer";
          users.groups.profile-consumer = { };
          systemd.services.sower-profile-consumer = {
            serviceConfig = {
              User = "profile-consumer";
              Group = "profile-consumer";
              ExecStart = "/var/lib/sower-profiles/package/package-a/profile/bin/profile-fixture serve";
            };
          };

          home-manager.users.testuser = {
            imports = [ ../home/module.nix ];

            home.stateVersion = "24.11";

            services.sower.garden = {
              enable = true;
              package = gardenPkg;
              activatorPackage = activatorPkg;
              accessTokenFile = "/run/sower/test_token";
              # kept on to exercise the distribution-on lifecycle subtest;
              # deploys now go over the admin socket (sow-204 drops distribution).
              distribution = true;

              settings = {
                endpoint = "http://localhost:4000";
                subscriptions = {
                  testuser = {
                    seed_name = "testuser";
                    seed_type = "home-manager";
                    policy.manual = {
                      actions = [ "activate" ];
                      triggers = [ "manual" ];
                    };
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
          # Do not expose the host store: the builder's deployment targets must
          # be genuinely absent here until a garden downloads them.
          virtualisation.useNixStoreImage = true;
          virtualisation.writableStore = true;
          virtualisation.writableStoreUseTmpfs = false;
          virtualisation.memorySize = 2048;
        };

      };

    builder =
      { nodes, pkgs, ... }:
      let
        fixturePkgs = import pkgs.path { inherit system; };
        # Rebuild real generations with a marker, preserving their activation
        # scripts. Only the builder receives these new paths initially.
        nixosTarget = nodes.server.system.build.toplevel.overrideAttrs (old: {
          name = "nixos-system-wrapper-e2e";
          buildCommand = old.buildCommand + ''
            echo canonical-nixos > "$out/sower-wrapper-e2e"
          '';
        });
        homeConfig = nodes.server.home-manager.users.testuser;
        homeTarget = homeConfig.home.activationPackage.overrideAttrs (old: {
          name = "home-manager-wrapper-e2e";
          buildCommand = old.buildCommand + ''
            echo canonical-home-manager > "$out/sower-wrapper-e2e"
          '';
        });
        jobs = pkgs.writeText "sower-wrapper-jobs.nix" ''
          {}:
          let
            pkgs = import ${pkgs.path} { system = "${system}"; };
            sowerLib = import ${../.}/sowerlib.nix {
              inputs = {};
              lib = pkgs.lib;
            };
          in
            (sowerLib.genNixosPackages {
              server = {
                inherit pkgs;
                config = {
                  system.build.toplevel = builtins.storePath "${nixosTarget}";
                  system.nixos.version = "${nodes.server.system.nixos.version}";
                };
              };
            }).${system}
            // (sowerLib.genHomeManagerPackages {
              testuser = {
                inherit pkgs;
                activationPackage = builtins.storePath "${homeTarget}";
                config.home = {
                  username = "${homeConfig.home.username}";
                  homeDirectory = "${homeConfig.home.homeDirectory}";
                  version.release = "${homeConfig.home.version.release}";
                };
              };
            }).${system}
        '';
        profileJobs =
          version:
          pkgs.writeText "sower-profile-jobs-${version}.nix" ''
            {}:
            let
              pkgs = import ${pkgs.path} { system = "${system}"; };
              sowerLib = import ${../.}/sowerlib.nix { inputs = {}; lib = pkgs.lib; };
              shared = pkgs.runCommand "profile-shared-input" {} "mkdir --parents $out; echo shared > $out/value";
              unique = pkgs.runCommand "profile-input-${version}" {} "mkdir --parents $out; echo ${version} > $out/value";
              package = pkgs.writeShellScriptBin "profile-fixture" '''
                printf '%s\n' '${version}'
                cat ${"$"}{shared}/value
                if [ "$#" -gt 0 ]; then
                  while true; do
                    ${"$"}{pkgs.coreutils}/bin/sleep 3600
                  done
                fi
              ''';
              shell = pkgs.mkShell {
                name = "profile-shell-${version}";
                buildInputs = [ shared unique ];
              };
            in builtins.listToAttrs [
              (sowerLib.mkSeedPackage {
                inherit pkgs;
                name = "package-fixture";
                target = package;
                tags.version = "${version}";
              })
              (sowerLib.mkSeedDevshell {
                inherit pkgs;
                name = "devshell-fixture";
                target = shell;
                tags.version = "${version}";
              })
            ]
          '';
      in
      {
        environment.systemPackages = [
          sowerPkg
          pkgs.python3
        ];
        environment.etc = {
          "sower/client.json".source = (pkgs.formats.json { }).generate "builder-client.json" {
            endpoint = "http://server:4000";
            access_token_file = "/run/sower/test_token";
          };
          "sower/wrapper-jobs.nix".source = jobs;
        }
        // builtins.listToAttrs (
          map
            (version: {
              name = "sower/profile-jobs-${version}.nix";
              value.source = profileJobs version;
            })
            [
              "one"
              "two"
              "three"
            ]
        );
        virtualisation = {
          useNixStoreImage = true;
          writableStore = true;
          writableStoreUseTmpfs = false;
          diskSize = 8192;
          memorySize = 2048;
          additionalPaths = [
            # Wrapper outputs are deliberately NOT included: sower must build
            # them inside this VM, with no network substituters.
            fixturePkgs.stdenv
            fixturePkgs.stdenvNoCC
            (fixturePkgs.callPackage ../packages/seed-manifest-validator.nix { })
            cacheSecretKey
          ];
        };
        nix.settings = {
          experimental-features = [
            "flakes"
            "nix-command"
          ];
          substituters = pkgs.lib.mkForce [ ];
        };
        networking.firewall.allowedTCPPorts = [ 8080 ];
        systemd.tmpfiles.rules = [
          "d /srv/sower-cache 0755 root root -"
          "d /run/sower 0755 root root -"
        ];
        systemd.services.sower-test-cache = {
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --directory /srv/sower-cache";
            Restart = "no";
          };
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
      import json
      import shlex
      from typing import Any
      start_all()
      server.wait_for_unit("postgresql.service")
      server.wait_for_unit("sower.service")
      server.wait_for_unit("sower-activator.socket")
      server.wait_for_unit("sower-garden.service")
      server.wait_for_open_port(4000)

      def assert_host_boot_identity(machine, pid):
          environment = dict(
              entry.split("=", 1)
              for entry in machine.succeed(f"cat /proc/{pid}/environ").split(chr(0))
              if "=" in entry
          )
          identity_path = environment["VM_MANAGER_BOOT_ID_FILE"]
          machine.succeed(
              f"cmp -- /proc/sys/kernel/random/boot_id /proc/{pid}/root{identity_path}"
          )

      with subtest("system garden receives actual host boot identity"):
          pid = server.succeed(
              "systemctl show --property=MainPID --value sower-garden.service"
          ).strip()
          assert_host_boot_identity(server, pid)

      with subtest("publication permissions preserve private Garden state"):
          server.succeed(
              "test \"$(stat --format='%a:%U:%G' /var/lib/sower-profiles)\""
              " = 755:sower-garden:sower-garden"
          )
          server.succeed(
              "test \"$(stat --format='%a' /var/lib/sower-garden)\" = 700"
          )
          server.succeed(
              "runuser --user profile-consumer -- test -x /var/lib/sower-profiles"
          )
          server.fail(
              "runuser --user profile-consumer -- test -w /var/lib/sower-profiles"
          )
          server.fail(
              "runuser --user profile-consumer -- test -x /var/lib/sower-garden"
          )

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
          server.succeed(f"RUST_LOG=debug sower seed --name server --type nixos submit --path {server_profile}")
          server.succeed("RUST_LOG=debug sower seed --name server --type nixos upgrade")

      with subtest("rust cli forwards build to the elixir cli"):
          server.succeed("echo '_: { }' > /root/empty.nix")
          server.succeed("sower build --eval-only --eval-type path /root/empty.nix")

      with subtest("nixos garden deployment"):
          # Resolve the admin socket from the garden's client.json
          # (admin_socket). The CLI bounds its own reply wait.
          server.wait_until_succeeds(
              "sower garden trigger --type nixos"
              " --config-file /etc/sower/client.json",
              timeout=30,
          )
          server.wait_until_succeeds(
              "journalctl --no-pager -u sower-garden"
              " --grep='Completed.activation'",
              timeout=15,
          )

      def api(method, path, body=None):
          auth = '-H "Authorization: Bearer $(cat /run/sower/test_token)"'
          data = " -H 'Content-Type: application/json' -d '" + body + "'" if body else ""
          url = "'http://localhost:4000/api/v1" + path + "'"
          return "curl -sf -X " + method + " " + auth + data + " " + url

      def api_field(method, path, field, body=None):
          extract = "python3 -c 'import json,sys; print(json.load(sys.stdin)[\"" + field + "\"])'"
          return server.succeed(api(method, path, body) + " | " + extract).strip()

      deploy = "sower deploy --config-file /etc/sower/client.json --to server"

      with subtest("direct deployment of a registered seed"):
          seed_sid = api_field("GET", "/seeds/latest?name=server&seed_type=nixos", "sid")
          server.succeed(f"RUST_LOG=debug {deploy} --seed {seed_sid} --force")

      with subtest("garden restart waits for the deployment that requested it"):
          pid_before = server.succeed(
              "systemctl show -p MainPID --value sower-garden.service"
          ).strip()
          before = server.succeed("date -u +%s").strip()
          sower = server.succeed("command -v sower").strip()
          server.succeed(
              f"systemd-run --unit=sower-deferred-reload-test"
              f" {sower} deploy --config-file /etc/sower/client.json"
              f" --to server --seed {seed_sid} --force"
          )
          server.wait_until_succeeds(
              f"journalctl --no-pager -u sower-garden.service"
              f" --since=@{before} --grep='Activating seed'",
              timeout=15,
          )
          server.systemctl("reload sower-garden.service")
          server.wait_until_succeeds(
              f"journalctl --no-pager -u sower-garden.service"
              f" --since=@{before} --grep='Received SIGHUP'",
              timeout=10,
          )
          assert (
              server.succeed(
                  "systemctl show -p MainPID --value sower-garden.service"
              ).strip()
              == pid_before
          ), "garden restarted before its active deployment completed"
          server.wait_until_succeeds(
              f"[ \"$(systemctl show -p MainPID --value sower-garden.service)\""
              f" != \"{pid_before}\" ]"
              " && [ \"$(systemctl is-active sower-garden.service)\" = active ]",
              timeout=30,
          )
          assert (
              server.succeed(
                  "systemctl show -p Result --value sower-deferred-reload-test.service"
              ).strip()
              == "success"
          )

      with subtest("direct deployment of a store path"):
          server.succeed(f"RUST_LOG=debug {deploy} --path {server_profile} --force")

      with subtest("deploy --no-wait prints a deployment sid"):
          sid = server.succeed(
              f"{deploy} --seed {seed_sid} --force --no-wait"
          ).strip()
          assert sid.startswith("dply_"), f"unexpected deployment sid {sid}"
          server.wait_until_succeeds(
              api("GET", f"/deployments/{sid}")
              + " | python3 -c 'import json,sys; d=json.load(sys.stdin);"
              + " assert d[\"state\"] == \"completed\" and d[\"result\"] == \"success\"'",
              timeout=120,
          )

      with subtest("deploy rejects an override with no reason"):
          server.fail(f"{deploy} --seed {seed_sid} --override --action activate")

      with subtest("break-glass override requires a reason"):
          body = (
              '{"garden": "server", "seed": "' + seed_sid + '",'
              ' "override": true, "action": "activate"}'
          )
          server.fail(api("POST", "/deployments", body))

      with subtest("activator handled nixos request"):
          server.succeed(
              "journalctl --no-pager -u 'sower-activator@*'"
              " --grep='Received request.*type=nixos'"
          )

      def start_user_garden(user):
          server.succeed(f"loginctl enable-linger {user}")
          uid = server.succeed(f"id -u {user}").strip()
          server.wait_for_unit(f"user@{uid}.service")
          # HM activation ran before the user manager was up, so reload and start manually
          server.systemctl("daemon-reload", user)
          server.systemctl("start sower-garden.service", user)
          server.wait_for_unit("sower-garden.service", user)
          pid = server.succeed(
              f"su --login {user} --command '"
              f"XDG_RUNTIME_DIR=/run/user/{uid} "
              f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus "
              "systemctl --user show --property=MainPID --value sower-garden.service'"
          ).strip()
          assert_host_boot_identity(server, pid)

      with subtest("start home-manager garden"):
          server.wait_for_unit("home-manager-testuser.service")
          start_user_garden("testuser")
          server.succeed(
              "test \"$(stat --format='%a:%U' /home/testuser/.local/state/sower-profiles)\""
              " = 700:testuser"
          )

      with subtest("home-manager garden registration"):
          server.wait_until_succeeds(
              "su -l testuser -c '"
              "journalctl --user --no-pager -u sower-garden"
              " --grep=Joined.channel.topic'",
              timeout=15,
          )

      with subtest("direct deployment is denied by a garden with no policy"):
          body = '{"garden": "testuser@server", "seed": "' + seed_sid + '", "force": true}'
          server.fail(api("POST", "/deployments", body))

      with subtest("home-manager garden deployment"):
          hm_generation = server.succeed(
              "readlink -f /home/testuser/.local/state/home-manager/gcroots/current-home"
          ).strip()
          server.succeed(
              f"sower seed --name testuser --type home-manager submit"
              f" --path {hm_generation}"
              f" --tag username=testuser"
          )
          # testuser's garden binds its socket under its own XDG_RUNTIME_DIR;
          # root connects to it explicitly (authorized as uid 0).
          hm_uid = server.succeed("id -u testuser").strip()
          server.wait_until_succeeds(
              f"sower garden trigger --type home-manager"
              f" --socket /run/user/{hm_uid}/sower-garden/admin.sock",
              timeout=30,
          )
          server.wait_until_succeeds(
              "su -l testuser -c '"
              "journalctl --user --no-pager -u sower-garden"
              " --grep=Completed.activation'",
              timeout=15,
          )

      with subtest("canonical wrappers are built, published, and register their targets"):
          # Stop consumers while publishing so absence cannot race a deployment.
          server.systemctl("stop sower-garden.service")
          server.systemctl("stop sower-garden.service", "testuser")
          builder.wait_for_unit("sower-test-cache.service")
          builder.wait_for_open_port(8080)
          builder.succeed(f"printf %s {shlex.quote(token.strip())} > /run/sower/test_token")
          wrappers = json.loads(builder.succeed(
              "nix eval --impure --json --file /etc/sower/wrapper-jobs.nix"
              " --apply 'jobs: builtins.mapAttrs (_: job: job.outPath) (jobs {})'"
          ))
          assert set(wrappers) == {"nixos/server", "home/testuser"}
          for wrapper in wrappers.values():
              builder.succeed(f"test ! -e {shlex.quote(wrapper)}")
              builder.fail(f"nix-store --check-validity {shlex.quote(wrapper)}")

          builder.succeed(
              "timeout --signal=KILL 900s"
              " sower build --eval-type path --eval-jobs 1 --build-jobs 1"
              " --seed --tag e2e=wrapper"
              " --cache 'file:///srv/sower-cache?secret-key=${cacheSecretKey}&compression=zstd&compression-level=1'"
              " /etc/sower/wrapper-jobs.nix",
              timeout=960,
          )

          manifests = {}
          seeds = {}
          for attr, wrapper in wrappers.items():
              manifest = json.loads(builder.succeed(f"cat {shlex.quote(wrapper)}/seed.json"))
              manifests[attr] = manifest
              seed = json.loads(server.succeed(api(
                  "GET",
                  f"/seeds/latest?name={manifest['name']}&seed_type={manifest['seed_type']}",
              )))
              seeds[attr] = seed
              assert seed["artifact"] == manifest["artifact"]
              assert seed["artifact"] != wrapper, "registered the wrapper instead of its target"
              tags = {(tag["key"], tag["value"]) for tag in seed["tags"]}
              assert ("e2e", "wrapper") in tags
              assert set(manifest["tags"].items()) <= tags
              for path in (wrapper, manifest["artifact"]):
                  server.succeed(f"test ! -e {shlex.quote(path)}")
                  server.fail(f"nix-store --check-validity {shlex.quote(path)}")

          wrapper_args = " ".join(shlex.quote(path) for path in wrappers.values())
          built_closure = set(builder.succeed(
              f"nix path-info --recursive {wrapper_args}"
          ).splitlines())
          published_closure = set(server.succeed(
              f"nix path-info --store http://builder:8080 --recursive {wrapper_args}",
              timeout=120,
          ).splitlines())
          assert published_closure == built_closure, "cache is missing wrapper closure paths"
          assert {manifest["artifact"] for manifest in manifests.values()} <= published_closure

      with subtest("home-manager garden downloads and activates the manifest target"):
          home_target = manifests["home/testuser"]["artifact"]
          server.succeed(f"test ! -e {shlex.quote(home_target)}")
          server.fail(f"nix-store --check-validity {shlex.quote(home_target)}")
          server.systemctl("start sower-garden.service", "testuser")
          server.wait_for_unit("sower-garden.service", "testuser")
          server.wait_until_succeeds(
              f"sower garden trigger --type home-manager"
              f" --socket /run/user/{hm_uid}/sower-garden/admin.sock",
              timeout=120,
          )
          server.wait_until_succeeds(
              "test \"$(readlink -f /home/testuser/.local/state/home-manager/gcroots/current-home)\""
              f" = {shlex.quote(home_target)}",
              timeout=30,
          )
          server.succeed(
              f"test \"$(cat {shlex.quote(home_target)}/sower-wrapper-e2e)\" = canonical-home-manager"
          )
          server.succeed(f"nix-store --check-validity {shlex.quote(home_target)}")
          server.succeed(f"test ! -e {shlex.quote(wrappers['home/testuser'])}")

      with subtest("nixos garden downloads and activates the manifest target"):
          nixos_target = manifests["nixos/server"]["artifact"]
          server.systemctl("start sower-garden.service")
          server.wait_for_unit("sower-garden.service")
          server.succeed(
              f"{deploy} --seed {seeds['nixos/server']['sid']} --force",
              timeout=120,
          )
          server.wait_until_succeeds(
              f"test \"$(readlink -f /run/current-system)\" = {shlex.quote(nixos_target)}",
              timeout=30,
          )
          server.succeed(f"test \"$(cat {shlex.quote(nixos_target)}/sower-wrapper-e2e)\" = canonical-nixos")
          server.succeed(f"nix-store --check-validity {shlex.quote(nixos_target)}")
          server.succeed(f"test ! -e {shlex.quote(wrappers['nixos/server'])}")

      def publish_profile_revision(version):
          jobs = f"/etc/sower/profile-jobs-{version}.nix"
          wrappers = json.loads(builder.succeed(
              f"nix eval --impure --json --file {jobs}"
              " --apply 'jobs: builtins.mapAttrs (_: job: job.outPath) (jobs {})'"
          ))
          builder.succeed(
              "timeout --signal=KILL 900s"
              " sower build --eval-type path --eval-jobs 1 --build-jobs 1 --seed"
              " --cache 'file:///srv/sower-cache?secret-key=${cacheSecretKey}&compression=zstd&compression-level=1'"
              f" {jobs}",
              timeout=960,
          )
          result = {}
          for attr, wrapper in wrappers.items():
              manifest = json.loads(builder.succeed(f"cat {shlex.quote(wrapper)}/seed.json"))
              seed = json.loads(server.succeed(api(
                  "GET",
                  f"/seeds/latest?name={manifest['name']}&seed_type={manifest['seed_type']}",
              )))
              assert seed["artifact"] == manifest["artifact"]
              assert seed["artifact"] != wrapper
              artifact = seed["artifact"]
              closure = set(builder.succeed(
                  f"nix path-info --recursive {shlex.quote(artifact)}"
              ).splitlines())
              cached = set(server.succeed(
                  "nix path-info --store http://builder:8080 --recursive "
                  + shlex.quote(artifact)
              ).splitlines())
              assert closure == cached, f"incomplete published closure for {attr}"
              result[manifest["seed_type"]] = {
                  "seed": seed,
                  "artifact": artifact,
                  "closure": closure,
                  "version": version,
              }
          shell = result["devshell"]
          shell["unique"] = next(
              path for path in shell["closure"] if path.endswith(f"-profile-input-{version}")
          )
          shell["shared"] = next(
              path for path in shell["closure"] if path.endswith("-profile-shared-input")
          )
          assert shell["shared"] in result["package"]["closure"]
          return result

      with subtest("ordinary package and devshell outputs publish through the real cache"):
          profile_one = publish_profile_revision("one")
          for fixture in profile_one.values():
              server.fail(f"nix-store --check-validity {shlex.quote(fixture['artifact'])}")
          server.fail(f"nix-store --check-validity {shlex.quote(profile_one['devshell']['unique'])}")

      profile_config = json.loads(server.succeed("cat /etc/sower/client.json"))
      server.succeed("cp --preserve=mode /run/sower/test_token /etc/sower/profile-token")
      profile_config["access_token_file"] = "/etc/sower/profile-token"
      profile_subscriptions: dict[str, dict[str, Any]] = {}
      for name, seed_type in (("package-a", "package"), ("package-b", "package"), ("shell-a", "devshell")):
          profile_subscriptions[name] = {
              "seed_name": f"{seed_type}-fixture",
              "seed_type": seed_type,
              "policy": {"manual": {"actions": ["activate"], "triggers": ["manual"]}},
          }
      profile_config["subscriptions"].update(profile_subscriptions)
      registered_subscriptions = (
          "sower-garden rpc "
          + shlex.quote("IO.puts(Jason.encode!(Garden.Storage.read().subscriptions))")
      )

      def reload_profile_config(online=True):
          server.succeed(
              "printf %s " + shlex.quote(json.dumps(profile_config))
              + " > /etc/sower/profile-client.json"
              + " && ln --symbolic --force /etc/sower/profile-client.json /etc/sower/client.json"
          )
          server.succeed("sower garden reload")
          if online:
              expected = {
                  name: (sub["policy"]["manual"]["actions"], sub.get("rules", []), sub.get("retention"))
                  for name, sub in profile_subscriptions.items()
                  if name in profile_config["subscriptions"]
              }
              check = (
                  "import json,sys; "
                  "subs={s['name']:s for s in json.load(sys.stdin)}; "
                  f"expected={expected!r}; "
                  "assert all(n in subs and subs[n]['sid'] and subs[n]['policy']['manual']['actions']==a "
                  "and subs[n]['rules']==r and subs[n]['retention']==t "
                  "for n,(a,r,t) in expected.items()), subs"
              )
              server.wait_until_succeeds(
                  registered_subscriptions
                  + " | python3 -c " + shlex.quote(check),
                  timeout=120,
              )

      def profile_directory(name):
          return f"/var/lib/sower-profiles/{profile_subscriptions[name]['seed_type']}/{name}"

      def selected_profile(name):
          return server.succeed(f"readlink --canonicalize {profile_directory(name)}/profile").strip()

      def profile_generations(name):
          return set(server.succeed(
              f"readlink --canonicalize {profile_directory(name)}/profile-*-link"
          ).splitlines())

      def deploy_profile(name, fixture, action="activate"):
          profile_subscriptions[name]["policy"]["manual"]["actions"] = [action]
          profile_subscriptions[name]["rules"] = [
              {"key": "version", "op": "eq", "value": fixture["version"]}
          ]
          reload_profile_config()
          subscriptions = json.loads(server.succeed(registered_subscriptions))
          sid = next(sub["sid"] for sub in subscriptions if sub["name"] == name)
          server.succeed(f"sower garden trigger --sid {sid} --force")
          directory = profile_directory(name)
          path = fixture["artifact"]
          link = f"{directory}/staged/{path.rsplit('/', 1)[1]}" if action == "stage" else f"{directory}/profile"
          server.wait_until_succeeds(
              f"test \"$(readlink --canonicalize {link})\" = {shlex.quote(path)}",
              timeout=120,
          )

      def vm_gc():
          server.succeed("nix-store --gc", timeout=120)

      def unrelated_profile_snapshot():
          return {
              path: server.succeed(f"readlink --canonicalize {path}").strip()
              for path in (
                  "/nix/var/nix/profiles/system",
                  "/home/testuser/.local/state/home-manager/gcroots/current-home",
              )
          }

      with subtest("configured independent profiles activate ordinary package and mkShell outputs"):
          unrelated_profiles = unrelated_profile_snapshot()
          for name, seed_type in (("package-a", "package"), ("package-b", "package"), ("shell-a", "devshell")):
              deploy_profile(name, profile_one[seed_type])
          vm_gc()
          for path in profile_one["devshell"]["closure"]:
              server.succeed(f"nix-store --check-validity {shlex.quote(path)}")
          server.succeed(
              "runuser --user profile-consumer -- "
              "/var/lib/sower-profiles/package/package-a/profile/bin/profile-fixture"
          )
          server.systemctl("start sower-profile-consumer.service")
          server.wait_for_unit("sower-profile-consumer.service")
          consumer_invocation = server.succeed(
              "systemctl show --property=InvocationID --value sower-profile-consumer.service"
          ).strip()
          consumer_unit = server.succeed("systemctl cat sower-profile-consumer.service")

      with subtest("ordinary stage retains closure without selecting or restarting consumers"):
          profile_two = publish_profile_revision("two")
          deploy_profile("package-a", profile_two["package"], "stage")
          assert selected_profile("package-a") == profile_one["package"]["artifact"]
          vm_gc()
          server.succeed(f"nix-store --check-validity {profile_two['package']['artifact']}")
          deploy_profile("package-a", profile_two["package"])
          assert selected_profile("package-b") == profile_one["package"]["artifact"]
          server.succeed(
              "runuser --user sower-garden -- nix-env"
              " --profile /var/lib/sower-profiles/package/package-a/profile --switch-generation 1"
          )
          assert selected_profile("package-a") == profile_one["package"]["artifact"]
          server.succeed(
              "runuser --user sower-garden -- nix-env"
              " --profile /var/lib/sower-profiles/package/package-a/profile --switch-generation 2"
          )
          assert selected_profile("package-a") == profile_two["package"]["artifact"]
          assert server.succeed(
              "systemctl show --property=InvocationID --value sower-profile-consumer.service"
          ).strip() == consumer_invocation
          assert server.succeed("systemctl cat sower-profile-consumer.service") == consumer_unit
          deploy_profile("shell-a", profile_two["devshell"])
          assert profile_generations("shell-a") == {
              profile_one["devshell"]["artifact"], profile_two["devshell"]["artifact"]
          }

      with subtest("retention combines count and local age and leaves staged roots alone"):
          profile_subscriptions["shell-a"]["retention"] = {"keep_generations": 1, "keep_days": 1}
          profile_three = publish_profile_revision("three")
          deploy_profile("shell-a", profile_three["devshell"])
          assert len(profile_generations("shell-a")) == 3
          server.succeed("date --set='+2 days'")
          deploy_profile("shell-a", profile_three["devshell"])
          server.wait_until_succeeds(
              "test ! -e /var/lib/sower-profiles/devshell/shell-a/profile-1-link"
              " && test ! -e /var/lib/sower-profiles/devshell/shell-a/profile-2-link"
          )
          deploy_profile("shell-a", profile_two["devshell"], "stage")
          assert selected_profile("shell-a") == profile_three["devshell"]["artifact"]
          vm_gc()
          server.fail(f"nix-store --check-validity {profile_one['devshell']['unique']}")
          server.succeed(f"nix-store --check-validity {profile_two['devshell']['unique']}")
          server.succeed(f"nix-store --check-validity {profile_three['devshell']['unique']}")
          staged = profile_two["devshell"]["artifact"].rsplit("/", 1)[1]
          server.succeed(f"rm /var/lib/sower-profiles/devshell/shell-a/staged/{staged}")
          vm_gc()
          server.fail(f"nix-store --check-validity {profile_two['devshell']['unique']}")
          assert unrelated_profile_snapshot() == unrelated_profiles

      with subtest("offline config removal deletes only owned directories without stopping external services"):
          server.systemctl("stop sower.service")
          del profile_config["subscriptions"]["package-a"]
          del profile_config["subscriptions"]["shell-a"]
          reload_profile_config(online=False)
          server.wait_until_succeeds(
              "test ! -e /var/lib/sower-profiles/package/package-a"
              " && test ! -e /var/lib/sower-profiles/devshell/shell-a"
          )
          assert selected_profile("package-b") == profile_one["package"]["artifact"]
          vm_gc()
          server.fail(f"nix-store --check-validity {profile_three['devshell']['unique']}")
          server.succeed(f"nix-store --check-validity {profile_one['devshell']['shared']}")
          assert server.succeed(
              "systemctl show --property=InvocationID --value sower-profile-consumer.service"
          ).strip() == consumer_invocation
          assert server.succeed("systemctl cat sower-profile-consumer.service") == consumer_unit
          assert unrelated_profile_snapshot() == unrelated_profiles
          del profile_config["subscriptions"]["package-b"]
          reload_profile_config(online=False)
          server.wait_until_succeeds("test ! -e /var/lib/sower-profiles/package/package-b")
          server.systemctl("start sower.service")
          server.wait_for_unit("sower.service")

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
          start_user_garden("nodist-user")
          assert_lifecycle(server, "sower-garden.service", "nodist-user")

      with subtest("home-manager signal-driven lifecycle (distribution on)"):
          start_user_garden("testuser")
          assert_lifecycle(server, "sower-garden.service", "testuser")

      with subtest("nixos signal-driven lifecycle (distribution on)"):
          # system garden on server has distribution=true; run last because
          # the stop call leaves it inactive.
          assert_lifecycle(server, "sower-garden.service")

    '';
}
