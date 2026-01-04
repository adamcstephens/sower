{ lib, pkgs, ... }:
let
  json = pkgs.formats.json { };
  jsonType = json.type;
in
{
  options = {
    sower.seed.meta = lib.mkOption {
      type = lib.types.submodule { freeformType = jsonType; };
      description = "meta to add to package meta";
      default = { };
    };
  };
}
