{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower;
in
{
  options = {
    services.sower = {
      enable = lib.mkEnableOption "Enable Sower service";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.sower;
      };

      initSecrets = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = lib.mdDoc ''
          Whether to initialise non‐existent secrets with random values.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.sower = {
      description = "Sower NixOS management platform";

      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];

      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "sower";
        RuntimeDirectory = "sower";

        ExecStop = "${cfg.package}/bin/sower stop";
      };

      environment =
        {
          RELEASE_DISTRIBUTION = "none";
          SOWER_DATABASE_PATH = "%S/sower/sower-prod.db";
          PHX_SERVER = "true";
        }
        // (lib.optionalAttrs cfg.initSecrets {
          RELEASE_COOKIE = "%t/sower/COOKIE";
          SECRET_KEY_BASE_FILE = "%S/sower/secret-key-base";
        })
        // cfg.environment;

      preStart = lib.optionalString cfg.initSecrets ''
        ${pkgs.coreutils}/bin/dd if=/dev/urandom bs=1 count=16 | ${pkgs.hexdump}/bin/hexdump -e '16/1 "%02x"' > "$RELEASE_COOKIE"
        ${lib.getExe pkgs.pwgen} --capitalize --secure 64 1 | ${pkgs.coreutils}/bin/tr -d '\n' > "$SECRET_KEY_BASE_FILE"
      '';

      script =
        (lib.optionalString cfg.initSecrets ''
          export SECRET_KEY_BASE=$(cat $SECRET_KEY_BASE_FILE)
        '')
        + ''
          ${cfg.package}/bin/sower eval Sower.Release.migrate
          ${cfg.package}/bin/sower start
        '';
    };
  };
}
