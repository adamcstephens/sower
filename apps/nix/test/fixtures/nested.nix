# Test fixture: nested structure with both attrsets and derivations
{ }:
{
  packages = {
    hello = derivation {
      name = "hello";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = [ "-c" "echo hello > $out" ];
    };
    world = derivation {
      name = "world";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = [ "-c" "echo world > $out" ];
    };
  };

  lib = {
    someFunc = x: x;
  };
}
