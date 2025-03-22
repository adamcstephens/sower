# Debug like this:
# $ nix build .\#checks.x86_64-linux.nixos-test.driverInteractive
# $ ./result/bin/nixos-test-driver
# >>> start_all()
# >>> machine.shell_interact()
{
  flake,
  pkgs,
  testers,
}:
testers.runNixOSTest {
  name = "sower";

  nodes = {
    server =
      { lib, pkgs, ... }:
      {
        imports = [ ../nixos/module.nix ];

        config = {
          # need switch-to-configuration
          system.switch.enable = true;
          # without trying to install grub
          boot.loader.grub.enable = false;

          environment.systemPackages = [
            flake.packages.${pkgs.system}.seed-ci
          ];

          networking.firewall.allowedTCPPorts = [ 4000 ];

          nix.settings = {
            experimental-features = "flakes nix-command";
            substituters = lib.mkForce [ ];
          };

          services.sower.client = {
            enable = true;
            package = flake.packages.${pkgs.system}.client;

            settings = {
              api-token-file = "/run/sower/test_token";
              debug = true;
              endpoint = "http://localhost:4000";
            };
          };

          services.sower.server = {
            enable = true;
            package = flake.packages.${pkgs.system}.server;
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

              auth = {
                oidc_client_id = "sower";
                oidc_base_url = "http://localhost:9000";
                oidc_client_secret_file = "${pkgs.writeText "oidc-secret" "ok"}";
              };

              log_level = "debug";

              clients."${pkgs.system}".path = builtins.toString flake.packages.${pkgs.system}.client;
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

          virtualisation.diskSize = 4096;
        };

      };
    client = { };
  };

  testScript = # python
    ''
      start_all()
      server.wait_for_unit("postgresql.service")
      server.wait_for_unit("sower.service")
      server.wait_for_open_port(4000)

      with subtest("basic submission and activation"):
          nixos_profile = server.succeed("readlink -f /run/booted-system").strip()
          server.succeed(f"sower seed submit --create --path {nixos_profile} --debug")
          server.succeed("curl http://server:4000/client/bootstrap | bash -s seed info")
          server.succeed("systemctl start sower-client")

      with subtest("client can bootstrap"):
          client_profile = client.succeed("readlink -f /run/booted-system").strip()
          server.succeed(f"sower seed submit --create --name client --type nixos --path {client_profile} --debug")
          token = server.succeed("cat /run/sower/test_token")
          client.succeed(f"curl http://server:4000/client/bootstrap | bash -s seed info --api-token {token} --name client --type nixos")
    '';
}
