{
  bash,
  lib,
  pkgs,
  runCommand,
  sowerLib,
  sowerServicesHook,
}:
runCommand "simple-service"
  {
    nativeBuildInputs = [ sowerServicesHook ];

    sowerServices = sowerLib.generateUnitFiles {
      inherit pkgs;
      config = {
        services.simple-oneshot = {
          wantedBy = [
            "multi-user.target"
          ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
            RemainAfterExit = true;
          };
        };

        services.simple-sleep = {
          wantedBy = [
            "multi-user.target"
          ];

          script = ''
            #!${lib.getExe bash}
            sleep 86400
          '';
        };
      };
    };
  }
  ''
    mkdir $out
    _sowerServicesHook
  ''
