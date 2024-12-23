# Debug like this:
# $ nix build .\#checks.x86_64-linux.nixos-test.driverInteractive
# $ ./result/bin/nixos-test-driver
# >>> start_all()
# >>> machine.shell_interact()
{
  flake,
  testers,
}:

testers.runNixOSTest {
  name = "sower";

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ ./nixos-module.nix ];

      config = {
        # need switch-to-configuration
        system.switch.enable = true;
        # without trying to install grub
        boot.loader.grub.enable = false;

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
            public_url = "http://127.0.0.1:4000";

            database = {
              socket = "/run/postgresql/.s.PGSQL.5432";
              username = "sower";
              database = "sower";
            };

            error_database = {
              socket = "/run/postgresql/.s.PGSQL.5432";
              username = "sower";
              database = "sower_error";
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
            CREATE DATABASE sower_error OWNER sower;
          '';

          authentication = ''
            local sower_error sower peer
          '';
        };
      };
    };

  testScript = # python
    ''
      start_all()
      server.wait_for_unit("postgresql.service")
      server.wait_for_unit("sower.service")
      server.wait_for_open_port(4000)

      nixos_profile = server.succeed("readlink -f /run/booted-system").strip()
      server.succeed(f"sower seed submit --create --path {nixos_profile} --debug")
      server.succeed("systemctl start sower-client")
    '';
}
