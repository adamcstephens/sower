{ pkgs, sowerLib }:
let
  target = pkgs.runCommand "seed-target" { } ''
    mkdir --parents "$out"
    echo ready > "$out/ready"
  '';
  manifest = sowerLib.mkSeedManifest {
    inherit pkgs target;
    name = "example";
    type = "nixos";
    tags.system = pkgs.stdenv.hostPlatform.system;
  };
  nixosManifest =
    (sowerLib.genNixosManifestPackages {
      example = {
        inherit pkgs;
        config.system.build.toplevel = target;
        config.system.nixos.version = "26.11";
        config.sower.seed.meta.tags.origin = "configuration";
      };
    }).${pkgs.stdenv.hostPlatform.system}."manifest/nixos/example";
  homeManifest =
    (sowerLib.genHomeManagerManifestPackages {
      example = {
        inherit pkgs;
        activationPackage = target;
        config.home = {
          username = "alice";
          homeDirectory = "/home/alice";
          version.release = "26.11";
        };
      };
    }).${pkgs.stdenv.hostPlatform.system}."manifest/home/example";
  check = pkgs.writers.writePython3Bin "check-seed-manifest" {
    libraries = [ pkgs.python3Packages.jsonschema ];
  } (builtins.readFile ./seed-manifest-check.py);
in
pkgs.stdenv.mkDerivation {
  name = "seed-manifest-test";
  dontUnpack = true;
  nativeBuildInputs = [ check ];
  installPhase = ''
    check-seed-manifest "${manifest}" "${target}" "${../seed-manifest.schema.json}" "${nixosManifest}" "${homeManifest}" "${pkgs.stdenv.hostPlatform.system}"
    touch "$out"
  '';
}
