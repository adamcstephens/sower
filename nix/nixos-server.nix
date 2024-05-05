{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.server;
in
{
  options = {
    services.sower.server = {
      enable = lib.mkEnableOption "Sower server";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./server-package.nix { };
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        description = "environment variables to pass to service. Do not set secrets here, but instead use systemd credentials";
        default = { };
      };

      initSecrets = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to initialise non‐existent secrets with random values.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.sower = {
      description = "Sower management platform";

      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "postgresql.service"
      ];
      requires = [ "network-online.target" ];

      serviceConfig = lib.mkMerge [
        {
          Type = "notify";
          WatchdogSec = "10s";
          Restart = "on-failure";

          DynamicUser = true;
          StateDirectory = "sower";
          RuntimeDirectory = "sower";

          ExecStart = pkgs.writeShellScript "sower-start" ''
            ${lib.optionalString cfg.initSecrets ''
              export RELEASE_COOKIE=$(cat $CREDENTIALS_DIRECTORY/RELEASE_COOKIE_FILE)
            ''}

            ${cfg.package}/bin/sower eval Sower.Release.migrate
            exec ${cfg.package}/bin/sower start
          '';
          ExecStop = "${cfg.package}/bin/sower stop";
        }
        (lib.optionalAttrs cfg.initSecrets {
          LoadCredential = [
            "RELEASE_COOKIE_FILE:%S/sower/release-cookie"
            "SECRET_KEY_BASE_FILE:%S/sower/secret-key-base"
          ];
        })
      ];

      environment = {
        PHX_SERVER = "true";
      } // cfg.environment;
    };

    systemd.services.sower-init-secrets = lib.mkIf cfg.initSecrets {
      wantedBy = [ "multi-user.target" ];
      before = [ "sower.service" ];
      requiredBy = [ "sower.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "sower-init-secrets" ''
          if [ ! -e /var/lib/sower/release-cookie ]; then
            ${pkgs.coreutils}/bin/dd if=/dev/urandom bs=1 count=16 | ${pkgs.hexdump}/bin/hexdump -e '64/1 "%02x"' > /var/lib/sower/release-cookie
          fi
          if [ ! -e /var/lib/sower/secret-key-base ]; then
            ${lib.getExe pkgs.pwgen} --capitalize --secure 64 1 | ${pkgs.coreutils}/bin/tr -d '\n' > /var/lib/sower/secret-key-base
          fi
        '';

        DynamicUser = true;
        StateDirectory = "sower";
        User = "sower";
        Group = "sower";
      };
    };
  };
}
