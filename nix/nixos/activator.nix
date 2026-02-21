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

      allowedGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional groups allowed to connect to the activator socket";
      };

      debug = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable debug logging for the activator";
      };
    };

  };

  config = lib.mkIf cfg.enable {
    systemd.sockets.sower-activator = {
      description = "Sower Activator Socket";
      wantedBy = [ "sockets.target" ];

      # Start before agent so socket is ready
      before = [ "sower-agent.service" ];

      socketConfig = {
        ListenStream = cfg.socketPath;
        Accept = true;
        SocketMode = "0660";
        SocketUser = "root";
        SocketGroup = cfg.socketGroup;
        DirectoryMode = "0755";
        RemoveOnStop = true;
      };
    };

    systemd.services."sower-activator@" = {
      description = "Sower Activator Service";

      path = [
        config.nix.package
        pkgs.getent
      ];

      # avoid stopping mid-switch
      restartIfChanged = false;

      serviceConfig = {
        Type = "simple";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";

        # Build allowed GIDs list at runtime (group GIDs may not be known at eval time)
        ExecStart =
          let
            additionalGroups = cfg.allowedGroups;
            additionalGroupsArg = lib.concatStringsSep " " additionalGroups;
            debugFlag = lib.optionalString cfg.debug "--debug";
          in
          pkgs.writeShellScript "sower-activator-start" ''
            # Look up socket group GID at runtime
            SOCKET_GID=$(getent group ${cfg.socketGroup} | cut -f 3 -d :)

            # Resolve extra group GIDs at runtime
            EXTRA_GIDS=$(for group in ${additionalGroupsArg}; do getent group "$group" | cut -f 3 -d :; done | tr '\n' ',' | sed 's/,$//')

            # Build comma-separated GID list
            ALLOWED_GIDS="$SOCKET_GID${lib.optionalString (additionalGroupsArg != "") ",$EXTRA_GIDS"}"

            exec ${lib.getExe config.services.sower.activator.package} \
              --socket-mode \
              --allowed-gids "$ALLOWED_GIDS" \
              ${debugFlag}
          '';

        # TODO security hardening is limited, but we could probably turn on some things
        # NoNewPrivileges = false;
        # ProtectSystem = "full";
        # ProtectHome = false;
        # PrivateTmp = true;
        # BindPaths = [ "/usr" ];
        # ReadWritePaths = [ "/usr" ];
      };
    };

    users.groups.sower-activator = { };
  };
}
