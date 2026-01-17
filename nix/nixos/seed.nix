{ lib, pkgs, ... }:
let
  json = pkgs.formats.json { };
  jsonType = json.type;
in
{
  options = {
    sower.seed.meta = lib.mkOption {
      type = lib.types.submodule {
        freeformType = jsonType;
        options = {
          tags = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            description = "key/value tags";
            default = { };
          };
        };
      };
      description = "meta to add to package meta";
      default = { };
    };
  };
}
