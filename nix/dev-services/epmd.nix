{
  pkgs,
  lib,
  name,
  config,
  ...
}:
let
  inherit (lib) types;
in
{
  options = {
    package = lib.mkPackageOption pkgs "erlang" { };

    port = lib.mkOption {
      type = types.port;
      default = 4369;
      description = ''
        The TCP port to accept connections.
      '';
    };
  };

  config = {
    outputs.settings.processes.${name} = {
      command = "${config.package}/bin/epmd -port ${toString config.port}";
    };
  };
}
