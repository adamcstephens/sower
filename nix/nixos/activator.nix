{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.activator;
  network = cfg.network;
  networkPolicy = pkgs.writeText "sower-network-policy.json" (
    builtins.toJSON {
      address_pool = network.addressPool;
      dns_resolver = network.dnsResolver;
      protected_destinations = network.protectedDestinations;
      state_directory = network.stateDirectory;
      garden_units = network.gardenUnits;
    }
  );
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

      network = {
        enable = lib.mkEnableOption "privileged, constrained Sower VM networking";

        gardenUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "sower-garden.service" ];
          description = "System services authorized to own network leases";
        };

        policyFile = lib.mkOption {
          type = lib.types.path;
          internal = true;
          readOnly = true;
          default = networkPolicy;
        };

        addressPool = lib.mkOption {
          type = lib.types.str;
          default = "10.254.0.0/16";
          description = "Canonical RFC1918 IPv4 CIDR (/16 through /30), divided into isolated guest /30 links";
        };

        dnsResolver = lib.mkOption {
          type = lib.types.str;
          default = "1.1.1.1";
          description = "Public IPv4 resolver; guests may use only this address on UDP/TCP port 53";
        };

        protectedDestinations = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Additional canonical IPv4 CIDRs denied to guests, including public host/control-plane destinations; built-in special/private/metadata exclusions cannot be removed";
        };

        stateDirectory = lib.mkOption {
          type = lib.types.str;
          default = "/run/sower-network";
          description = "Root-only runtime lease state and locks directory";
        };
      };
    };

  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.sockets.sower-activator = {
        description = "Sower Activator Socket";
        wantedBy = [ "sockets.target" ];

        before = [ "sower-garden.service" ];

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
        ]
        ++ lib.optionals network.enable [
          pkgs.iproute2
          pkgs.nftables
          pkgs.conntrack-tools
          config.systemd.package
          pkgs.coreutils
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
            pkgs.writeShellScriptBin "sower-activator-start" ''
              # Look up socket group GID at runtime
              SOCKET_GID=$(getent group ${cfg.socketGroup} | cut -f 3 -d :)

              # Resolve extra group GIDs at runtime
              EXTRA_GIDS=$(for group in ${additionalGroupsArg}; do getent group "$group" | cut -f 3 -d :; done | tr '\n' ',' | sed 's/,$//')

              # Build comma-separated GID list
              ALLOWED_GIDS="$SOCKET_GID${lib.optionalString (additionalGroupsArg != "") ",$EXTRA_GIDS"}"

              exec ${lib.getExe config.services.sower.activator.package} activator \
                --allowed-gids "$ALLOWED_GIDS" \
                ${lib.optionalString network.enable "--network-policy ${networkPolicy}"} \
                ${debugFlag}
            ''
            |> lib.getExe;

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
    })
    (lib.mkIf network.enable {
      assertions = [
        {
          assertion = cfg.enable;
          message = "services.sower.activator.network.enable requires services.sower.activator.enable";
        }
        {
          assertion =
            lib.hasPrefix "/run/" network.stateDirectory
            && builtins.match "/[A-Za-z0-9_./-]+" network.stateDirectory != null
            && !(lib.hasInfix "/../" network.stateDirectory)
            && !(lib.hasSuffix "/.." network.stateDirectory);
          message = "Sower network state directory must be beneath /run, without whitespace or parent traversal";
        }
      ];

      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      boot.kernelModules = [
        "tun"
        "nf_tables"
        "nf_conntrack"
        "nf_conntrack_netlink"
        "nf_nat"
      ];

      systemd.tmpfiles.rules = [
        "d /run/sower-network-ownership 0700 root root -"
        "d ${network.stateDirectory} 0700 root root -"
      ];

    })
  ];
}
