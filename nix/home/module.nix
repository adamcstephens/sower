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

  jsonConfig = json.generate "sower-client.json" cfg.settings;

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

  stopScript = pkgs.writeShellApplication {
    name = "sower-garden-stop";
    text = ''
      RELEASE_COOKIE=$(cat ${stateDir}/release-cookie)
      export RELEASE_COOKIE
      PID=$(${lib.getExe cfg.package} pid)
      ${lib.getExe cfg.package} stop
      while [ -d "/proc/$PID" ]; do sleep 1; done
    '';
  };

  reloadScript = pkgs.writeShellApplication {
    name = "sower-garden-reload";
    text = ''
      RELEASE_COOKIE=$(cat ${stateDir}/release-cookie)
      export RELEASE_COOKIE
      ${lib.getExe cfg.package} rpc "Garden.request_reload()"
    '';
  };
in
{
  options = {
    services.sower.garden = {
      enable = lib.mkEnableOption "Sower garden";

      package = lib.mkOption { type = lib.types.package; };

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
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ cfg.package ];

        xdg.configFile."sower/client.json".source = lib.mkIf (cfg.settings != { }) jsonConfig;

        warnings =
          let
            subs = cfg.settings.subscriptions or { };
            legacyFields = [
              "reboot_policy"
              "allow_realtime"
              "poll_on_connect"
              "window"
              "activation_args"
            ];
            subsWithLegacy = lib.filterAttrs (_name: sub: lib.any (field: sub ? ${field}) legacyFields) subs;
          in
          lib.mapAttrsToList (
            name: sub:
            let
              found = lib.filter (field: sub ? ${field}) legacyFields;
            in
            "services.sower.garden: subscription '${name}' uses deprecated fields (${lib.concatStringsSep ", " found}); use 'policy' instead"
          ) subsWithLegacy;
      }

      (lib.mkIf pkgs.stdenv.isLinux {
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
              "RELEASE_MODE=interactive"
              "SHELL=${lib.getExe pkgs.bash}"
            ]
            ++ lib.optionals (cfg.accessTokenFile != null) [
              "SOWER_ACCESS_TOKEN_FILE=${cfg.accessTokenFile}"
            ];

            ExecStartPre = [
              (lib.getExe secretsScript)
            ];
            ExecStart = lib.getExe startScript;
            ExecStop = lib.getExe stopScript;
            ExecReload = lib.getExe reloadScript;

            Type = "notify";
            WatchdogSec = "10s";

            Restart = "always";
            RestartSec = "5";
            RestartMaxDelaySec = "120s";
            RestartSteps = "7";

            WorkingDirectory = "-${stateDir}";

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

      (lib.mkIf pkgs.stdenv.isDarwin {
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
