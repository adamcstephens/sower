{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.activator;
in
{
  options = {
    services.sower.activator = {
      enable = lib.mkEnableOption "Sower activator socket service";

      package = lib.mkOption { type = lib.types.package; };

      socketPath = lib.mkOption {
        type = lib.types.str;
        default = "/run/sower-activator/activator.sock";
        description = "Path to the activator Unix socket";
      };

      socketGroup = lib.mkOption {
        type = lib.types.str;
        default = "sower-activator";
        description = "Group that can access the activator socket";
      };

      allowedGIDs = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [ ];
        description = "Additional GIDs allowed to connect to the activator socket";
      };

      debug = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable debug logging for the activator";
      };
    };

  };

  config = lib.mkIf cfg.enable {
    systemd.services.sower-activator = {
      description = "Sower Activator Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # Start before agent so socket is ready
      before = [ "sower-agent.service" ];

      path = [
        config.nix.package
        pkgs.getent
      ];

      # avoid restarting mid-switch
      restartIfChanged = false;

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";

        # Run as root (needed for NixOS activation) but with socketGroup
        # so the socket is created with root:socketGroup ownership
        Group = cfg.socketGroup;

        # RuntimeDirectory creates /run/sower-activator with proper ownership
        RuntimeDirectory = "sower-activator";
        RuntimeDirectoryMode = "0750";

        # Build allowed GIDs list at runtime (group GIDs may not be known at eval time)
        ExecStart =
          let
            additionalGIDs = map toString cfg.allowedGIDs;
            additionalGIDsArg = lib.concatStringsSep "," additionalGIDs;
            debugFlag = lib.optionalString cfg.debug "--debug";
          in
          pkgs.writeShellScript "sower-activator-start" ''
            # Look up socket group GID at runtime
            SOCKET_GID=$(getent group ${cfg.socketGroup} | cut -f 3 -d :)

            # Build comma-separated GID list
            ALLOWED_GIDS="$SOCKET_GID${lib.optionalString (additionalGIDsArg != "") ",${additionalGIDsArg}"}"

            exec ${lib.getExe config.services.sower.activator.package} \
              --server \
              --socket ${cfg.socketPath} \
              --allowed-gids "$ALLOWED_GIDS" \
              ${debugFlag}
          '';

        # Security hardening (limited since we need root for activation)
        NoNewPrivileges = false;
        ProtectSystem = "full";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    users.groups.sower-activator = { };
  };
}
