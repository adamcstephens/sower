# Debug like this:
# $ nix build .\#checks.x86_64-linux.nixos-test.driverInteractive
# $ ./result/bin/nixos-test-driver
# >>> start_all()
# >>> machine.shell_interact()
{
  client,
  curl,
  testers,
}:

testers.runNixOSTest {
  name = "sower";

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ ./nixos-module.nix ];

      config = {
        environment.systemPackages = [ curl ];

        services.sower.client = {
          enable = true;
          package = client;

          credentials = [ "SOWER_BOOTSTRAP_TOKEN_FILE:${pkgs.writeText "token" "aninsecuretoken"}" ];

          settings = {
            url = "http://localhost:4000";
            mode = "dry-activate";
            bootstrap_token_file = "${pkgs.writeText "token" "aninsecuretoken"}";
          };
        };

        services.sower.server = {
          enable = true;
          initSecrets = true;
          secrets = {
            bootstrap_token_file = "${pkgs.writeText "token" "aninsecuretken"}";
          };

          settings = {
            public_url = "http://127.0.0.1:4000";

            database = {
              socket = "/run/postgresql/.s.PGSQL.5432";
              username = "sower";
              database = "sower";
            };

            auth = {
              oidc_client_id = "sower";
              oidc_base_url = "http://localhost:9000";
              oidc_client_secret_file = "${pkgs.writeText "oidc-secret" "ok"}";
            };

            log_level = "debug";
          };
        };
        systemd.services.sower.serviceConfig.Restart = "no";

        services.postgresql = {
          enable = true;
          ensureUsers = [
            {
              name = "sower";
              ensureDBOwnership = true;
            }
          ];
          ensureDatabases = [ "sower" ];
        };
      };
    };

  testScript = ''
    start_all()
    server.wait_for_unit("postgresql.service")
    server.wait_for_unit("sower.service")
    server.wait_for_open_port(4000)

    nixos_profile = server.succeed("readlink -f /run/booted-system").strip()
    server.succeed('curl --fail -X POST --header "Content-Type: application/json" http://localhost:4000/api/seeds -d \'{"name": "server", "type": "nixos", "out_path": "' + nixos_profile + "\"}'")
    server.succeed("systemctl start sower-client")
    server.succeed('curl --fail -X POST --header "Content-Type: application/json" http://localhost:4000/api/seeds -d \'{"name": "server", "type": "nixos", "branch": "testbranch", "repo_url": "https://test.com", "out_path": "' + nixos_profile + "\"}'")
    server.succeed("systemctl start sower-client")
  '';
}
