{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.server;
  jsonType = (pkgs.formats.json { }).type;

  beamPackages = pkgs.beam.packagesWith pkgs.erlang_27;
  elixir = beamPackages.elixir_1_17;
in
{
  options = {
    services.sower.server = {
      enable = lib.mkEnableOption "Sower server";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./server-package.nix { inherit beamPackages elixir; };
      };

      secrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        description = "systemd credentials wrapper";
        example = {
          SOWER_DATABASE_PASS_FILE = "/path/to/pass/file";
        };
        default = { };
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
    };
  };

  config = lib.mkIf cfg.enable {
    services.sower.server.secrets = lib.mkIf cfg.initSecrets {
      release_cookie_file = "/var/lib/sower/release-cookie";
      secret_key_base_file = "/var/lib/sower/secret-key-base";
    };

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

        ExecStart = pkgs.writeShellScript "sower-start" ''
          ${lib.optionalString cfg.initSecrets ''
            export RELEASE_COOKIE=$(cat $CREDENTIALS_DIRECTORY/SOWER_RELEASE_COOKIE_FILE)
          ''}

          ${cfg.package}/bin/sower eval Sower.Release.migrate
          exec ${cfg.package}/bin/sower start
        '';
        ExecStop = "${cfg.package}/bin/sower stop";

        LoadCredential = lib.mapAttrsToList (k: v: "SOWER_${lib.toUpper k}:${v}") cfg.secrets;
      };

      environment = {
        PHX_SERVER = "true";
        SOWER_SERVER_CONFIG_FILE = pkgs.writeText "sower-server-config" (builtins.toJSON cfg.settings);
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
