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

  nodes.server = {
    imports = [ ./nixos-module.nix ];

    config = {
      environment.systemPackages = [ curl ];

      services.sower.client = {
        enable = true;
        package = client;
        settings = {
          url = "http://localhost:4000";
          mode = "dry-activate";
        };
      };

      services.sower.server = {
        enable = true;
        environment = {
          SOWER_DATABASE_SOCKET = "/run/postgresql/.s.PGSQL.5432";
          SOWER_HOSTNAME = "localhost";
          SOWER_PUBLIC_PORT = "4000";
          SOWER_PUBLIC_SCHEME = "http";
        };
      };

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
  '';
}
