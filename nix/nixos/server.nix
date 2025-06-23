{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.server;
  jsonType = (pkgs.formats.json { }).type;

  adminScript = pkgs.writeShellApplication {
    name = "sower-server";

    text =
      (lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: val: ''
          ${name}="${val}"
          export ${name}
        '') cfg.environment
      ))
      + ''
        RELEASE_COOKIE=$(cat ${cfg.environment.RELEASE_COOKIE_FILE})
        export RELEASE_COOKIE
        exec ${cfg.package}/bin/sower "$@"
      '';
  };

  config-file = pkgs.writeText "sower-server-config" (builtins.toJSON cfg.settings);
in
{
  options = {
    services.sower.server = {
      enable = lib.mkEnableOption "Sower server";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ../packages/server.nix { };
      };

      settings = lib.mkOption {
        type = lib.types.submodule { freeformType = jsonType; };
        description = "sower server main configuration file";
        default = { };
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        description = "environment variables to pass to service. Do not set secrets here, but instead use `services.sower.server.secrets`";
        default = { };
      };

      initSecrets = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to initialise non-existent secrets with random values.
        '';
      };

      e2eTest = lib.mkEnableOption "e2e test mode. will preseed and write a token file";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr "RELEASE_COOKIE_FILE" cfg.environment;
        message = ''
          No RELEASE_COOKIE_FILE found. Either enable `services.sower.server.initSecrets`
            or set `services.sower.server.environment.RELEASE_COOKIE_FILE` to a path.
        '';
      }
    ];
    services.sower.server = lib.mkIf cfg.initSecrets {
      environment.RELEASE_COOKIE_FILE = "/var/lib/sower/release-cookie";
      settings.secret_key_base_file = "/var/lib/sower/secret-key-base";
    };

    environment.etc."sower/server.json".source = config-file;

    environment.systemPackages = [
      adminScript
    ];

    systemd.services.sower = {
      description = "Sower management platform";

      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "postgresql.service"
      ];
      requires = [ "network-online.target" ];

      serviceConfig = {
        Type = "notify";
        WatchdogSec = "10s";
        Restart = lib.mkDefault "on-failure";

        DynamicUser = true;
        StateDirectory = "sower";
        RuntimeDirectory = "sower";
        WorkingDirectory = "%S/sower";

        ExecStart = pkgs.writeShellScript "sower-start" ''
          RELEASE_COOKIE=$(cat ${cfg.environment.RELEASE_COOKIE_FILE})
          export RELEASE_COOKIE

          ${lib.getExe cfg.package} eval Sower.Release.migrate
          ${lib.optionalString cfg.e2eTest "${lib.getExe cfg.package} eval Sower.Repo.Seeds.Preseed.for_e2e"}
          exec ${lib.getExe cfg.package} start
        '';
        ExecStop = "${lib.getExe cfg.package} stop";
      };

      environment = {
        HOME = "%S/sower";
        PHX_SERVER = "true";
        SOWER_SERVER_CONFIG_FILE = config-file;
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
            echo "Generating release cookie"
            ${pkgs.coreutils}/bin/dd if=/dev/urandom bs=1 count=16 | ${pkgs.hexdump}/bin/hexdump -e '64/1 "%02x"' > /var/lib/sower/release-cookie
          fi
          if [ ! -e /var/lib/sower/secret-key-base ]; then
            echo "Generating secret key base"
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
