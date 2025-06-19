{
  flake,
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
          boot.extraSystemdUnitPaths = [
            "/etc/sower/system"
          ];

          environment.etc = {
            "sower/system/test.service".text = ''
              [Unit]

              [Service]
              Type=oneshot
              RemainAfterExit=yes
              ExecStart=/run/current-system/sw/bin/true
            '';

            # "sower/system/multi-user.target.wants/test.service".source = "/etc/sower/system/test.service";
          };
        };

      };
  };

  testScript = # python
    ''
      start_all()
      server.wait_for_unit("test.service")
    '';
}
