{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.garden;
  json = pkgs.formats.json { };
  jsonType = json.type;

  jsonConfig = json.generate "sower-client.json" (
    cfg.settings
    // {
      managed_profiles_directory = cfg.managedProfilesDirectory;
      nix_state_directory = cfg.nixStateDirectory;
    }
  );

  stateDir = "${config.xdg.stateHome}/sower-garden";

  secretsScript = pkgs.writeShellApplication {
    name = "sower-garden-init-secrets";
    runtimeInputs = [ pkgs.openssl ];
    text = ''
      mkdir -p ${stateDir}
      if [ ! -e ${stateDir}/release-cookie ]; then
        openssl rand -hex 48 > ${stateDir}/release-cookie
      fi
    '';
  };

  startScript = pkgs.writeShellApplication {
    name = "sower-garden-start";
    text = ''
      RELEASE_COOKIE=$(cat ${stateDir}/release-cookie)
      export RELEASE_COOKIE
      exec ${lib.getExe cfg.package} start
    '';
  };
in
{
  options = {
    services.sower.garden = {
      enable = lib.mkEnableOption "Sower garden";

      package = lib.mkOption { type = lib.types.package; };

      managedProfilesDirectory = lib.mkOption {
        type = lib.types.str;
        default = "${config.xdg.stateHome}/sower-profiles";
        description = "User-owned publication directory for named package and devshell profiles.";
      };

      nixStateDirectory = lib.mkOption {
        type = lib.types.str;
        default = "/nix/var/nix";
        description = "Actual local Nix daemon state directory. Must match a custom daemon state directory; this is not Garden's private state directory.";
      };

      activatorPackage = lib.mkOption { type = lib.types.package; };

      accessTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        description = "Path to file containing access token";
        default = null;
      };

      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = jsonType;

          options = { };
        };
        description = "Sower garden configuration file";
        default = { };
      };

      distribution = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable Erlang distribution for the garden.

          When disabled (default), lifecycle is signal-driven via systemd
          and release CLI subcommands that rely on RPC are unavailable.
          When enabled, the node uses a distinct RELEASE_NODE so it does
          not collide with a co-located system garden on the same host.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ cfg.package ];

        xdg.configFile."sower/client.json".source = jsonConfig;

        home.activation.sowerProfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${pkgs.coreutils}/bin/mkdir --parents --mode=0700 ${lib.escapeShellArg cfg.managedProfilesDirectory}
        '';
      }

      (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
        systemd.user.services.sower-garden = {
          Service = {
            Environment = [
              "PATH=/run/current-system/sw/bin:${
                lib.makeBinPath [
                  config.nix.package
                  cfg.activatorPackage
                ]
              }"
              "SOWER_CONFIG_FILE=%E/sower/client.json"
              "XDG_STATE_HOME=${config.xdg.stateHome}"
              "VM_MANAGER_BOOT_ID_FILE=%d/vm-manager-boot-id"
              "RELEASE_MODE=interactive"
              "SHELL=${lib.getExe pkgs.bash}"
            ]
            ++ lib.optionals cfg.distribution [
              # distinct node name so a co-located system garden doesn't clash
              "RELEASE_NODE=sower-garden-hm"
            ]
            ++ lib.optionals (!cfg.distribution) [
              "RELEASE_DISTRIBUTION=none"
              # release start script reads RELEASE_COOKIE unconditionally;
              # value is unused with distribution off.
              "RELEASE_COOKIE=disabled"
            ]
            ++ lib.optionals (cfg.accessTokenFile != null) [
              "SOWER_ACCESS_TOKEN_FILE=${cfg.accessTokenFile}"
            ];

            LoadCredential = [ "vm-manager-boot-id:/proc/sys/kernel/random/boot_id" ];

            ExecStartPre = [
              "${pkgs.coreutils}/bin/mkdir --parents --mode=0700 ${lib.escapeShellArg cfg.managedProfilesDirectory}"
            ]
            ++ (
              if cfg.distribution then
                [ (lib.getExe secretsScript) ]
              else
                [ "${pkgs.coreutils}/bin/mkdir --parents ${stateDir}" ]
            );
            ExecStart = if cfg.distribution then lib.getExe startScript else "${lib.getExe cfg.package} start";
            ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";

            Type = "notify";
            WatchdogSec = "10s";

            Restart = "always";
            RestartSec = "5";
            RestartMaxDelaySec = "120s";
            RestartSteps = "7";

            WorkingDirectory = "-${stateDir}";

            # Dir for the BEAM-bound admin socket; resolves to
            # $XDG_RUNTIME_DIR/sower-garden, matching the garden's default
            # admin_socket path. User-private (only the owning user connects).
            RuntimeDirectory = "sower-garden";
            RuntimeDirectoryMode = "0700";

            MemoryAccounting = true;
            MemoryMax = "200M";
          };

          Unit = {
            # For sd-switch users, this prevents killing sower mid-deployment
            X-SwitchMethod = "keep-old";
          };

          Install.WantedBy = [ "default.target" ];
        };
      })

      (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
        launchd = {
          agents.sower-garden = {
            enable = true;
            config = {
              KeepAlive = true;
              ProgramArguments = [
                (lib.getExe cfg.package)
                "start"
              ];
              EnvironmentVariables = {
                PATH = "/run/current-system/sw/bin:${
                  lib.makeBinPath [
                    config.nix.package
                    cfg.activatorPackage
                  ]
                }";
                SOWER_CONFIG_FILE = "${config.xdg.configHome}/sower/client.json";
                XDG_STATE_HOME = config.xdg.stateHome;
                RELEASE_MODE = "interactive";
              }
              // lib.optionalAttrs (cfg.accessTokenFile != null) {
                SOWER_ACCESS_TOKEN_FILE = cfg.accessTokenFile;
              };
              StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/sower-garden-err.log";
              StandardOutPath = "${config.home.homeDirectory}/Library/Logs/sower-garden-out.log";
            };
          };
        };
      })
    ]
  );
}
