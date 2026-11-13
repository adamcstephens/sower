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
              ExecStart = "/var/lib/sower-profiles/package-a/profile/bin/profile-fixture serve";
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
              "four"
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

      def profile_operation(name, action, expected="completed", **fields):
          import uuid
          request_id = str(uuid.uuid4())
          body = dict(request_id=request_id, profile_name=name, action=action, **fields)
          result = json.loads(server.succeed(api(
              "POST", "/gardens/server/profiles/operations", json.dumps(body)
          )))
          if result["status"] == "pending":
              endpoint = f"/gardens/server/profiles/operations/{request_id}"
              server.wait_until_succeeds(
                  api("GET", endpoint)
                  + " | python3 -c 'import json,sys; result=json.load(sys.stdin);"
                  + f' assert result["status"] == "{expected}", result' + "'",
                  timeout=120,
              )
              result = json.loads(server.succeed(api("GET", endpoint)))
          assert result["status"] == expected, result
          return result

      def profile_inventory(name):
          return profile_operation(name, "inspect")["profile"]

      def stage_profile(name, fixture):
          profile_operation(
              name, "stage",
              subscription_sid=profile_subscriptions[name]["sid"],
              seed_sid=fixture["seed"]["sid"],
          )
          profile = profile_inventory(name)
          return next(g for g in profile["generations"] if g["path"] == fixture["artifact"])

      def select_profile(name, generation):
          profile_operation(name, "select", generation_id=generation["generation_id"])
          path = f"/var/lib/sower-profiles/{name}/profile"
          assert server.succeed(f"readlink --canonicalize {path}").strip() == generation["path"]
          generation.update(next(
              g for g in profile_inventory(name)["generations"]
              if g["generation_id"] == generation["generation_id"]
          ))

      def vm_gc():
          server.succeed("nix-store --gc", timeout=120)

      def unrelated_profile_snapshot():
          paths = {
              "system": "/nix/var/nix/profiles/system",
              "home": "/home/testuser/.local/state/home-manager/gcroots/current-home",
          }
          return {
              name: {
                  "raw": server.succeed(f"readlink {path}").strip(),
                  "resolved": server.succeed(f"readlink --canonicalize {path}").strip(),
              }
              for name, path in paths.items()
          }

      def assert_unrelated_profiles(expected):
          actual = unrelated_profile_snapshot()
          assert actual == expected, {"expected": expected, "actual": actual}

      with subtest("independent subscriptions select ordinary outputs with native roots"):
          unrelated_profiles = unrelated_profile_snapshot()
          profile_subscriptions = {}
          for name, seed_type in (("package-a", "package"), ("package-b", "package"), ("shell-a", "devshell")):
              subscription = {
                  "name": name,
                  "seed_name": f"{seed_type}-fixture",
                  "seed_type": seed_type,
                  "policy": {"manual": {"actions": ["stage", "activate"], "triggers": ["manual"]}},
              }
              profile_subscriptions[name] = json.loads(server.succeed(api(
                  "POST", "/gardens/server/subscriptions", json.dumps(subscription)
              )))
          package_a_one = stage_profile("package-a", profile_one["package"])
          server.fail("test -e /var/lib/sower-profiles/package-a/profile")
          select_profile("package-a", package_a_one)
          package_b_one = stage_profile("package-b", profile_one["package"])
          select_profile("package-b", package_b_one)
          shell_one = stage_profile("shell-a", profile_one["devshell"])
          select_profile("shell-a", shell_one)
          assert profile_inventory("shell-a")["retention"] is None
          before = profile_inventory("package-a")["generations"]
          stage_profile("package-a", profile_one["package"])
          select_profile("package-a", package_a_one)
          assert profile_inventory("package-a")["generations"] == before
          server.succeed(
              "sower-garden rpc "
              + shlex.quote(
                  "{_, 0} = System.cmd(System.find_executable(\"sower\"), "
                  "[\"internal\", \"sync-directory\", \"/nix/var/nix/gcroots/auto\"])"
              )
          )
          vm_gc()
          for path in profile_one["devshell"]["closure"]:
              server.succeed(f"nix-store --check-validity {shlex.quote(path)}")
          server.succeed(
              "runuser --user profile-consumer -- "
              "/var/lib/sower-profiles/package-a/profile/bin/profile-fixture"
          )
          server.systemctl("start sower-profile-consumer.service")
          server.wait_for_unit("sower-profile-consumer.service")
          consumer_pid = server.succeed(
              "systemctl show --property=MainPID --value sower-profile-consumer.service"
          ).strip()
          assert consumer_pid != "0"
          consumer_invocation = server.succeed(
              "systemctl show --property=InvocationID --value sower-profile-consumer.service"
          ).strip()
          consumer_unit = server.succeed("systemctl cat sower-profile-consumer.service")
          profile_operation("package-a", "pin", generation_id=package_a_one["generation_id"])

      with subtest("stage preserves selection and pinned immutable generations survive update"):
          profile_two = publish_profile_revision("two")
          package_a_two = stage_profile("package-a", profile_two["package"])
          assert server.succeed(
              "readlink --canonicalize /var/lib/sower-profiles/package-a/profile"
          ).strip() == profile_one["package"]["artifact"]
          vm_gc()
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_two['package']['artifact'])}")
          select_profile("package-a", package_a_two)
          assert server.succeed(
              "readlink --canonicalize /var/lib/sower-profiles/package-b/profile"
          ).strip() == profile_one["package"]["artifact"]
          assert server.succeed(
              "systemctl show --property=InvocationID --value sower-profile-consumer.service"
          ).strip() == consumer_invocation
          assert server.succeed(
              "systemctl show --property=MainPID --value sower-profile-consumer.service"
          ).strip() == consumer_pid
          assert server.succeed("systemctl cat sower-profile-consumer.service") == consumer_unit
          server.succeed(
              "runuser --user profile-consumer -- "
              + shlex.quote(package_a_one["generation_path"] + "/bin/profile-fixture")
          )
          profile_operation("package-a", "rollback", generation_id=package_a_one["generation_id"])
          assert server.succeed(
              "readlink --canonicalize /var/lib/sower-profiles/package-a/profile"
          ).strip() == profile_one["package"]["artifact"]
          select_profile("package-a", package_a_two)
          shell_two = stage_profile("shell-a", profile_two["devshell"])
          select_profile("shell-a", shell_two)
          assert len(profile_inventory("shell-a")["generations"]) == 2
          assert_unrelated_profiles(unrelated_profiles)

      def local_profile(command):
          return json.loads(server.succeed(
              "sower garden --socket /run/sower-garden/admin.sock profile " + command
          ))

      def local_uninstall(name):
          result = local_profile(f"uninstall {shlex.quote(name)} --confirm")
          if result["status"] == "pending":
              endpoint = f"/gardens/server/profiles/operations/{result['request_id']}"
              server.wait_until_succeeds(
                  api("GET", endpoint)
                  + " | python3 -c 'import json,sys; result=json.load(sys.stdin);"
                  + ' assert result["status"] != "pending", result' + "'",
                  timeout=120,
              )
              result = json.loads(server.succeed(api("GET", endpoint)))
          assert result["status"] == "completed", result
          path = shlex.quote(f"/var/lib/sower-profiles/{name}/profile")
          server.succeed(f"test ! -e {path} && test ! -L {path}")

      def daily_retention():
          server.succeed(
              "sower-garden rpc "
              + shlex.quote(
                  "job = Garden.Scheduler.find_job(:managed_profile_retention); "
                  "true = not is_nil(job); "
                  "true = job.schedule == Crontab.CronExpression.Parser.parse!(\"0 3 * * *\"); "
                  "{m, f, a} = job.task; apply(m, f, a)"
              )
          )

      with subtest("omitted retention keeps old generations after the daily callback"):
          assert server.succeed("timedatectl show --property=NTP --value").strip() == "no"
          server.succeed("date --set='+2 days'")
          daily_retention()
          assert len(profile_inventory("shell-a")["generations"]) == 2
          vm_gc()
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_one['devshell']['unique'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_two['devshell']['unique'])}")

      with subtest("post-update retention combines count and local age and preserves pins"):
          profile_operation("shell-a", "pin", generation_id=shell_one["generation_id"])
          subscription = profile_subscriptions["shell-a"]
          subscription["retention"] = {"keep_generations": 1, "keep_days": 1}
          server.succeed(api(
              "PATCH", f"/gardens/server/subscriptions/{subscription['sid']}",
              json.dumps({key: value for key, value in subscription.items() if key != "sid"}),
          ))
          profile_three = publish_profile_revision("three")
          shell_three = stage_profile("shell-a", profile_three["devshell"])
          select_profile("shell-a", shell_three)
          generations = profile_inventory("shell-a")["generations"]
          assert {g["path"] for g in generations} == {
              profile_one["devshell"]["artifact"], profile_three["devshell"]["artifact"]
          }
          assert next(g for g in generations if g["path"] == profile_one["devshell"]["artifact"])["pinned"]
          vm_gc()
          server.fail(f"nix-store --check-validity {shlex.quote(profile_two['devshell']['unique'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_one['devshell']['unique'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_one['devshell']['shared'])}")

      with subtest("staged roots and selected generations survive abrupt Garden stop and reboot"):
          profile_four = publish_profile_revision("four")
          shell_four = stage_profile("shell-a", profile_four["devshell"])
          server.systemctl("kill --signal=KILL sower-garden.service")
          server.systemctl("reset-failed sower-garden.service")
          server.systemctl("start sower-garden.service")
          server.wait_for_unit("sower-garden.service")
          assert any(g["generation_id"] == shell_four["generation_id"] and g["is_staged"]
                     for g in local_profile("show shell-a")["profile"]["generations"])
          assert_unrelated_profiles(unrelated_profiles)
          retention_time = server.succeed("date +%s").strip()
          server.shutdown()
          server.start()
          server.wait_for_unit("sower.service")
          server.wait_for_unit("sower-garden.service")
          server.wait_for_unit("home-manager-testuser.service")
          reboot_profiles = unrelated_profile_snapshot()
          assert reboot_profiles["system"] == unrelated_profiles["system"], {
              "expected": unrelated_profiles, "actual": reboot_profiles,
          }
          assert reboot_profiles["home"]["resolved"] == hm_generation, {
              "expected_home": hm_generation, "actual": reboot_profiles,
          }
          unrelated_profiles["home"] = reboot_profiles["home"]
          server.succeed(f"date --set=@{retention_time}")
          assert server.succeed(
              "readlink --canonicalize /var/lib/sower-profiles/shell-a/profile"
          ).strip() == profile_three["devshell"]["artifact"]
          vm_gc()
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_four['devshell']['unique'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_three['devshell']['unique'])}")

      with subtest("daily retention runs offline without new seeds and preserves staged and shared roots"):
          server.wait_for_unit("epmd.service")
          epmd_pid = server.succeed("systemctl show --property=MainPID --value epmd.service").strip()
          assert epmd_pid != "0"
          assert "epmd.service" in server.succeed(f"cat /proc/{epmd_pid}/cgroup")
          garden_pid = server.succeed("systemctl show --property=MainPID --value sower-garden.service").strip()
          epmd_names = "${pkgs.beamMinimal29Packages.erlang}/bin/epmd -names"
          assert "name garden " in server.succeed(epmd_names)
          server.systemctl("stop sower.service")
          assert server.succeed("systemctl show --property=MainPID --value epmd.service").strip() == epmd_pid
          assert server.succeed("systemctl show --property=MainPID --value sower-garden.service").strip() == garden_pid
          assert "name garden " in server.succeed(epmd_names)
          server.succeed("date --set='+2 days'")
          result = local_profile(f"unpin shell-a {shell_one['generation_id']}")
          assert result["status"] == "completed"
          daily_retention()
          generations = local_profile("show shell-a")["profile"]["generations"]
          assert {g["path"] for g in generations} == {
              profile_three["devshell"]["artifact"], profile_four["devshell"]["artifact"]
          }
          vm_gc()
          server.fail(f"nix-store --check-validity {shlex.quote(profile_one['devshell']['unique'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_one['devshell']['shared'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_four['devshell']['unique'])}")
          result = local_profile(f"discard shell-a {shell_four['generation_id']}")
          assert result["status"] == "completed"
          vm_gc()
          server.fail(f"nix-store --check-validity {shlex.quote(profile_four['devshell']['unique'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_three['devshell']['unique'])}")
          server.systemctl("start sower.service")
          server.wait_for_unit("sower.service")

      with subtest("offline subscription deletion waits for acknowledgement and blocks on pins"):
          preview = profile_operation("package-a", "uninstall", expected="preview", preview=True)
          assert preview["affected_generations"]
          assert "external" in preview["warning"].lower()
          assert any(g["pinned"] for g in preview["affected_generations"])
          server.systemctl("stop sower-garden.service")
          removal = json.loads(server.succeed(api(
              "DELETE",
              f"/gardens/server/subscriptions/{profile_subscriptions['package-a']['sid']}",
          )))
          assert removal["status"] == "pending"
          assert "external" in removal["warning"].lower()
          server.succeed("test -e /var/lib/sower-profiles/package-a/profile")
          removal_endpoint = f"/gardens/server/profiles/operations/{removal['request_id']}"
          assert json.loads(server.succeed(api("GET", removal_endpoint)))["status"] == "pending"
          server.systemctl("start sower-garden.service")
          server.wait_for_unit("sower-garden.service")
          server.wait_until_succeeds(
              api("GET", removal_endpoint)
              + " | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"status\"] == \"blocked\"'",
              timeout=120,
          )
          blocked = local_profile("show package-a")["profile"]
          assert blocked["lifecycle_status"] == "uninstall_blocked"
          result = local_profile(f"unpin package-a {package_a_one['generation_id']}")
          assert result["status"] == "completed"
          server.wait_until_succeeds(
              api("GET", removal_endpoint)
              + " | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"status\"] == \"completed\"'",
              timeout=120,
          )
          server.fail("test -e /var/lib/sower-profiles/package-a/profile")
          assert server.succeed(
              "readlink --canonicalize /var/lib/sower-profiles/package-b/profile"
          ).strip() == profile_one["package"]["artifact"]
          vm_gc()
          server.fail(f"nix-store --check-validity {shlex.quote(profile_two['package']['artifact'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_one['package']['artifact'])}")

      with subtest("explicit uninstall releases only owned roots and leaves unrelated profiles intact"):
          result = local_profile("uninstall shell-a")
          assert result["status"] == "preview"
          assert result["affected_generations"]
          assert "external" in result["warning"].lower()
          local_uninstall("shell-a")
          vm_gc()
          server.fail(f"nix-store --check-validity {shlex.quote(profile_three['devshell']['unique'])}")
          server.succeed(f"nix-store --check-validity {shlex.quote(profile_one['devshell']['shared'])}")
          assert_unrelated_profiles(unrelated_profiles)
          local_uninstall("package-b")
          vm_gc()
          server.fail(f"nix-store --check-validity {shlex.quote(profile_one['package']['artifact'])}")
          server.fail(f"nix-store --check-validity {shlex.quote(profile_one['devshell']['shared'])}")
          assert_unrelated_profiles(unrelated_profiles)

      with subtest("Garden death during real cache realization preserves selection and accounts recovered roots"):
          import uuid
          name = "package-interrupted"
          profile_subscriptions[name] = json.loads(server.succeed(api(
              "POST", "/gardens/server/subscriptions",
              json.dumps({
                  "name": name, "seed_name": "package-fixture", "seed_type": "package",
                  "policy": {"manual": {"actions": ["stage", "activate"], "triggers": ["manual"]}},
              }),
          )))
          previous = stage_profile(name, profile_one["package"])
          select_profile(name, previous)
          target = profile_two["package"]["artifact"]
          server.fail(f"nix-store --check-validity {shlex.quote(target)}")
          builder.systemctl("kill --signal=STOP sower-test-cache.service")
          interrupted = json.loads(server.succeed(api(
              "POST", "/gardens/server/profiles/operations",
              json.dumps({
                  "request_id": str(uuid.uuid4()), "profile_name": name, "action": "stage",
                  "subscription_sid": profile_subscriptions[name]["sid"],
                  "seed_sid": profile_two["package"]["seed"]["sid"],
              }),
          )))
          assert interrupted["status"] == "pending"
          child_query = "pgrep --uid sower-garden --full " + shlex.quote("nix-store.*" + target)
          server.wait_until_succeeds(child_query, timeout=30)
          native_pids = server.succeed(child_query).split()
          server.systemctl("kill --signal=KILL sower-garden.service")
          for pid in native_pids:
              server.wait_until_succeeds(f"test ! -e /proc/{pid}", timeout=30)
          builder.systemctl("kill --signal=CONT sower-test-cache.service")
          server.systemctl("reset-failed sower-garden.service")
          server.systemctl("start sower-garden.service")
          server.wait_for_unit("sower-garden.service")
          recovered = local_profile(f"show {name}")["profile"]
          assert server.succeed(
              f"readlink --canonicalize /var/lib/sower-profiles/{name}/profile"
          ).strip() == previous["path"]
          accounted = {recovered["profile_path"]}
          for generation in recovered["generations"]:
              accounted.update(
                  generation[key] for key in ("link", "generation_path") if generation.get(key)
              )
          roots = set(server.succeed(
              f"find /var/lib/sower-profiles/{name} -maxdepth 1 -type l -printf '%p\\n'"
          ).splitlines())
          assert roots == accounted
          vm_gc()
          server.succeed(f"nix-store --check-validity {shlex.quote(previous['path'])}")
          local_uninstall(name)

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
