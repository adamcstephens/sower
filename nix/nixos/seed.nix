{ lib, ... }:
{
  options = {
    sower.seed.meta = lib.mkOption {
      type = lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "Seed name override; null uses the configuration name.";
            default = null;
          };
          seed_type = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "nixos"
                "home-manager"
                "nix-darwin"
                "service"
              ]
            );
            description = "Seed type override; null uses nixos.";
            default = null;
          };
          tags = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            description = "key/value tags";
            default = { };
          };
        };
      };
      apply = lib.filterAttrs (_: value: value != null);
      description = "Seed manifest name, seed_type, and tags overrides. Other metadata is unsupported.";
      default = { };
    };
  };
}
