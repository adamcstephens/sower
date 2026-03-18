{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sower.agent;
  json = pkgs.formats.json { };
  jsonType = json.type;

  jsonConfig = json.generate "sower-client.json" cfg.settings;

  stateDir = "${config.xdg.stateHome}/sower-agent";
in
{
  options = {
    services.sower.agent = {
      enable = lib.mkEnableOption "Sower agent";

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
        description = "Sower agent configuration file";
        default = { };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ cfg.package ];

        xdg.configFile."sower/client.json".source = lib.mkIf (cfg.settings != { }) jsonConfig;
      }

      (lib.mkIf pkgs.stdenv.isLinux {
        systemd.user.services.sower-agent = {
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

            ExecStartPre = pkgs.writeShellScript "sower-agent-init" ''
              mkdir -p ${stateDir}
              if [ ! -e ${stateDir}/release-cookie ]; then
                ${lib.getExe pkgs.openssl} rand -hex 48 > ${stateDir}/release-cookie
              fi
            '';
            ExecStart = pkgs.writeShellScript "sower-agent-start" ''
              RELEASE_COOKIE=$(cat ${stateDir}/release-cookie)
              export RELEASE_COOKIE
              exec ${lib.getExe cfg.package} start
            '';
            ExecStop = pkgs.writeShellScript "sower-agent-stop" ''
              RELEASE_COOKIE=$(cat ${stateDir}/release-cookie)
              export RELEASE_COOKIE
              PID=$(${lib.getExe cfg.package} pid)
              ${lib.getExe cfg.package} stop
              while [ -d "/proc/$PID" ]; do sleep 1; done
            '';
            ExecReload = pkgs.writeShellScript "sower-agent-reload" ''
              RELEASE_COOKIE=$(cat ${stateDir}/release-cookie)
              export RELEASE_COOKIE
              ${lib.getExe cfg.package} rpc "SowerAgent.request_reload()"
            '';

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
          agents.sower-agent = {
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
              StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/sower-agent-err.log";
              StandardOutPath = "${config.home.homeDirectory}/Library/Logs/sower-agent-out.log";
            };
          };
        };
      })
    ]
  );
}
